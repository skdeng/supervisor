// Entitled now-playing reader: fetches the system-wide now-playing info dict — including
// the raw artwork bytes — and prints it as a single JSON object on stdout.
//
// Why this exists as a separately-compiled dylib loaded by /usr/bin/perl:
//
// Since macOS 15.4, `mediaremoted` gates the now-playing *info* read
// (`MRMediaRemoteGetNowPlayingInfo`) to callers whose host process is code-signed as an
// Apple identity (`com.apple.*`). An ad-hoc-signed third-party app receives a `nil` info
// dict — title, artist, AND artwork all denied. The `MRNowPlayingRequest` /
// `localNowPlayingItem.nowPlayingInfo` Objective-C path is admitted for metadata, but its
// dict carries only artwork *metadata* (MIME type, identifier, width/height) and never the
// raw `kMRMediaRemoteNowPlayingInfoArtworkData` bytes.
//
// The C async function `MRMediaRemoteGetNowPlayingInfo` returns a *different* info dict that
// DOES inline the artwork bytes under `kMRMediaRemoteNowPlayingInfoArtworkData` — the same
// channel Control Center uses, so it works source-agnostically (Music, Spotify, browser
// video). The catch is the entitlement gate: the gate keys off the *host* process identity,
// not the code that calls the function. `/usr/bin/perl` is Apple-signed (`com.apple.perl`),
// so when perl loads this dylib via DynaLoader and invokes the entry point, the
// MediaRemote call runs inside an entitled host and the daemon returns the full dict.
//
// All MediaRemote symbols are private/unsupported and resolved by name with `dlsym`.

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <unistd.h>

typedef void (*MRGetNowPlayingInfo_t)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRRegisterForNowPlayingNotifications_t)(dispatch_queue_t);

static NSString *MRAStringForKey(NSDictionary *info, NSString *key) {
    id v = info[key];
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

static NSNumber *MRANumberForKey(NSDictionary *info, NSString *key) {
    id v = info[key];
    return [v isKindOfClass:[NSNumber class]] ? (NSNumber *)v : nil;
}

// Like MRANumberForKey but rejects NaN / ±Infinity. A malicious now-playing source can set a
// non-finite duration/elapsed/rate, and NSJSONSerialization throws NSInvalidArgumentException on
// non-finite numbers — which, uncaught, would abort this helper. Dropping the field degrades to
// missing metadata instead.
static NSNumber *MRAFiniteNumberForKey(NSDictionary *info, NSString *key) {
    NSNumber *n = MRANumberForKey(info, key);
    return (n != nil && isfinite([n doubleValue])) ? n : nil;
}

// Builds the JSON payload the Swift side parses (NowPlaying.init?(json:)). Returns the
// serialized JSON, or "{}" when nothing is playing / the read was denied.
static NSString *MRABuildJSON(NSDictionary *info) {
    if (info == nil || [info count] == 0) {
        return @"{}";
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    NSString *title = MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoTitle");
    if (title != nil) out[@"title"] = title;
    NSString *artist = MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoArtist");
    if (artist != nil) out[@"artist"] = artist;
    NSString *album = MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
    if (album != nil) out[@"album"] = album;

    NSNumber *duration = MRAFiniteNumberForKey(info, @"kMRMediaRemoteNowPlayingInfoDuration");
    if (duration != nil) out[@"duration"] = duration;
    NSNumber *elapsed = MRAFiniteNumberForKey(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
    if (elapsed != nil) out[@"elapsed"] = elapsed;
    NSNumber *rate = MRAFiniteNumberForKey(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
    if (rate != nil) out[@"rate"] = rate;

    // The daemon samples ElapsedTime at this instant (an NSDate), NOT continuously — the live
    // position is `elapsed + (now - timestamp) * rate`. Forward it as epoch seconds (NSDate is
    // not JSON-serializable) so the Swift side can extrapolate accurately instead of assuming
    // the sample was taken "now" (which makes the scrubber snap back to the stale sample each
    // poll). Players that only push the sample at track start / seek rely on this entirely.
    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:[NSDate class]]) {
        out[@"timestampEpoch"] = @([(NSDate *)timestamp timeIntervalSince1970]);
    }

    // Track identity so the Swift side can reuse cached artwork across the daemon's
    // transient artwork drops (e.g. while scrubbing) without re-decoding.
    NSString *artworkID = MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoArtworkIdentifier");
    if (artworkID != nil) out[@"artworkIdentifier"] = artworkID;

    id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:[NSData class]] && [(NSData *)artwork length] > 0) {
        out[@"artwork"] = [(NSData *)artwork base64EncodedStringWithOptions:0];
    }

    // Final safety net: bail cleanly if anything in the payload is not JSON-serializable rather
    // than letting NSJSONSerialization raise (which would abort the helper).
    if (![NSJSONSerialization isValidJSONObject:out]) {
        return @"{}";
    }
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:&err];
    if (json == nil) {
        return @"{}";
    }
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

