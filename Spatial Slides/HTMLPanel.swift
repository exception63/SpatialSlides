//
//  HTMLPanel.swift
//  Spatial Slides
//
//  The far 主屏: the show's HTML deck in single-slide present mode, inside a
//  WKWebView so the real fonts/layout/animations are preserved exactly. Each page
//  change calls deckAPI.setActive(page). (The transcript is a native board now —
//  see StageView.TranscriptBoard — so this panel only ever plays the deck.)
//

import SwiftUI
import WebKit

struct HTMLPanel: UIViewRepresentable {
    let fileURL: URL
    var page: Int = 0

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        context.coordinator.loadedURL = fileURL
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != fileURL {
            context.coordinator.ready = false
            webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
            context.coordinator.loadedURL = fileURL
        }
        context.coordinator.setActive(page)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var loadedURL: URL?
        var ready = false
        private var lastPage = -1

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            lastPage = -1
            // Enter single-slide present mode ('p' → body.present, chrome hidden).
            webView.evaluateJavaScript(HTMLPanel.enterPresentJS, completionHandler: nil)
        }

        func setActive(_ page: Int) {
            guard ready, let webView, page != lastPage else { return }
            lastPage = page
            webView.evaluateJavaScript("window.deckAPI && window.deckAPI.setActive(\(page));", completionHandler: nil)
        }
    }

    static let enterPresentJS = """
    (function () {
      try {
        if (document.body && !document.body.classList.contains('present')) {
          document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'p', bubbles: true, cancelable: true }));
        }
      } catch (e) {}
    })();
    """
}
