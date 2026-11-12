// Entitled now-playing reader: reports every app's now-playing session — metadata, playback
// state, and raw artwork bytes — as JSON on stdout.
//
// Why this exists as a separately-compiled dylib loaded by /usr/bin/perl:
//
// Since macOS 15.4, `mediaremoted` gates now-playing *info* reads to callers whose host process
// is code-signed as an Apple identity (`com.apple.*`). An ad-hoc-signed third-party app gets a
// `nil` dict from `MRMediaRemoteGetNowPlayingInfo` and "Operation not permitted" from
// `MRNowPlayingRequest`. The gate keys off the *host* process identity, not the code that makes
// the call. `/usr/bin/perl` is Apple-signed (`com.apple.perl`), so when perl loads this dylib via
// DynaLoader and invokes an entry point, the reads run inside an admitted host.
//
// What it reads:
//
// macOS elects ONE app as "the" now-playing app, and the election lags behind what is audible:
// a video started in a browser can play for minutes while a paused music app stays elected, so
// the elected app alone misses media that is playing. The helper lists every now-playing client
// (`MRMediaRemoteGetNowPlayingClients` — the list Control Center renders) and asks each one for
// its playback state, info dict, and artwork through `MRNowPlayingRequest`. The caller decides
// which session to present.
//
// When that per-app surface cannot be resolved, or yields no session, the helper reads the
// elected app alone via `MRMediaRemoteGetNowPlayingInfo`, whose dict inlines the artwork bytes.
//
// Output: `{"capturedAt": <epoch seconds>, "sessions":[{...}, ...]}`, one object per session.
// `capturedAt` lets the caller order the output of two helpers. Each session carries `title`, `artist`,
// `album`, `duration`, `elapsed`, `rate`, `timestampEpoch`, `artworkIdentifier`, `artwork`
// (base64), `playing`, and `elected`; per-app sessions also carry `bundleIdentifier`,
// `processIdentifier`, and `appName`.
//
// All MediaRemote symbols and classes are private/unsupported: functions are resolved by name
// with `dlsym`, classes with `objc_getClass`, and every selector is checked before it is sent.

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>

typedef void (*MRGetNowPlayingInfo_t)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetNowPlayingClients_t)(dispatch_queue_t, void (^)(NSArray *));
typedef void (*MRRegisterForNowPlayingNotifications_t)(dispatch_queue_t);

// The private initializers this helper sends, declared so ARC applies init-family ownership to
// them: the receiver is consumed and the result is owned. Sent through a cast `objc_msgSend`,
// ARC would release the `alloc` result itself, which over-releases whenever an initializer
// returns nil or an object other than its receiver.
@interface NSObject (MRAPrivateInitializers)
- (instancetype)initWithOrigin:(id)origin client:(id)client player:(id)player;
- (instancetype)initWithPlayerPath:(id)playerPath;
@end

/// `MRPlaybackState` value for a session that is playing.
static const uint32_t kMRAPlaybackStatePlaying = 1;
/// Titled sessions past this count are ignored.
static const NSUInteger kMRAMaxSessions = 8;
/// Clients past this count are not queried, bounding the work one capture can be made to do.
/// Larger than `kMRAMaxSessions` because a listed client may have nothing loaded.
static const NSUInteger kMRAMaxClients = 32;
/// Artwork larger than this is dropped (the session renders its placeholder), so the line a
/// capture prints stays within the reader's buffer: 8 sessions x 4 MiB of base64 = 32 MiB.
static const NSUInteger kMRAMaxArtworkBytes = 3 << 20;
/// Longest title/artist/album/app name forwarded, in UTF-16 units. Another app sets these, and
/// an unbounded one would push every line past the reader's buffer.
static const NSUInteger kMRAMaxTextLength = 300;
/// Longest bundle identifier accepted; a client naming a longer one is skipped.
static const NSUInteger kMRAMaxBundleIdentifierLength = 255;
/// Artwork requests made for one track before concluding it has none to give.
static const NSInteger kMRAMaxArtworkAttempts = 5;

// MARK: - Resolved MediaRemote surface

static void *gHandle = NULL;
static MRGetNowPlayingInfo_t gGetInfo = NULL;
static MRGetNowPlayingClients_t gGetClients = NULL;
static MRRegisterForNowPlayingNotifications_t gRegister = NULL;
static Class gRequestClass = Nil;
static Class gPlayerPathClass = Nil;
static Class gOriginClass = Nil;
/// Whether every function, class, and selector the per-app read needs was found.
static BOOL gPerAppReads = NO;