// Entry point invoked by perl via DynaLoader. Synchronously fetches the now-playing info
// (driving a short run-loop spin so the async completion and lazy artwork load can settle),
// then prints the JSON payload to stdout exactly once.
__attribute__((visibility("default")))
void run_mediaremote_adapter(void) {
    @autoreleasepool {
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (handle == NULL) {
            fputs("{}", stdout);
            return;
        }

        MRGetNowPlayingInfo_t getInfo =
            (MRGetNowPlayingInfo_t)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        MRRegisterForNowPlayingNotifications_t reg =
            (MRRegisterForNowPlayingNotifications_t)dlsym(
                handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (getInfo == NULL) {
            fputs("{}", stdout);
            return;
        }

        // Registering makes the daemon stream now-playing state to this process, which makes
        // the lazily-loaded artwork bytes far more likely to be populated by the time the
        // info read completes.
        if (reg != NULL) {
            reg(dispatch_get_main_queue());
        }

        dispatch_queue_t queue = dispatch_get_main_queue();

        // The artwork bytes load asynchronously and lazily: a single one-shot read right
        // after registration frequently returns metadata with no artwork yet. Issue a small
        // burst of reads at staggered intervals and stop as soon as a dict carrying artwork
        // arrives, otherwise settle for the richest metadata-only dict we saw. The whole run
        // stays well under the ~2s poll cadence on the Swift side.
        __block NSString *bestJSON = @"{}";
        __block BOOL haveArtwork = NO;
        __block BOOL haveTitle = NO;
        __block int completedReads = 0;
        const int kMaxPolls = 10;
        const NSTimeInterval kPollInterval = 0.06;     // 60ms between reads
        const NSTimeInterval kHardDeadline = 0.95;     // absolute cap on the whole run

        for (int i = 0; i < kMaxPolls; i++) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * kPollInterval * NSEC_PER_SEC)),
                queue,
                ^{
                    if (haveArtwork) return;   // already done; skip remaining scheduled reads
                    getInfo(queue, ^(NSDictionary *info) {
                        if (haveArtwork) return;
                        completedReads++;
                        NSString *json = MRABuildJSON(info);
                        BOOL gotArtwork = (info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] != nil);
                        BOOL gotTitle =
                            (MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoTitle") != nil);

                        // Keep the richest snapshot: prefer artwork, else a titled dict, else
                        // whatever we have.
                        if (gotArtwork || (gotTitle && !haveArtwork) || (!haveTitle && !haveArtwork)) {
                            bestJSON = json;
                        }
                        if (gotTitle) haveTitle = YES;
                        if (gotArtwork) {
                            haveArtwork = YES;
                            CFRunLoopStop(CFRunLoopGetMain());
                        } else if (!haveTitle && completedReads >= 2) {
                            // No now-playing session after a couple of reads (the second
                            // tolerates a transient empty first read): conclude nothing is
                            // playing and stop now rather than spinning to the hard deadline.
                            // Keeps the frequent idle polls cheap (~120ms vs ~950ms).
                            CFRunLoopStop(CFRunLoopGetMain());
                        }
                    });
                });
        }

        // Hard deadline so we always terminate even if no completion ever fires.
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHardDeadline * NSEC_PER_SEC)),
            queue, ^{ CFRunLoopStop(CFRunLoopGetMain()); });

        CFRunLoopRun();

        fputs([bestJSON UTF8String], stdout);
        fflush(stdout);
    }
}

