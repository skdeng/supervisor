import AppKit
import Foundation
import Testing

@testable import SuperVisor

/// A session object as the entitled helper prints it.
private func sessionJSON(
    _ bundleID: String,
    pid: Int = 100,
    title: String = "Track",
    playing: Bool,
    sampledAt: Double = 1_000,
    elected: Bool = false
) -> [String: Any] {
    [
        "bundleIdentifier": bundleID,
        "processIdentifier": pid,
        "appName": bundleID,
        "title": title,
        "playing": playing,
        "rate": playing ? 1.0 : 0.0,
        "timestampEpoch": sampledAt,
        "elected": elected,
    ]
}

private func sessions(_ entries: [String: Any]...) -> [NowPlaying] {
    NowPlayingCapture(json: ["sessions": entries])?.sessions ?? []
}

/// A wall-clock instant on the same scale as `sessionJSON`'s `sampledAt`.
private func at(_ epoch: Double) -> Date {
    Date(timeIntervalSince1970: epoch)
}

@Suite("Now-playing selection")
struct NowPlayingSelectionTests {
    @Test("A playing session is presented over the paused one macOS elects")
    func playingBeatsElected() {
        var selection = NowPlayingSelection()
        let chosen = selection.update(with: sessions(
            sessionJSON("music", playing: false, sampledAt: 2_000, elected: true),
            sessionJSON("browser", playing: true, sampledAt: 1_000)
        ))
        #expect(chosen?.app?.bundleIdentifier == "browser")
    }

    @Test("With nothing playing at first, the elected session is presented")
    func coldStartFallsBackToElected() {
        var selection = NowPlayingSelection()
        let chosen = selection.update(with: sessions(
            sessionJSON("browser", playing: false, sampledAt: 2_000),
            sessionJSON("music", playing: false, sampledAt: 1_000, elected: true)
        ))
        #expect(chosen?.app?.bundleIdentifier == "music")
    }

    @Test("A session that starts playing takes over from one already playing")
    func newlyStartedTakesOver() {
        var selection = NowPlayingSelection()
        _ = selection.update(with: sessions(
            sessionJSON("music", playing: true),
            sessionJSON("browser", playing: false)
        ))
        let chosen = selection.update(with: sessions(
            sessionJSON("music", playing: true),
            sessionJSON("browser", playing: true, sampledAt: 2_000)
        ))
        #expect(chosen?.app?.bundleIdentifier == "browser")
    }

    @Test("A session that appears already playing takes over when it began after the last update")
    func newSessionTakesOver() {
        var selection = NowPlayingSelection()
        _ = selection.update(with: sessions(sessionJSON("music", playing: true)), now: at(1_500))
        let chosen = selection.update(with: sessions(
            sessionJSON("music", playing: true),
            sessionJSON("browser", playing: true, sampledAt: 1_800)
        ), now: at(2_000))
        #expect(chosen?.app?.bundleIdentifier == "browser")
    }

    @Test("A playing session missing from one update returns without taking over or releasing a pin")
    func reappearingSessionIsNotAStart() {
        var selection = NowPlayingSelection()
        let both = sessions(
            sessionJSON("music", playing: true, sampledAt: 1_000),
            sessionJSON("browser", playing: true, sampledAt: 900)
        )
        #expect(selection.update(with: both, now: at(1_100))?.app?.bundleIdentifier == "music")
        selection.pin("music:100")
        #expect(selection.update(with: both, now: at(1_200))?.app?.bundleIdentifier == "music")

        // "browser" drops out of one update and comes back with the position it had all along.
        _ = selection.update(with: sessions(sessionJSON("music", playing: true, sampledAt: 1_000)), now: at(1_300))
        let chosen = selection.update(with: both, now: at(1_400))
        #expect(chosen?.app?.bundleIdentifier == "music")
        #expect(selection.pinnedID == "music:100")
    }