/// Resolves the MediaRemote surface. Returns NO when neither the per-app read nor the
/// elected-app read is available, in which case there is nothing this helper can report.
static BOOL MRAResolve(void) {
    gHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (gHandle == NULL) return NO;

    gGetInfo = (MRGetNowPlayingInfo_t)dlsym(gHandle, "MRMediaRemoteGetNowPlayingInfo");
    gGetClients = (MRGetNowPlayingClients_t)dlsym(gHandle, "MRMediaRemoteGetNowPlayingClients");
    gRegister = (MRRegisterForNowPlayingNotifications_t)dlsym(
        gHandle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    gRequestClass = objc_getClass("MRNowPlayingRequest");
    gPlayerPathClass = objc_getClass("MRPlayerPath");
    gOriginClass = objc_getClass("MROrigin");

    gPerAppReads =
        gGetClients != NULL && gRequestClass != Nil && gPlayerPathClass != Nil && gOriginClass != Nil
        && [gOriginClass respondsToSelector:sel_registerName("localOrigin")]
        && [gRequestClass respondsToSelector:sel_registerName("localNowPlayingPlayerPath")]
        && [gPlayerPathClass instancesRespondToSelector:sel_registerName("initWithOrigin:client:player:")]
        && [gRequestClass instancesRespondToSelector:sel_registerName("initWithPlayerPath:")]
        && [gRequestClass instancesRespondToSelector:sel_registerName("requestPlaybackStateOnQueue:completion:")]
        && [gRequestClass instancesRespondToSelector:sel_registerName("requestNowPlayingInfoOnQueue:completion:")]
        && [gRequestClass instancesRespondToSelector:sel_registerName("requestNowPlayingItemArtworkOnQueue:completion:")];

    return gPerAppReads || gGetInfo != NULL;
}

// MARK: - Payload building

/// `text` cut to `kMRAMaxTextLength`, on a composed-character boundary so the cut never splits
/// a surrogate pair into text that cannot be encoded.
static NSString *MRABoundedText(NSString *text) {
    if ([text length] <= kMRAMaxTextLength) return text;
    NSRange kept = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, kMRAMaxTextLength)];
    return [text substringToIndex:kept.location + kept.length];
}

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