// MARK: - Streaming mode
//
// `run_mediaremote_adapter` above pays a process spawn (perl + dyld + this dylib) for every
// read. Streaming pays it once: one long-lived helper prints one JSON object per line, and the
// caller reads lines as they arrive.
//
// The helper learns about changes two ways, because neither alone is dependable. It registers
// for MediaRemote's change notifications, which fire promptly when they fire at all — but they
// are silent for some players, so a cheap in-process re-read also runs on a timer. That timer
// costs an XPC round trip, not a process spawn, and it emits nothing unless the state moved.

/// Reads the now-playing dict, retrying briefly so the lazily-loaded artwork bytes have a
/// chance to arrive, then hands the richest JSON payload it saw to `completion` exactly once.
static void MRACaptureBest(MRGetNowPlayingInfo_t getInfo, void (^completion)(NSString *)) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    __block NSString *best = @"{}";
    __block BOOL haveArtwork = NO, haveTitle = NO, finished = NO;
    __block int completedReads = 0;
    const int kMaxPolls = 8;
    const NSTimeInterval kPollInterval = 0.06;
    const NSTimeInterval kDeadline = 0.6;

    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        completion(best);
    };

    for (int i = 0; i < kMaxPolls; i++) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * kPollInterval * NSEC_PER_SEC)), queue, ^{
                if (finished) return;
                getInfo(queue, ^(NSDictionary *info) {
                    if (finished) return;
                    completedReads++;
                    NSString *json = MRABuildJSON(info);
                    BOOL gotArtwork = (info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] != nil);
                    BOOL gotTitle = (MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoTitle") != nil);

                    if (gotArtwork || (gotTitle && !haveArtwork) || (!haveTitle && !haveArtwork)) {
                        best = json;
                    }
                    if (gotTitle) haveTitle = YES;
                    if (gotArtwork) {
                        haveArtwork = YES;
                        finish();
                    } else if (!haveTitle && completedReads >= 2) {
                        finish();   // nothing is playing; don't spin to the deadline
                    }
                });
            });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDeadline * NSEC_PER_SEC)), queue, finish);
}

// State of the last payload written to stdout, used to decide whether a fresh read is worth
// emitting at all.
static NSString *gLastIdentity = nil;   // title/artist/album/artworkID/duration/rate, joined
static double gLastElapsed = 0;
static double gLastTimestamp = 0;
static double gLastRate = 0;
static BOOL gHaveLast = NO;
static BOOL gEmitting = NO;
static BOOL gEmitPending = NO;

/// The fields whose change means "different track, or different playback state".
static NSString *MRAIdentity(NSDictionary *payload) {
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@",
            payload[@"title"] ?: @"", payload[@"artist"] ?: @"", payload[@"album"] ?: @"",
            payload[@"artworkIdentifier"] ?: @"", payload[@"duration"] ?: @"",
            payload[@"rate"] ?: @""];
}

/// True when this payload says something the last one didn't.
///
/// `elapsed` and `timestampEpoch` move on their own every time the daemon re-samples, so they
/// cannot be diffed directly — doing so would emit on every timer tick. The position is only
/// news when it disagrees with where the last sample said playback would be by now, which is
/// exactly what a seek looks like.
static BOOL MRAIsNewsworthy(NSDictionary *payload) {
    if (!gHaveLast) return YES;
    if (![MRAIdentity(payload) isEqualToString:gLastIdentity]) return YES;

    NSNumber *elapsed = payload[@"elapsed"];
    NSNumber *timestamp = payload[@"timestampEpoch"];
    if (elapsed == nil || timestamp == nil) return NO;

    double predicted = gLastElapsed + ([timestamp doubleValue] - gLastTimestamp) * gLastRate;
    return fabs([elapsed doubleValue] - predicted) > 1.5;   // a seek, not drift
}

