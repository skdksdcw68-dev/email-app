import SwiftUI
import UIKit
import WebKit

/// Renders an email's real HTML, so images, links and layout survive.
///
/// Stripping to plain text is fine for classifying a message and for the list
/// preview, but it throws away everything that makes an email look like an
/// email. This shows what the sender actually sent.
///
/// JavaScript is disabled. Email HTML has no business executing anything, and
/// leaving it on turns every message into an untrusted script host.
struct HTMLMessageView: UIViewRepresentable {
    let html: String
    /// Reported back so the web view can size itself inside a ScrollView
    /// instead of scrolling within its own fixed box.
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(Self.wrap(html), baseURL: nil)
    }

    /// A viewport, a readable type scale, and images clamped to the width.
    /// `color-scheme: light dark` lets a message that declares no colours
    /// follow the system appearance instead of glowing white at night.
    private static func wrap(_ html: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body {
            margin: 0;
            padding: 0;
            font: -apple-system-body;
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 17px;
            line-height: 1.45;
            word-break: break-word;
            overflow-wrap: anywhere;
            -webkit-text-size-adjust: 100%;
            background: transparent;
          }
          img { max-width: 100% !important; height: auto !important; }
          table { max-width: 100% !important; }
          pre, code { white-space: pre-wrap; word-break: break-word; }
          blockquote {
            margin: 0 0 0 12px;
            padding-left: 10px;
            border-left: 3px solid rgba(128,128,128,0.35);
            color: rgba(128,128,128,1);
          }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: HTMLMessageView
        var loadedHTML: String?

        init(_ parent: HTMLMessageView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                guard let value = result as? CGFloat else { return }
                Task { @MainActor in
                    // Only grow. Intermediate layout passes report smaller
                    // heights and would make the message jump as it settles.
                    if value > self.parent.height {
                        self.parent.height = value
                    }
                }
            }
        }

        /// Taps open in Safari rather than navigating inside the message.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url
            else {
                decisionHandler(.allow)
                return
            }
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}
