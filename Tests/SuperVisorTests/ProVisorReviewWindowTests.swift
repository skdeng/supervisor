import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SuperVisor

/// The review's content changes height as the selection changes what is shown, and the window
/// is not resizable by hand, so a window that kept its first size would clip the taller states.
@Suite("ProVisor review window")
@MainActor
struct ProVisorReviewWindowTests {
    private final class Model: ObservableObject {
        @Published var height: CGFloat = 150
    }

    private struct Probe: View {
        @ObservedObject var model: Model

        var body: some View {
            Color.clear.frame(width: ProVisorReviewView.width, height: model.height)
        }
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.layoutIfNeeded()
        }
    }

    @Test("The window's content area follows the content's height, growing and shrinking")
    func followsContentHeight() throws {
        let model = Model()
        let (window, _) = ProVisorReviewWindow.makeWindow(rootView: AnyView(Probe(model: model)))
        let content = try #require(window.contentView)

        settle(window)
        #expect(content.frame.size == CGSize(width: ProVisorReviewView.width, height: 150))

        model.height = 420
        settle(window)
        #expect(content.frame.size == CGSize(width: ProVisorReviewView.width, height: 420))

        model.height = 90
        settle(window)
        #expect(content.frame.size == CGSize(width: ProVisorReviewView.width, height: 90))
    }
}