static void MRARemember(NSDictionary *payload) {
    gLastIdentity = MRAIdentity(payload);
    gLastElapsed = [payload[@"elapsed"] doubleValue];
    gLastTimestamp = [payload[@"timestampEpoch"] doubleValue];
    gLastRate = [payload[@"rate"] doubleValue];
    gHaveLast = YES;
}

/// Capture a snapshot and write it as one line, but only if it carries news. Overlapping calls
/// (a notification landing mid-capture) collapse into one trailing re-capture.
static void MRAEmitIfChanged(MRGetNowPlayingInfo_t getInfo) {
    if (gEmitting) { gEmitPending = YES; return; }
    gEmitting = YES;

    MRACaptureBest(getInfo, ^(NSString *json) {
        gEmitting = NO;

        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([payload isKindOfClass:[NSDictionary class]] && MRAIsNewsworthy(payload)) {
            MRARemember(payload);
            // Writing to a pipe whose reader is gone raises SIGPIPE, which terminates this
            // helper — the correct outcome when the app has exited.
            fputs([json UTF8String], stdout);
            fputc('\n', stdout);
            fflush(stdout);
        }

        if (gEmitPending) {
            gEmitPending = NO;
            MRAEmitIfChanged(getInfo);
        }
    });
}

/// Exit when the parent closes our stdin, so the helper can never outlive the app that spawned
/// it. SIGPIPE covers the case where we are mid-write; this covers a helper that is idle and
/// would otherwise linger forever without writing.
static void MRAExitWhenParentGoes(void) {
    static dispatch_source_t source;   // must outlive this function
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0,
                                    dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        char scratch[256];
        if (read(STDIN_FILENO, scratch, sizeof(scratch)) <= 0) exit(0);   // EOF
    });
    dispatch_resume(source);
}

/// Entry point invoked by perl via DynaLoader for `stream` mode. Never returns.
__attribute__((visibility("default")))
void run_mediaremote_adapter_stream(void) {
    @autoreleasepool {
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (handle == NULL) return;

        MRGetNowPlayingInfo_t getInfo =
            (MRGetNowPlayingInfo_t)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
        MRRegisterForNowPlayingNotifications_t reg =
            (MRRegisterForNowPlayingNotifications_t)dlsym(
                handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (getInfo == NULL) return;

        MRAExitWhenParentGoes();

        // Registering both makes the daemon push state to this process (so artwork is warm) and
        // enables the change notifications observed below.
        if (reg != NULL) reg(dispatch_get_main_queue());

        // The notification names are exported as CFStringRef constants, so the symbol's address
        // is the address *of the variable*; dereference it to get the string.
        const char *notificationSymbols[] = {
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        };
        for (int i = 0; i < 4; i++) {
            void *symbol = dlsym(handle, notificationSymbols[i]);
            if (symbol == NULL) continue;
            NSString *name = (__bridge NSString *)*(CFStringRef *)symbol;
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                MRAEmitIfChanged(getInfo);
            }];
        }

        // Publish the current state at once. The caller has nothing to show until the first
        // line arrives, so it must not wait for a timer tick.
        MRAEmitIfChanged(getInfo);

        // Re-read on a timer as well: the notifications above stay silent for some players, and
        // a seek performed elsewhere never announces itself. Faster while playing, because that
        // is the only time the position can drift out from under the caller. Emitting is still
        // gated on the state having actually moved, so a quiet system writes nothing.
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                  (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            static int tick = 0;
            tick++;
            // Paused: re-read every other tick (4s). Slower than this and a play pressed in
            // another app would take that long to reach the notch whenever the change
            // notifications stay silent, which they do for some players.
            BOOL playing = (gLastRate != 0);
            if (playing || (tick % 2) == 0) MRAEmitIfChanged(getInfo);
        });
        dispatch_resume(timer);

        CFRunLoopRun();
    }
}
