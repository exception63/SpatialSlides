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
        // The deck is a live WKWebView composited at ~2.6 m wide. Its per-slide entrance
        // animations (`.anim-play .head/.fill/.bhbar/...`) re-rasterize that huge surface
        // every frame for ~0.6 s on each page change — the exact "transition janks on
        // content-heavy slides, smooth on simple ones" the user saw. Collapse all deck
        // animations/transitions to instant, drop backdrop blur, and install a present-
        // mode-only fast page switcher that avoids updating the hidden outline/thumb UI.
        config.userContentController.addUserScript(
            WKUserScript(source: HTMLPanel.performanceJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        private var requestedPage = 0

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            lastPage = -1
            // Enter single-slide present mode directly, with the deck chrome hidden.
            webView.evaluateJavaScript(HTMLPanel.enterPresentJS) { [weak self] _, _ in
                guard let self else { return }
                self.setActive(self.requestedPage)
            }
        }

        func setActive(_ page: Int) {
            requestedPage = page
            guard ready, let webView, page != lastPage else { return }
            lastPage = page
            webView.evaluateJavaScript(HTMLPanel.setActiveJS(page), completionHandler: nil)
        }
    }

    /// Collapses every deck animation/transition to ~instant, removes backdrop blur, and
    /// exposes a fast present-mode switcher. The fast path does not toggle the deck's
    /// `.active` class on every page, so the deck's MutationObserver/count-up build script
    /// does not run while the immersive carousel is moving.
    static let performanceJS = """
    (function () {
      try {
        var css = '*,*::before,*::after{animation-duration:0.001s!important;animation-delay:0s!important;transition-duration:0.001s!important;transition-delay:0s!important;backdrop-filter:none!important;-webkit-backdrop-filter:none!important;}';
        var s = document.createElement('style');
        s.id = '__spatial_dampen__';
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);

        window.__spatialSlides = null;
        window.__spatialLast = -1;

        function slides() {
          return window.__spatialSlides ||
            (window.__spatialSlides = Array.prototype.slice.call(document.querySelectorAll('.deck>.slide-wrap>.slide')));
        }

        window.__spatialEnterPresent = function () {
          if (document.body) document.body.classList.add('present');
          var list = slides();
          for (var i = 0; i < list.length; i++) {
            list[i].classList.remove('active', 'anim-play');
            list[i].style.display = 'none';
          }
          window.__spatialLast = -1;
        };

        window.__spatialSetActive = function (n) {
          var list = slides();
          if (!list.length) return -1;
          var idx = Math.max(0, Math.min(list.length - 1, n | 0));
          if (document.body && !document.body.classList.contains('present')) {
            document.body.classList.add('present');
          }

          var sc = Math.min(window.innerWidth / 1920, window.innerHeight / 1080) * 0.98;
          var last = window.__spatialLast;
          if (last < 0) {
            for (var i = 0; i < list.length; i++) list[i].style.display = i === idx ? 'flex' : 'none';
          } else if (last !== idx && list[last]) {
            list[last].style.display = 'none';
          }

          list[idx].style.setProperty('--sc', sc);
          list[idx].style.display = 'flex';
          window.__spatialLast = idx;
          return idx;
        };
      } catch (e) {}
    })();
    """

    static let enterPresentJS = """
    (function () {
      try {
        if (window.__spatialEnterPresent) window.__spatialEnterPresent();
        else if (document.body) document.body.classList.add('present');
      } catch (e) {}
    })();
    """

    static func setActiveJS(_ page: Int) -> String {
        """
        (function () {
          try {
            if (window.__spatialSetActive) return window.__spatialSetActive(\(page));
            if (window.deckAPI && window.deckAPI.setActive) return window.deckAPI.setActive(\(page));
          } catch (e) {}
        })();
        """
    }
}
