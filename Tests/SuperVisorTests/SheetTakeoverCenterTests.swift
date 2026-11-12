import SwiftUI
import Testing

@testable import SuperVisor

@MainActor
@Suite("Sheet takeover", .serialized)
struct SheetTakeoverCenterTests {
    private let center = SheetTakeoverCenter.shared

    private func present(_ id: String) {
        center.present(id: id, title: id, content: AnyView(EmptyView()))
    }

    @Test("Presenting replaces whatever was presented")
    func presentingReplaces() {
        defer { center.dismiss() }
        present("first")
        present("second")
        #expect(center.current?.id == "second")
    }

    @Test("A presenter dismisses only its own takeover")
    func scopedDismissLeavesOthers() {
        defer { center.dismiss() }
        present("second")
        center.dismiss(id: "first")
        #expect(center.current?.id == "second")
        center.dismiss(id: "second")
        #expect(center.current == nil)
    }

    @Test("Closing the sheet dismisses the takeover")
    func sheetCloseDismisses() {
        defer { center.dismiss() }
        let engine = NotchEngine()
        engine.toggleSheet()
        #expect(engine.state == .expanded)
        present("first")
        engine.toggleSheet()
        #expect(engine.state != .expanded)
        #expect(center.current == nil)
    }

    @Test("An unscoped dismiss clears any takeover")
    func dismissClears() {
        present("first")
        center.dismiss()
        #expect(center.current == nil)
    }
}