    @Test("The presented session returning from a missed update is presented again once the other stops")
    func presentedSessionSurvivesAMissedUpdate() {
        var selection = NowPlayingSelection()
        _ = selection.update(with: sessions(
            sessionJSON("music", playing: false, sampledAt: 500),
            sessionJSON("browser", playing: true, sampledAt: 1_000)
        ), now: at(1_100))
        // "browser" is missing once; the paused session fills in.
        #expect(selection.update(
            with: sessions(sessionJSON("music", playing: false, sampledAt: 500)), now: at(1_200)
        )?.app?.bundleIdentifier == "music")
        let chosen = selection.update(with: sessions(
            sessionJSON("music", playing: false, sampledAt: 500),
            sessionJSON("browser", playing: true, sampledAt: 1_000)
        ), now: at(1_300))
        #expect(chosen?.app?.bundleIdentifier == "browser")
    }

    @Test("The identity-less elected session is presented and replaced like any other")
    func electedOnlySession() {
        var selection = NowPlayingSelection()
        let elected = NowPlayingCapture(json: ["sessions": [
            ["title": "Track", "rate": 1.0, "elected": true, "timestampEpoch": 1_000.0],
        ]])?.sessions ?? []
        #expect(selection.update(with: elected)?.sessionID == "elected")
        #expect(selection.update(with: []) == nil)
        #expect(selection.currentID == nil)
        #expect(selection.update(with: sessions(sessionJSON("music", playing: false)))?.sessionID == "music:100")
    }

    @Test("Two sessions playing with neither newly started keep the presented one")
    func steadyStateIsSticky() {
        var selection = NowPlayingSelection()
        let both = sessions(
            sessionJSON("music", playing: true, sampledAt: 1_000),
            sessionJSON("browser", playing: true, sampledAt: 2_000)
        )
        #expect(selection.update(with: both)?.app?.bundleIdentifier == "browser")

        // "music" re-samples its position (a seek) without having stopped.
        let chosen = selection.update(with: sessions(
            sessionJSON("music", playing: true, sampledAt: 3_000),
            sessionJSON("browser", playing: true, sampledAt: 2_000)
        ))
        #expect(chosen?.app?.bundleIdentifier == "browser")
    }

    @Test("Pausing the presented session keeps it while nothing else plays")
    func pausedSessionStays() {
        var selection = NowPlayingSelection()
        _ = selection.update(with: sessions(
            sessionJSON("music", playing: false, elected: true),
            sessionJSON("browser", playing: true)
        ))
        let chosen = selection.update(with: sessions(
            sessionJSON("music", playing: false, sampledAt: 5_000, elected: true),
            sessionJSON("browser", playing: false)
        ))
        #expect(chosen?.app?.bundleIdentifier == "browser")
        #expect(chosen?.isPlaying == false)
    }

    @Test("Pausing the presented session hands over to one still playing")
    func pausedSessionYieldsToPlaying() {
        var selection = NowPlayingSelection()
        _ = selection.update(with: sessions(
            sessionJSON("music", playing: true, sampledAt: 1_000),
            sessionJSON("browser", playing: true, sampledAt: 2_000)
        ))
        let chosen = selection.update(with: sessions(
            sessionJSON("music", playing: true, sampledAt: 1_000),
            sessionJSON("browser", playing: false, sampledAt: 3_000)
        ))
        #expect(chosen?.app?.bundleIdentifier == "music")
    }

    @Test("When the presented session ends, a remaining one is presented")
    func endedSessionIsReplaced() {
        var selection = NowPlayingSelection()
        _ = selection.update(with: sessions(
            sessionJSON("music", playing: false),
            sessionJSON("browser", playing: true)
        ))
        let chosen = selection.update(with: sessions(sessionJSON("music", playing: false)))
        #expect(chosen?.app?.bundleIdentifier == "music")
        #expect(selection.update(with: []) == nil)
    }

    @Test("A picked session stays presented while another keeps playing")
    func pinHoldsOverPlaying() {
        var selection = NowPlayingSelection()
        let both = sessions(
            sessionJSON("music", playing: false),
            sessionJSON("browser", playing: true)
        )
        #expect(selection.update(with: both)?.app?.bundleIdentifier == "browser")

        selection.pin("music:100")
        #expect(selection.update(with: both)?.app?.bundleIdentifier == "music")
        #expect(selection.update(with: both)?.app?.bundleIdentifier == "music")
    }

    @Test("A picked session keeps its pin when it is the one that starts playing")
    func pinSurvivesItsOwnStart() {
        var selection = NowPlayingSelection()
        _ = selection.update(with: sessions(
            sessionJSON("music", playing: false),
            sessionJSON("browser", playing: true)
        ))
        selection.pin("music:100")
        let chosen = selection.update(with: sessions(
            sessionJSON("music", playing: true, sampledAt: 2_000),
            sessionJSON("browser", playing: true)
        ))
        #expect(chosen?.app?.bundleIdentifier == "music")
        #expect(selection.pinnedID == "music:100")
    }

    @Test("A different session starting to play releases the pin and takes over")
    func pinReleasedByAnotherStart() {
        var selection = NowPlayingSelection()
        _ = selection.update(with: sessions(
            sessionJSON("music", playing: false),
            sessionJSON("browser", playing: false)
        ))
        selection.pin("music:100")
        #expect(selection.update(with: sessions(
            sessionJSON("music", playing: false),
            sessionJSON("browser", playing: false)
        ))?.app?.bundleIdentifier == "music")

        let chosen = selection.update(with: sessions(
            sessionJSON("music", playing: false),
            sessionJSON("browser", playing: true, sampledAt: 2_000)
        ))
        #expect(chosen?.app?.bundleIdentifier == "browser")
        #expect(selection.pinnedID == nil)
    }

    @Test("A pin on a session that ended is released")
    func pinReleasedWhenSessionEnds() {
        var selection = NowPlayingSelection()
        selection.pin("music:100")
        let chosen = selection.update(with: sessions(sessionJSON("browser", playing: false)))
        #expect(chosen?.app?.bundleIdentifier == "browser")
        #expect(selection.pinnedID == nil)
    }

    @Test("The same app in two processes is two sessions")
    func processesAreDistinctSessions() {
        var selection = NowPlayingSelection()
        let chosen = selection.update(with: sessions(
            sessionJSON("browser", pid: 100, playing: false),
            sessionJSON("browser", pid: 200, playing: true)
        ))
        #expect(chosen?.app?.processID == 200)
    }
}