/// Sends a no-argument selector that returns an object, or nil when `target` lacks it.
static id MRAObject(id target, const char *selector) {
    SEL sel = sel_registerName(selector);
    if (target == nil || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static NSString *MRAString(id target, const char *selector) {
    id v = MRAObject(target, selector);
    return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
}

static int MRAProcessIdentifier(id client) {
    SEL sel = sel_registerName("processIdentifier");
    if (client == nil || ![client respondsToSelector:sel]) return 0;
    return ((int (*)(id, SEL))objc_msgSend)(client, sel);
}

/// The session fields the Swift side parses (`NowPlaying.init?(json:)`), taken from a
/// MediaRemote info dict. Empty when the dict is nil or carries none of them.
static NSMutableDictionary *MRABuildPayload(NSDictionary *info) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (![info isKindOfClass:[NSDictionary class]]) return out;

    NSString *title = MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoTitle");
    if (title != nil) out[@"title"] = MRABoundedText(title);
    NSString *artist = MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoArtist");
    if (artist != nil) out[@"artist"] = MRABoundedText(artist);
    NSString *album = MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
    if (album != nil) out[@"album"] = MRABoundedText(album);

    NSNumber *duration = MRAFiniteNumberForKey(info, @"kMRMediaRemoteNowPlayingInfoDuration");
    if (duration != nil) out[@"duration"] = duration;
    NSNumber *elapsed = MRAFiniteNumberForKey(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
    if (elapsed != nil) out[@"elapsed"] = elapsed;
    NSNumber *rate = MRAFiniteNumberForKey(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
    if (rate != nil) out[@"rate"] = rate;

    // The daemon samples ElapsedTime at this instant (an NSDate), NOT continuously — the live
    // position is `elapsed + (now - timestamp) * rate`. Forward it as epoch seconds (NSDate is
    // not JSON-serializable) so the Swift side can extrapolate from the real sample time. Players
    // that only push the sample at track start / seek rely on this entirely.
    id timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([timestamp isKindOfClass:[NSDate class]]) {
        out[@"timestampEpoch"] = @([(NSDate *)timestamp timeIntervalSince1970]);
    }

    // Track identity, so the Swift side decodes artwork once per track.
    NSString *artworkID = MRAStringForKey(info, @"kMRMediaRemoteNowPlayingInfoArtworkIdentifier");
    if (artworkID != nil) out[@"artworkIdentifier"] = MRABoundedText(artworkID);

    // Present only in the elected-app dict; a per-app dict carries artwork metadata without the
    // bytes, which come from a separate artwork request.
    id artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([artwork isKindOfClass:[NSData class]] && [(NSData *)artwork length] > 0
        && [(NSData *)artwork length] <= kMRAMaxArtworkBytes) {
        out[@"artwork"] = [(NSData *)artwork base64EncodedStringWithOptions:0];
    }
    return out;
}

/// Sets `playing` and normalizes `rate` to match it. `playbackState` is the explicit state when
/// the session reported one; without it the rate decides. A playing session with no usable rate
/// advances at 1x, and a session that is not playing advances at 0 whatever rate it last set.
static void MRAApplyPlayback(NSMutableDictionary *payload, NSNumber *playbackState) {
    double rate = [payload[@"rate"] doubleValue];
    BOOL playing = playbackState != nil
        ? ([playbackState unsignedIntValue] == kMRAPlaybackStatePlaying)
        : (rate > 0);
    payload[@"playing"] = playing ? @YES : @NO;
    payload[@"rate"] = @(playing ? (rate > 0 ? rate : 1.0) : 0.0);
}

/// One line of output for a set of sessions, or nil when it cannot be serialized.
static NSString *MRASerialize(NSArray<NSDictionary *> *sessions) {
    NSDictionary *root = @{
        @"sessions": sessions,
        @"capturedAt": @([[NSDate date] timeIntervalSince1970]),
    };
    // Bail cleanly if anything in the payload is not JSON-serializable rather than letting
    // NSJSONSerialization raise (which would abort the helper).
    if (![NSJSONSerialization isValidJSONObject:root]) return nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    if (json == nil) return nil;
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

// MARK: - Elected-app capture

/// Reads the elected app's info dict, retrying briefly because its artwork bytes load lazily: a
/// read right after registration often returns metadata with no artwork yet. Hands the richest
/// payload it saw to `completion` exactly once — nil when nothing is playing.
static void MRACaptureElected(NSTimeInterval deadline, void (^completion)(NSDictionary *)) {
    dispatch_queue_t queue = dispatch_get_main_queue();
    __block NSDictionary *best = nil;
    __block BOOL haveArtwork = NO, haveTitle = NO, finished = NO;
    __block int completedReads = 0;
    const int kMaxPolls = 10;
    const NSTimeInterval kPollInterval = 0.06;

    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        completion(best);
    };

    if (gGetInfo == NULL) {
        dispatch_async(queue, finish);
        return;
    }

    for (int i = 0; i < kMaxPolls; i++) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * kPollInterval * NSEC_PER_SEC)), queue, ^{
                if (finished) return;
                gGetInfo(queue, ^(NSDictionary *info) {
                    if (finished) return;
                    completedReads++;
                    NSMutableDictionary *payload = MRABuildPayload(info);
                    BOOL gotArtwork = (payload[@"artwork"] != nil);
                    BOOL gotTitle = (payload[@"title"] != nil);

                    // Keep the richest snapshot: prefer artwork, else a titled dict.
                    if (gotTitle && (gotArtwork || !haveArtwork)) {
                        MRAApplyPlayback(payload, nil);
                        payload[@"elected"] = @YES;
                        best = payload;
                    }
                    if (gotTitle) haveTitle = YES;
                    if (gotArtwork) {
                        haveArtwork = YES;
                        finish();
                    } else if (!haveTitle && completedReads >= 2) {
                        // No session after a second read (which tolerates a transient empty
                        // first one): nothing is playing, so don't spin to the deadline.
                        finish();
                    }
                });
            });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)), queue, finish);
}

// MARK: - Per-app capture

