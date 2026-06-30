import AppKit
import Quartz

/// Drives the shared `QLPreviewPanel` for a set of staged file URLs. `QLPreviewPanel` pulls
/// its content from a data source and is steered by a delegate; both live here. The panel is
/// a shared singleton, so this controller installs itself as the current data source/delegate
/// while previewing and tears that down when finished.
@MainActor
final class QuickLookController: NSObject, @MainActor QLPreviewPanelDataSource, @MainActor QLPreviewPanelDelegate {
    /// URLs currently being previewed, in display order.
    private(set) var urls: [URL] = []

    /// Begin previewing `urls`, optionally starting on `initialIndex`. Brings the shared
    /// panel forward and binds this controller as its data source/delegate.
    func preview(_ urls: [URL], startingAt initialIndex: Int = 0) {
        guard !urls.isEmpty else { return }
        self.urls = urls

        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.currentPreviewItemIndex = min(initialIndex, max(0, urls.count - 1))
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
            panel.currentPreviewItemIndex = min(initialIndex, max(0, urls.count - 1))
        }
    }

    /// Close the panel if this controller owns it.
    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.dataSource === self
        else { return }
        panel.orderOut(nil)
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Forward arrow keys to let the panel navigate between items natively.
        false
    }
}
