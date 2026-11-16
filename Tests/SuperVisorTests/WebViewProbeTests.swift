import AppKit
import Foundation
import Testing
import WebKit

@testable import SuperVisor

@Suite("Web view under the test runner", .serialized)
@MainActor
struct WebViewProbeTests {
    private final class Loader: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Bool, Never>?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume(returning: true)
            continuation = nil
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            continuation?.resume(returning: false)
            continuation = nil
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            continuation?.resume(returning: false)
            continuation = nil
        }
    }

    @Test("A page loads and script runs in a web view that is never shown", .timeLimit(.minutes(1)))
    func loadsAndEvaluates() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        let loader = Loader()
        webView.navigationDelegate = loader

        let loaded = await withCheckedContinuation { continuation in
            loader.continuation = continuation
            webView.loadHTMLString(
                "<html><body><form><input id='u' name='username'><input id='p' type='password'></form></body></html>",
                baseURL: URL(string: "https://example.test/")
            )
        }
        #expect(loaded)

        let filled = try await webView.callAsyncJavaScript(
            "document.getElementById('p').value = secret; return document.getElementById('p').value.length",
            arguments: ["secret": "hunter2"],
            in: nil,
            contentWorld: .defaultClient
        )
        #expect(filled as? Int == 7)
    }
}