/// Artwork state per session: `sessionKey -> @{@"track": ..., @"artwork": base64, @"attempts": n}`.
/// A streaming helper re-reads every couple of seconds; this keeps each read from pulling the
/// full artwork bytes for every session across XPC again, and stops asking for artwork a track
/// has repeatedly failed to produce. `artwork` is absent until a request yields usable bytes.
static NSMutableDictionary<NSString *, NSDictionary *> *gArtworkCache = nil;

static NSString *MRASessionKey(NSDictionary *session) {
    NSString *bundleID = session[@"bundleIdentifier"];
    if (bundleID == nil) return @"elected";
    return [NSString stringWithFormat:@"%@:%@", bundleID, session[@"processIdentifier"] ?: @0];
}

/// What the cached artwork belongs to. An app that sets no artwork identifier is keyed by its
/// metadata, so a new track still refetches — and so does artwork that arrives after the
/// metadata, since its identifier arrives with it.
static NSString *MRATrackKey(NSDictionary *payload) {
    NSString *artworkID = payload[@"artworkIdentifier"];
    if (artworkID != nil) return [@"id:" stringByAppendingString:artworkID];
    return [NSString stringWithFormat:@"meta:%@|%@|%@",
            payload[@"title"] ?: @"", payload[@"artist"] ?: @"", payload[@"album"] ?: @""];
}