@Suite("Now-playing session parsing")
struct NowPlayingSessionParsingTests {
    @Test("Sessions are ordered by app name, whatever order they arrive in")
    func stableOrder() {
        let forward = sessions(sessionJSON("spotify", playing: false), sessionJSON("edge", playing: true))
        let reversed = sessions(sessionJSON("edge", playing: true), sessionJSON("spotify", playing: false))
        #expect(forward.map(\.sessionID) == ["edge:100", "spotify:100"])
        #expect(forward == reversed)
    }

    @Test("The explicit playing flag wins over the rate")
    func playingFlagWins() {
        var json = sessionJSON("music", playing: false)
        json["rate"] = 1.0
        #expect(NowPlaying(json: json)?.isPlaying == false)
    }

    @Test("Without a playing flag the rate decides")
    func rateDecidesWithoutFlag() {
        var json = sessionJSON("music", playing: true)
        json["playing"] = nil
        #expect(NowPlaying(json: json)?.isPlaying == true)
        json["rate"] = 0.0
        #expect(NowPlaying(json: json)?.isPlaying == false)
    }

    @Test("A session with no app identity parses as the elected session")
    func identityLessSession() {
        let parsed = NowPlaying(json: ["title": "Track", "rate": 1.0, "elected": true])
        #expect(parsed?.app == nil)
        #expect(parsed?.sessionID == "elected")
        #expect(parsed?.isElected == true)
    }

