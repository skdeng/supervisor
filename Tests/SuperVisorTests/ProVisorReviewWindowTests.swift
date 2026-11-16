import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SuperVisor

/// The review's content changes height as the selection changes what is shown, and the window
/// is not resizable by hand, so a window that kept its first size would clip the taller states.
///
/// The steps run inside `NSApplication.run()`, the event loop the window lives under in the
/// app. This covers that the window tracks its content. It does not reproduce the layout
/// exception described on `FittedWindow`, which a hosting controller with sizing options
/// raises in the app and not in this process.
@Suite("ProVisor review window", .serialized)
@MainActor
struct ProVisorReviewWindowTests {
    private final class Model: ObservableObject {
        @Published var isTyping = false
        @Published var text = ""
    }

    /// Shaped like the review: wrapping text, then either more text or a focused text field.
    private struct Probe: View {
        @ObservedObject var model: Model
        @FocusState private var focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(repeating: "Why this was proposed. ", count: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if model.isTyping {
                    TextField("What should it do?", text: $model.text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(3...8)
                        .focused($focused)
                        .onAppear { focused = true }
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.pink, lineWidth: focused ? 1 : 0)
                        )
                    Text(focused ? "Carried out as you write it." : "Not focused")
                        .font(.caption)
                } else {
                    Text(String(repeating: "What approving does. ", count: 30))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(width: ProVisorReviewView.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Runs steps one at a time inside the application's own event loop, a few display cycles
    /// apart, then stops the loop.
    @MainActor
    private final class Stepper: NSObject {
        private var remaining: ArraySlice<@MainActor () -> Void>

        init(_ steps: [@MainActor () -> Void]) {
            remaining = steps[...]
        }

        func run() {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let timer = Timer(
                timeInterval: 0.25,
                target: self,
                selector: #selector(tick(_:)),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            application.run()
        }

        @objc private func tick(_ timer: Timer) {
            if let step = remaining.popFirst() {
                step()
                return
            }
            timer.invalidate()
            NSApplication.shared.stop(nil)
            // `stop` takes effect only once another event comes through the loop.
            if let wake = NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: 0
            ) {
                NSApplication.shared.postEvent(wake, atStart: false)
            }
        }
    }

    /// The opacity the window server composites the window at, or nil while it is off screen.
    private func compositedAlpha(of window: NSWindow) -> Double? {
        let listed = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(window.windowNumber)
        ) as? [[CFString: Any]]
        guard let entry = listed?.first, entry[kCGWindowIsOnscreen] as? Bool == true else {
            return nil
        }
        return entry[kCGWindowAlpha] as? Double
    }

    @Test("The window follows its content's height, growing and shrinking, in a running app")
    func followsContentHeight() throws {
        let model = Model()
        let window = FittedWindow(
            width: ProVisorReviewView.width,
            content: AnyView(Probe(model: model))
        )
        let content = try #require(window.contentView)
        // The window has to be on screen for its layout to run as it does in the app, and AppKit
        // pulls a titled window back onto a display wherever its origin is set. Transparency
        // is what keeps it out of sight of whoever is at the machine while the suite runs.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        defer { window.close() }

        // Sized to its content before it is ever shown.
        let reading = content.frame.height
        #expect(content.frame.width == ProVisorReviewView.width)
        #expect(reading > 100)

        var heights: [CGFloat] = []
        var top: CGFloat = 0
        var alphaOnScreen: Double?
        Stepper([
            { window.makeKeyAndOrderFront(nil) },
            {
                // Read once shown: AppKit may move a window as it comes on screen.
                top = window.frame.maxY
                alphaOnScreen = compositedAlpha(of: window)
                heights.append(content.frame.height)
                model.isTyping = true
            },
            {
                heights.append(content.frame.height)
                model.text = String(repeating: "A long instruction that wraps. ", count: 12)
            },
            {
                heights.append(content.frame.height)
                model.isTyping = false
            },
            { heights.append(content.frame.height) },
        ]).run()

        let (shown, typing, typed, back) = try #require(
            heights.count == 4 ? (heights[0], heights[1], heights[2], heights[3]) : nil
        )
        // A nil reading means the window never reached the screen.
        #expect(alphaOnScreen == 0)
        #expect(shown == reading)
        #expect(typing < reading)
        #expect(typed > typing)
        #expect(back == reading)
        // The title bar stays put; the window grows and shrinks at its bottom edge.
        #expect(window.frame.maxY == top)
    }
}