/// Reads every now-playing client's session through `MRNowPlayingRequest`. Hands `completion`
/// the titled sessions exactly once — an empty array when no client has one, nil when the
/// capture is incomplete.
///
/// A capture is incomplete when the client list, or any client's state or info reply, has not
/// arrived by `deadline`. An incomplete capture says nothing about what is playing: reporting it
/// would make a session with a slow reply vanish for one read and return on the next. With
/// `allowPartial`, a capture missing only per-client replies reports what did arrive, which is
/// how a caller stops waiting on a client that never answers. Artwork is never waited for; a
/// late reply is cached for the next capture.
static void MRACapturePerApp(NSTimeInterval deadline, BOOL allowPartial,
                             void (^completion)(NSArray<NSDictionary *> *)) {
    if (gArtworkCache == nil) gArtworkCache = [NSMutableDictionary dictionary];

    dispatch_queue_t queue = dispatch_get_main_queue();
    NSMutableArray<NSMutableDictionary *> *entries = [NSMutableArray array];
    __block BOOL finished = NO, listed = NO;
    __block NSInteger essential = 1;   // replies a complete capture needs: the listing, then
                                       // each client's state and info
    __block NSInteger artworkPending = 0;

    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        if (!listed || (essential > 0 && !allowPartial)) {
            completion(nil);
            return;
        }
        NSMutableArray<NSDictionary *> *sessions = [NSMutableArray array];
        NSMutableSet<NSString *> *present = [NSMutableSet set];
        for (NSMutableDictionary *entry in entries) {
            NSString *key = MRASessionKey(entry);
            BOOL repeated = [present containsObject:key];
            [present addObject:key];
            // Skipped: a client with nothing loaded, a second entry for a session already
            // taken, and sessions past the cap.
            if (entry[@"title"] == nil || repeated || [sessions count] >= kMRAMaxSessions) continue;
            NSNumber *state = entry[@"playbackState"];
            [entry removeObjectForKey:@"playbackState"];
            MRAApplyPlayback(entry, state);
            [sessions addObject:entry];
        }
        for (NSString *key in [gArtworkCache allKeys]) {
            if (![present containsObject:key]) [gArtworkCache removeObjectForKey:key];
        }
        completion(sessions);
    };
    void (^settle)(void) = ^{
        if (essential == 0 && artworkPending == 0) finish();
    };

    gGetClients(queue, ^(NSArray *clients) { @autoreleasepool {
        if (finished) return;
        listed = YES;
        essential--;
        if (![clients isKindOfClass:[NSArray class]]) {
            settle();
            return;
        }

        id origin = MRAObject(gOriginClass, "localOrigin");
        id electedClient = MRAObject(MRAObject(gRequestClass, "localNowPlayingPlayerPath"), "client");
        NSString *electedBundleID = MRAString(electedClient, "bundleIdentifier");
        int electedPID = MRAProcessIdentifier(electedClient);

        for (id client in clients) {
            if ([entries count] >= kMRAMaxClients) break;
            NSString *bundleID = MRAString(client, "bundleIdentifier");
            if (bundleID == nil || [bundleID length] == 0
                || [bundleID length] > kMRAMaxBundleIdentifierLength) continue;
            int pid = MRAProcessIdentifier(client);
            if (pid <= 0) continue;

            // A nil player addresses the client's own now-playing player.
            id path = [[gPlayerPathClass alloc] initWithOrigin:origin client:client player:nil];
            if (path == nil) continue;
            id request = [[gRequestClass alloc] initWithPlayerPath:path];
            if (request == nil) continue;

            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"bundleIdentifier"] = bundleID;
            entry[@"processIdentifier"] = @(pid);
            NSString *appName = MRAString(client, "displayName");
            if (appName != nil) entry[@"appName"] = MRABoundedText(appName);
            BOOL elected = electedBundleID != nil && [electedBundleID isEqualToString:bundleID]
                && electedPID == pid;
            entry[@"elected"] = elected ? @YES : @NO;
            [entries addObject:entry];
            NSString *sessionKey = MRASessionKey(entry);

            // Each completion block holds `request`, keeping it alive until its reply arrives.
            essential += 2;
            ((void (*)(id, SEL, id, id))objc_msgSend)(
                request, sel_registerName("requestPlaybackStateOnQueue:completion:"), queue,
                ^(uint32_t state, NSError *error) {
                    (void)request;
                    if (finished) return;
                    if (error == nil) entry[@"playbackState"] = @(state);
                    essential--;
                    settle();
                });
            ((void (*)(id, SEL, id, id))objc_msgSend)(
                request, sel_registerName("requestNowPlayingInfoOnQueue:completion:"), queue,
                ^(NSDictionary *info, NSError *error) { @autoreleasepool {
                    if (finished) return;
                    essential--;
                    NSMutableDictionary *payload = MRABuildPayload(info);
                    [entry addEntriesFromDictionary:payload];
                    if (payload[@"title"] == nil) {
                        settle();
                        return;
                    }

                    NSString *trackKey = MRATrackKey(payload);
                    NSDictionary *cached = gArtworkCache[sessionKey];
                    BOOL sameTrack = cached != nil && [cached[@"track"] isEqualToString:trackKey];
                    NSInteger attempts = sameTrack ? [cached[@"attempts"] integerValue] : 0;
                    if (sameTrack && cached[@"artwork"] != nil) {
                        entry[@"artwork"] = cached[@"artwork"];
                        settle();
                        return;
                    }
                    if (attempts >= kMRAMaxArtworkAttempts) {
                        settle();
                        return;
                    }

                    // Uncached. Artwork can load after the metadata, so a track is asked a few
                    // times before it is taken to have none.
                    gArtworkCache[sessionKey] = @{@"track": trackKey, @"attempts": @(attempts + 1)};
                    artworkPending++;
                    ((void (*)(id, SEL, id, id))objc_msgSend)(
                        request, sel_registerName("requestNowPlayingItemArtworkOnQueue:completion:"), queue,
                        ^(id artwork, NSError *artworkError) { @autoreleasepool {
                            id data = MRAObject(artwork, "imageData");
                            BOOL isData = [data isKindOfClass:[NSData class]] && [(NSData *)data length] > 0;
                            BOOL current = [gArtworkCache[sessionKey][@"track"] isEqualToString:trackKey];
                            if (isData && [(NSData *)data length] > kMRAMaxArtworkBytes) {
                                // Too large to forward, and asking again returns the same bytes.
                                if (current) {
                                    gArtworkCache[sessionKey] =
                                        @{@"track": trackKey, @"attempts": @(kMRAMaxArtworkAttempts)};
                                }
                            } else if (isData) {
                                NSString *encoded = [(NSData *)data base64EncodedStringWithOptions:0];
                                // Cached even when this capture already finished, so a reply
                                // that missed the deadline is ready for the next capture.
                                if (current) {
                                    gArtworkCache[sessionKey] = @{
                                        @"track": trackKey, @"artwork": encoded,
                                        @"attempts": @(attempts + 1),
                                    };
                                }
                                if (!finished) entry[@"artwork"] = encoded;
                            }
                            if (finished) return;
                            artworkPending--;
                            settle();
                        }});
                    settle();
                }});
        }
        settle();
    }});

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(deadline * NSEC_PER_SEC)), queue, finish);
}