    @Test("A session naming a malformed app is dropped")
    func malformedAppDropped() {
        #expect(NowPlaying(json: ["title": "Track", "bundleIdentifier": "", "processIdentifier": 5]) == nil)
        #expect(NowPlaying(json: ["title": "Track", "bundleIdentifier": "app", "processIdentifier": 0]) == nil)
        #expect(NowPlaying(json: ["title": "Track", "bundleIdentifier": "app"]) == nil)
        #expect(NowPlaying(json: ["title": "Track", "bundleIdentifier": 7, "processIdentifier": 5]) == nil)
        #expect(NowPlaying(json: [
            "title": "Track",
            "bundleIdentifier": String(repeating: "a", count: 256),
            "processIdentifier": 5,
        ]) == nil)
    }

    @Test("Untitled entries, non-object entries, and repeats of a session are skipped")
    func unusableEntriesSkipped() {
        let parsed = NowPlayingCapture(json: ["sessions": [
            sessionJSON("music", title: "First", playing: true),
            sessionJSON("music", title: "Repeat", playing: false),
            ["bundleIdentifier": "silent", "processIdentifier": 9],
            "not an object",
        ] as [Any]])
        #expect(parsed?.sessions.map(\.title) == ["First"])
    }

    @Test("The session cap counts usable sessions, so unusable entries ahead of them cost nothing")
    func sessionCountIsCapped() {
        let untitled: [[String: Any]] = (1...20).map { ["bundleIdentifier": "idle\($0)", "processIdentifier": $0] }
        let titled = (1...20).map { sessionJSON("app\($0)", pid: $0, playing: false) }
        let parsed = NowPlayingCapture(json: ["sessions": untitled + titled])
        #expect(parsed?.sessions.count == NowPlayingCapture.maxSessions)
    }

    @Test("A payload without a session list is no capture, distinct from an empty list")
    func missingListIsNoCapture() {
        #expect(NowPlayingCapture(json: [:]) == nil)
        #expect(NowPlayingCapture(json: ["sessions": "nope"]) == nil)
        #expect(NowPlayingCapture(json: ["sessions": [Any]()])?.sessions.isEmpty == true)
    }

    @Test("The capture time is read when it is a usable epoch")
    func captureTime() {
        #expect(NowPlayingCapture(json: ["sessions": [Any](), "capturedAt": 1_000.0])?.capturedAt == at(1_000))
        #expect(NowPlayingCapture(json: ["sessions": [Any]()])?.capturedAt == nil)
        #expect(NowPlayingCapture(json: ["sessions": [Any](), "capturedAt": -5.0])?.capturedAt == nil)
    }

    @Test("Overlong text fields are cut to the cap")
    func textIsBounded() {
        var json = sessionJSON("music", title: String(repeating: "t", count: 5_000), playing: true)
        json["artist"] = String(repeating: "a", count: 5_000)
        json["appName"] = String(repeating: "n", count: 5_000)
        let parsed = NowPlaying(json: json)
        #expect(parsed?.title.count == NowPlaying.maxTextLength)
        #expect(parsed?.artist?.count == NowPlaying.maxTextLength)
        #expect(parsed?.appName?.count == NowPlaying.maxTextLength)
    }

    @Test("The session list detail line joins artist and app")
    func detailLine() {
        var json = sessionJSON("Spotify", playing: true)
        json["artist"] = "Artist"
        #expect(MediaSessionList.detail(for: NowPlaying(json: json)!) == "Artist · Spotify")
        json["artist"] = nil
        #expect(MediaSessionList.detail(for: NowPlaying(json: json)!) == "Spotify")
    }
}

@Suite("Transport command routing")
struct TransportCommandRoutingTests {
    @Test("Every kind of session has a command route on this OS")
    func routesExist() throws {
        let bridge = try #require(MediaRemoteBridge())
        let other = try #require(NowPlaying(json: sessionJSON("music", playing: true)))
        let elected = try #require(NowPlaying(json: sessionJSON("music", playing: true, elected: true)))
        let identityLess = try #require(NowPlaying(json: ["title": "Track", "elected": true]))
        #expect(bridge.canSend(to: other))
        #expect(bridge.canSend(to: elected))
        #expect(bridge.canSend(to: identityLess))
    }
}

@Suite("Artwork decoding")
struct MediaArtworkDecoderTests {
    private func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test("Artwork larger than the display size is decoded down to it")
    func downsamples() throws {
        let image = try #require(MediaArtworkDecoder.image(from: png(width: 2_000, height: 1_000)))
        #expect(image.size.width == 512)
        #expect(image.size.height == 256)
    }

    @Test("Artwork already within the display size keeps its dimensions")
    func keepsSmallArtwork() throws {
        let image = try #require(MediaArtworkDecoder.image(from: png(width: 150, height: 83)))
        #expect(image.size.width == 150)
        #expect(image.size.height == 83)
    }

    @Test("An image declaring more pixels than the cap is refused")
    func refusesOversizedCanvas() throws {
        // 9000 x 9000 = 81 million pixels, over the 64 million cap.
        #expect(MediaArtworkDecoder.image(from: try png(width: 9_000, height: 9_000)) == nil)
    }

    @Test("Bytes that are not an image decode to nothing")
    func rejectsNonImage() {
        #expect(MediaArtworkDecoder.image(from: Data("not an image".utf8)) == nil)
    }
}

@Suite("Per-app transport commands")
struct AppCommandSurfaceTests {
    @Test("A request can be built for a specific app's session on this OS")
    func requestBuilds() {
        let surface = MediaRemoteBridge.AppCommandSurface()
        #expect(surface != nil)
        let app = NowPlayingApp(
            bundleIdentifier: "com.example.player",
            processID: ProcessInfo.processInfo.processIdentifier)
        #expect(surface?.makeRequest(for: app) != nil)
    }
}
