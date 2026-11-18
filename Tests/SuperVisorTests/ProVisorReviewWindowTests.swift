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
///
/// **`NSApplication.run()` is entered only in a child process** (an exit test), and the child
/// ends from inside that loop. The process that runs the suite keeps its main thread in one
/// outer `CFRunLoopRun`, and the Swift runtime calls `exit(0)` the moment that returns. Once
/// AppKit's event loop has run in a process, its display cycle wakes the main run loop with
/// `CFRunLoopStop` whenever a window has work; with the event loop gone that stops the outer
/// loop, and the whole test run ends with status 0 and no summary line, every unfinished test
/// unreported.
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

    /// The status the child exits with from its last step. Any other status means the steps
    /// did not all run.
    private static let ranEveryStep: CInt = 23

    /// Runs steps one at a time inside the application's own event loop, a few display cycles
    /// apart. The last step ends the process: `run()` returns only if the loop was stopped
    /// before the steps were through.
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
            remaining.popFirst()?()
        }
    }

    /// The opacity the window server composites the window at, or nil while it is off screen.
    private static func compositedAlpha(of window: NSWindow) -> Double? {
        let listed = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(window.windowNumber)
        ) as? [[CFString: Any]]
        guard let entry = listed?.first, entry[kCGWindowIsOnscreen] as? Bool == true else {
            return nil
        }
        return entry[kCGWindowAlpha] as? Double
    }

    /// Shows the window, changes what it holds, and checks its height at each step, all inside
    /// the application's event loop, then exits with `ranEveryStep`.
    private static func followContentHeightInsideTheLoop() throws {
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

        // Sized to its content before it is ever shown.
        let reading = content.frame.height
        #expect(content.frame.width == ProVisorReviewView.width)
        #expect(reading > 100)

        var top: CGFloat = 0
        var typing: CGFloat = 0
        Stepper([
            { window.makeKeyAndOrderFront(nil) },
            {
                // Read once shown: AppKit may move a window as it comes on screen. A nil
                // reading means the window never reached the screen.
                top = window.frame.maxY
                #expect(compositedAlpha(of: window) == 0)
                #expect(content.frame.height == reading)
                model.isTyping = true
            },
            {
                typing = content.frame.height
                #expect(typing < reading)
                model.text = String(repeating: "A long instruction that wraps. ", count: 12)
            },
            {
                #expect(content.frame.height > typing)
                model.isTyping = false
            },
            {
                #expect(content.frame.height == reading)
                // The title bar stays put; the window grows and shrinks at its bottom edge.
                #expect(window.frame.maxY == top)
                window.close()
                exit(ranEveryStep)
            },
        ]).run()
    }

    @Test(
        "The window follows its content's height, growing and shrinking, in a running app",
        .timeLimit(.minutes(1))
    )
    func followsContentHeight() async {
        await #expect(processExitsWith: .exitCode(Self.ranEveryStep)) {
            try await MainActor.run {
                try ProVisorReviewWindowTests.followContentHeightInsideTheLoop()
            }
        }
    }
}