/// Reads every session: each app's own where the per-app surface is available, and the elected
/// app's when it is not or when it reports no session (a per-app read that is refused yields
/// none, and the elected read may still be admitted). `completion` receives nil for an
/// incomplete capture — see `MRACapturePerApp`.
static void MRACaptureSessions(NSTimeInterval deadline, BOOL allowPartial,
                               void (^completion)(NSArray<NSDictionary *> *)) {
    void (^captureElected)(void) = ^{
        MRACaptureElected(deadline, ^(NSDictionary *payload) {
            completion(payload != nil ? @[payload] : @[]);
        });
    };
    if (!gPerAppReads) {
        captureElected();
        return;
    }
    MRACapturePerApp(deadline, allowPartial, ^(NSArray<NSDictionary *> *sessions) {
        if (sessions != nil && [sessions count] == 0 && gGetInfo != NULL) {
            captureElected();
        } else {
            completion(sessions);
        }
    });
}

// MARK: - One-shot mode

// Entry point invoked by perl via DynaLoader. Captures every session once, prints the JSON
// payload to stdout, and returns. An incomplete capture prints `{}` — no `sessions` key — which
// the caller reads as "no answer", distinct from an empty session list.
__attribute__((visibility("default")))
void run_mediaremote_adapter(void) {
    @autoreleasepool {
        if (!MRAResolve()) {
            fputs("{}", stdout);
            return;
        }

        // Registering makes the daemon stream now-playing state to this process, which makes
        // the lazily-loaded artwork bytes far more likely to be populated by the time a read
        // completes.
        if (gRegister != NULL) gRegister(dispatch_get_main_queue());

        MRACaptureSessions(0.95, NO, ^(NSArray<NSDictionary *> *sessions) {
            NSString *json = sessions != nil ? MRASerialize(sessions) : nil;
            fputs(json != nil ? [json UTF8String] : "{}", stdout);
            fflush(stdout);
            CFRunLoopStop(CFRunLoopGetMain());
        });
        CFRunLoopRun();
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
// costs XPC round trips, not a process spawn, and it emits nothing unless the state moved.

// What the last line written to stdout said about each session, keyed by `MRASessionKey`:
// `@{@"identity": ..., @"elapsed": ..., @"timestamp": ..., @"rate": ...}`. Decides whether a
// fresh capture is worth emitting at all.
static NSDictionary<NSString *, NSDictionary *> *gLastSessions = nil;
static BOOL gAnyPlaying = NO;
static BOOL gEmitting = NO;
static BOOL gEmitPending = NO;
/// Incomplete captures in a row. After a few, the next capture reports what it has, so one
/// client that never answers cannot freeze the stream.
static NSInteger gIncompleteStreak = 0;
static const NSInteger kMRAIncompleteCapturesTolerated = 2;

/// The fields whose change means "different track, different app state, or artwork arrived".
static NSString *MRAIdentity(NSDictionary *payload) {
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%@|%@|%@",
            payload[@"title"] ?: @"", payload[@"artist"] ?: @"", payload[@"album"] ?: @"",
            payload[@"artworkIdentifier"] ?: @"", payload[@"duration"] ?: @"",
            payload[@"rate"] ?: @"", payload[@"playing"] ?: @"", payload[@"elected"] ?: @"",
            payload[@"appName"] ?: @"", payload[@"artwork"] != nil ? @"art" : @""];
}

/// True when these sessions say something the last line didn't.
///
/// `elapsed` and `timestampEpoch` move on their own every time the daemon re-samples, so they
/// cannot be diffed directly — doing so would emit on every timer tick. A position is only news
/// when it disagrees with where the last sample said playback would be by now, which is exactly
/// what a seek looks like. The order sessions arrive in carries no meaning and is ignored.
static BOOL MRAIsNewsworthy(NSArray<NSDictionary *> *sessions) {
    if (gLastSessions == nil) return YES;
    if ([sessions count] != [gLastSessions count]) return YES;

    for (NSDictionary *session in sessions) {
        NSDictionary *last = gLastSessions[MRASessionKey(session)];
        if (last == nil) return YES;
        if (![MRAIdentity(session) isEqualToString:last[@"identity"]]) return YES;

        NSNumber *elapsed = session[@"elapsed"];
        NSNumber *timestamp = session[@"timestampEpoch"];
        if (elapsed == nil || timestamp == nil) continue;
        double predicted = [last[@"elapsed"] doubleValue]
            + ([timestamp doubleValue] - [last[@"timestamp"] doubleValue]) * [last[@"rate"] doubleValue];
        if (fabs([elapsed doubleValue] - predicted) > 1.5) return YES;   // a seek, not drift
    }
    return NO;
}

static void MRARemember(NSArray<NSDictionary *> *sessions) {
    NSMutableDictionary *remembered = [NSMutableDictionary dictionary];
    BOOL anyPlaying = NO;
    for (NSDictionary *session in sessions) {
        remembered[MRASessionKey(session)] = @{
            @"identity": MRAIdentity(session),
            @"elapsed": session[@"elapsed"] ?: @0,
            @"timestamp": session[@"timestampEpoch"] ?: @0,
            @"rate": session[@"rate"] ?: @0,
        };
        if ([session[@"playing"] boolValue]) anyPlaying = YES;
    }
    gLastSessions = remembered;
    gAnyPlaying = anyPlaying;
}

/// Capture every session and write them as one line, but only if they carry news. Overlapping
/// calls (a notification landing mid-capture) collapse into one trailing re-capture.
static void MRAEmitIfChanged(void) {
    if (gEmitting) { gEmitPending = YES; return; }
    gEmitting = YES;

    BOOL allowPartial = gIncompleteStreak >= kMRAIncompleteCapturesTolerated;
    MRACaptureSessions(0.6, allowPartial, ^(NSArray<NSDictionary *> *sessions) { @autoreleasepool {
        gEmitting = NO;
        gIncompleteStreak = sessions != nil ? 0 : gIncompleteStreak + 1;

        if (sessions != nil && MRAIsNewsworthy(sessions)) {
            NSString *line = MRASerialize(sessions);
            if (line != nil) {
                MRARemember(sessions);
                // Writing to a pipe whose reader is gone raises SIGPIPE, which terminates this
                // helper — the correct outcome when the app has exited.
                fputs([line UTF8String], stdout);
                fputc('\n', stdout);
                fflush(stdout);
            }
        }

        if (gEmitPending) {
            gEmitPending = NO;
            MRAEmitIfChanged();
        }
    }});
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
        if (!MRAResolve()) return;

        MRAExitWhenParentGoes();

        // Registering both makes the daemon push state to this process (so artwork is warm) and
        // enables the change notifications observed below.
        if (gRegister != NULL) gRegister(dispatch_get_main_queue());

        // The notification names are exported as CFStringRef constants, so the symbol's address
        // is the address *of the variable*; dereference it to get the string. The first four
        // announce the elected app; the rest announce any app's player, which is what moves when
        // an app that is not elected starts or stops playing.
        const char *notificationSymbols[] = {
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRMediaRemotePlayerIsPlayingDidChangeNotification",
            "kMRMediaRemotePlayerPlaybackStateDidChangeNotification",
            "kMRMediaRemotePlayerNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteActivePlayerPathsDidChange",
        };
        const int notificationCount = sizeof(notificationSymbols) / sizeof(notificationSymbols[0]);
        for (int i = 0; i < notificationCount; i++) {
            void *symbol = dlsym(gHandle, notificationSymbols[i]);
            if (symbol == NULL) continue;
            NSString *name = (__bridge NSString *)*(CFStringRef *)symbol;
            if (name == nil) continue;
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *note) {
                MRAEmitIfChanged();
            }];
        }

        // Publish the current state at once. The caller has nothing to show until the first
        // line arrives, so it must not wait for a timer tick.
        MRAEmitIfChanged();

        // Re-read on a timer as well: the notifications above stay silent for some players, and
        // a seek performed elsewhere never announces itself. Faster while any session plays,
        // because that is the only time a position can drift out from under the caller. Emitting
        // is still gated on the state having actually moved, so a quiet system writes nothing.
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                  (uint64_t)(2.0 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            static int tick = 0;
            tick++;
            // Nothing playing: re-read every other tick (4s). Slower than this and a play
            // pressed in another app would take that long to reach the notch whenever the
            // change notifications stay silent, which they do for some players.
            if (gAnyPlaying || (tick % 2) == 0) MRAEmitIfChanged();
        });
        dispatch_resume(timer);

        CFRunLoopRun();
    }
}
