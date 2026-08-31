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

        // Height comes from observing contentSize, not from evaluateJavaScript.
        // JavaScript is disabled above, which blocks host-side evaluation too --
        // the measurement would never come back and every message would render
        // in a 40pt sliver.
        context.coordinator.observe(webView)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        return webView
    }

    /// Whether this message brings its own design.
    ///
    /// A branded template sets its own backgrounds and colours inline, and
    /// those beat any stylesheet we add -- inverting it produces white text on
    /// the sender's own white panel. A plain message declares none of that and
    /// can safely follow the system appearance.
    static func isDesigned(_ html: String) -> Bool {
        let markers = ["bgcolor=", "background-color", "background:", "<table"]
        let lowered = html.lowercased()
        return markers.contains { lowered.contains($0) }
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html

        let designed = Self.isDesigned(html)
        // A designed email keeps its white canvas; a plain one gets a
        // transparent background so the app's own surface shows through.
        webView.isOpaque = designed
        webView.backgroundColor = designed ? .white : .clear
        webView.scrollView.backgroundColor = designed ? .white : .clear

        webView.loadHTMLString(Self.wrap(html, designed: designed), baseURL: nil)
    }

    /// A viewport, a readable type scale, and images clamped to the width.
    /// `color-scheme: light dark` lets a message that declares no colours
    /// follow the system appearance instead of glowing white at night.
    private static func wrap(_ html: String, designed: Bool) -> String {
        // Only a plain message gets the dark treatment. See isDesigned.
        let adaptive = designed ? "" : """
          @media (prefers-color-scheme: dark) {
            html, body { background: transparent !important; color: #F2F2F7 !important; }
            p, div, span, td, li, h1, h2, h3, h4 { color: #F2F2F7 !important; }
            a { color: #6EA8FE !important; }
            blockquote { color: #A0A0A8 !important; border-left-color: rgba(255,255,255,0.25) !important; }
          }
        """

        let base = designed
            ? "html, body { background: #ffffff; color: #111111; }"
            : "html, body { background: transparent; color: #111111; }"

        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          \(base)
          body {
            margin: 0;
            padding: \(designed ? 14 : 0)px;
            font-family: -apple-system, system-ui, sans-serif;
            font-size: 17px;
            line-height: 1.45;
            word-break: break-word;
            overflow-wrap: anywhere;
            -webkit-text-size-adjust: 100%;
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
          \(adaptive)
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: HTMLMessageView
        var loadedHTML: String?
        private var observation: NSKeyValueObservation?

        init(_ parent: HTMLMessageView) { self.parent = parent }

        deinit { observation?.invalidate() }

        func observe(_ webView: WKWebView) {
            observation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
                guard let self else { return }
                let measured = scrollView.contentSize.height
                Task { @MainActor in
                    // Only grow. Intermediate layout passes report smaller
                    // heights and the message would jump as it settles.
                    if measured > self.parent.height {
                        self.parent.height = measured
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
