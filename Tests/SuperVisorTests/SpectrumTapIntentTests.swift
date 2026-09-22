import AppKit
import Testing

@testable import SuperVisor

@Suite("Spectrum tap intent")
struct SpectrumTapIntentTests {
    @Test("Disabled or failed always stops, whatever is playing")
    func offOrFailedStops() {
        #expect(SpectrumTapIntent.resolve(enabled: false, unavailable: false, playing: true, localOutputRunning: true) == .stop)
        #expect(SpectrumTapIntent.resolve(enabled: true, unavailable: true, playing: true, localOutputRunning: true) == .stop)
    }

    @Test("Playing with sound produced here captures")
    func playingWithLocalOutputCaptures() {
        #expect(SpectrumTapIntent.resolve(enabled: true, unavailable: false, playing: true, localOutputRunning: true) == .capture)
    }

    @Test("Playing while no process here produces sound lingers instead of capturing silence")
    func playingElsewhereLingers() {
        #expect(SpectrumTapIntent.resolve(enabled: true, unavailable: false, playing: true, localOutputRunning: false) == .linger)
    }

    @Test("Unknown local output falls back to the playing flag")
    func unknownOutputTrustsPlaying() {
        #expect(SpectrumTapIntent.resolve(enabled: true, unavailable: false, playing: true, localOutputRunning: nil) == .capture)
        #expect(SpectrumTapIntent.resolve(enabled: true, unavailable: false, playing: false, localOutputRunning: nil) == .linger)
    }

    @Test("Paused lingers even while other audio plays here")
    func pausedLingers() {
        #expect(SpectrumTapIntent.resolve(enabled: true, unavailable: false, playing: false, localOutputRunning: true) == .linger)
    }
}

@Suite("Spectrum tap action")
struct SpectrumTapActionTests {
    @Test("Stop and linger pass straight through")
    func passThrough() {
        #expect(SpectrumTapAction.resolve(intent: .stop, silentPlayingFor: 60, settlePending: true) == .stop)
        #expect(SpectrumTapAction.resolve(intent: .linger, silentPlayingFor: nil, settlePending: false) == .linger)
    }

    @Test("A play press whose sound follows within moments starts at once")
    func promptPlayStartsImmediately() {
        #expect(SpectrumTapAction.resolve(intent: .capture, silentPlayingFor: nil, settlePending: false) == .start)
        #expect(SpectrumTapAction.resolve(intent: .capture, silentPlayingFor: 1, settlePending: false) == .start)
    }

    @Test("Sound appearing after a long silent stretch of playing settles first")
    func soundAfterSilentPlayingSettles() {
        #expect(SpectrumTapAction.resolve(intent: .capture, silentPlayingFor: 3, settlePending: false) == .settleThenStart)
        #expect(SpectrumTapAction.resolve(intent: .capture, silentPlayingFor: 600, settlePending: false) == .settleThenStart)
    }

    @Test("A reconcile during a pending settle keeps settling instead of starting early")
    func pendingSettleIsNotCutShort() {
        #expect(SpectrumTapAction.resolve(intent: .capture, silentPlayingFor: nil, settlePending: true) == .settleThenStart)
    }
}

@MainActor
@Suite("Hover monitor event location")
struct HoverMonitorLocationTests {
    @Test("An event with no window reports its location as screen coordinates")
    func windowlessEventIsScreenSpace() throws {
        let location = NSPoint(x: 1234.5, y: 67.25)
        let event = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        #expect(event.window == nil)
        #expect(HoverMonitor.screenLocation(of: event) == location)
    }
}
