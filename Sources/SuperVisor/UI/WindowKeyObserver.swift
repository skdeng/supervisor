import AppKit
import SwiftUI

extension View {
    /// Calls `action` each time the window this view is in becomes key, and at no other time:
    /// a closed window, or another of the app's windows taking focus, calls nothing.
    func onWindowBecomesKey(_ action: @escaping @MainActor () -> Void) -> some View {
        background(WindowKeyObserver(action: action))
    }
}

private struct WindowKeyObserver: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> WindowKeyObservingView {
        let view = WindowKeyObservingView()
        view.action = action
        return view
    }

    func updateNSView(_ view: WindowKeyObservingView, context: Context) {
        view.action = action
    }
}

/// Watches the window it is placed in, re-pointing the watch whenever it moves to another.
private final class WindowKeyObservingView: NSView {
    var action: (@MainActor () -> Void)?
    private var observation: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        observation = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.action?()
            }
        }
    }

    private func stopObserving() {
        if let observation {
            NotificationCenter.default.removeObserver(observation)
        }
        observation = nil
    }

    isolated deinit {
        stopObserving()
    }
}
