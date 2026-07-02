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
