import Testing

@testable import SuperVisor

@Suite("Peek resumed after the sheet closes")
@MainActor
struct PeekResumeTests {
    @Test("A close of the sheet with a banner supplied resumes the peek, and nothing else does")
    func decision() {
        let table: [(NotchState, NotchState, Bool, Bool)] = [
            (.expanded, .compact, true, true),
            (.expanded, .idle, true, true),
            (.expanded, .idle, false, false),
            (.expanded, .expanded, true, false),
            (.compact, .idle, true, false),
            (.idle, .compact, true, false),
            (.compact, .expanded, true, false),
        ]
        for (current, requested, banner, resumes) in table {
            let decided = NotchEngine.resumesPeek(leaving: current, for: requested, bannerSupplied: { banner })
            #expect(decided == resumes, "\(current) to \(requested), banner \(banner)")
        }
    }

    @Test("Whether a banner is supplied is asked only when the sheet is closing")
    func bannerAskedOnlyOnClose() {
        var asked = 0
        _ = NotchEngine.resumesPeek(leaving: .compact, for: .idle) { asked += 1; return true }
        _ = NotchEngine.resumesPeek(leaving: .expanded, for: .expanded) { asked += 1; return true }
        #expect(asked == 0)
        _ = NotchEngine.resumesPeek(leaving: .expanded, for: .idle) { asked += 1; return true }
        #expect(asked == 1)
    }

    @Test("Closing the sheet with no banner supplied leaves no peek")
    func closeWithoutBanner() {
        let engine = NotchEngine()
        engine.toggleSheet()
        #expect(engine.state == .expanded)
        engine.toggleSheet()
        #expect(engine.state == .idle)
        #expect(!engine.isPeeking)
    }
}
