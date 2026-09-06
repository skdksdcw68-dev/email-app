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
///
/// ## Fitting the phone
///
/// Most designed mail is laid out for 600px. Squeezed into a phone-width
/// viewport it did not get narrower, it got *clipped* -- fixed-width tables
/// ran off the right edge, buttons lost their ends -- and the type stayed at
/// desktop size, so everything read as too big. Gmail and Apple Mail render
/// at the email's own width and scale the whole thing down to fit. So does
/// this: a first pass at device width measures the natural width, and if the
/// mail is wider, a second pass declares that width as the viewport and
/// WebKit scales it to fit.
///
/// ## Dark mode
///
/// A designed email brings its own colours -- white panels, inline `bgcolor`
/// -- and no stylesheet of ours beats an inline attribute. Gmail darkens
/// those anyway, and so does this: in dark mode the document is inverted with
/// `filter`, hue-rotated back so a blue button stays blue, and every image
/// inverted again so photographs come out the right way round.
/// `invert(0.92)` rather than `invert(1)`: white becomes Gmail's dark grey
/// rather than pure black, and black text comes out off-white.
struct HTMLMessageView: UIViewRepresentable {
    let html: String
    /// Reported back so the web view can size itself inside a ScrollView
    /// instead of scrolling within its own fixed box.
    @Binding var height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    /// How far a wide email may be scaled down. Past this the type is
    /// unreadable anyway, and the rest overflows as it did before.
    static let maxScaleDown: CGFloat = 2

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
    /// those beat any stylesheet we add. A plain message declares none of that
    /// and can simply follow the system appearance; a designed one is
    /// inverted instead. See `wrap`.
    static func isDesigned(_ html: String) -> Bool {
        let markers = ["bgcolor=", "background-color", "background:", "<table"]
        let lowered = html.lowercased()
        return markers.contains { lowered.contains($0) }
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let dark = colorScheme == .dark
        let coordinator = context.coordinator
        guard coordinator.loadedHTML != html || coordinator.loadedDark != dark else { return }
        coordinator.loadedHTML = html
        coordinator.loadedDark = dark

        let designed = Self.isDesigned(html)
        // A designed email in light mode keeps its white canvas. Everything
        // else is transparent so the app's own surface shows through -- in
        // dark mode that surface is what the inverted email sits on.
        let whiteCanvas = designed && !dark
        webView.isOpaque = whiteCanvas
        webView.backgroundColor = whiteCanvas ? .white : .clear
        webView.scrollView.backgroundColor = whiteCanvas ? .white : .clear

        coordinator.load(html, designed: designed, dark: dark, into: webView)
    }

    /// A viewport, a readable type scale, and images clamped to the width.
    ///
    /// `layoutWidth` is the second pass: the email's own width, which WebKit
    /// then scales down to the view. Nil is the first, device-width pass.
    private static func wrap(
        _ html: String, designed: Bool, dark: Bool, layoutWidth: CGFloat?
    ) -> String {
        let viewport = layoutWidth.map { "width=\(Int($0.rounded(.up)))" }
            ?? "width=device-width, initial-scale=1"

        let canvas: String
        if designed && !dark {
            canvas = "html, body { background: #ffffff; color: #111111; }"
        } else if designed {
            // The inversion. Pictures are inverted back, and so is anything
            // carrying a background image, so a photo behind text is not a
            // negative -- but not a picture *inside* such a thing, which would
            // be turned three times.
            canvas = """
            html, body { background: transparent; color: #111111; }
            body { filter: invert(0.92) hue-rotate(180deg); }
            img, video, picture, svg, [style*="background-image"], [background] {
              filter: invert(1) hue-rotate(180deg);
            }
            [style*="background-image"] img, [background] img { filter: none; }
            """
        } else {
            canvas = "html, body { background: transparent; color: #111111; }"
        }

        // A plain message follows the system appearance through its own
        // colours; a designed one is inverted above, and told it is in light
        // mode so WebKit does not darken its controls before the inversion.
        let scheme = designed ? "light" : "light dark"
        let adaptive = designed ? "" : """
          @media (prefers-color-scheme: dark) {
            html, body { background: transparent !important; color: #F2F2F7 !important; }
            p, div, span, td, li, h1, h2, h3, h4 { color: #F2F2F7 !important; }
            a { color: #6EA8FE !important; }
            blockquote { color: #A0A0A8 !important; border-left-color: rgba(255,255,255,0.25) !important; }
          }
        """

        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="\(viewport)">
        <style>
          :root { color-scheme: \(scheme); }
          \(canvas)
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
        var loadedDark = false

        private var observation: NSKeyValueObservation?
        private weak var webView: WKWebView?
        private var current: (html: String, designed: Bool, dark: Bool)?
        /// The width the current pass is laid out at; nil on the first,
        /// device-width pass. Set once, so a wide second pass cannot start a
        /// third.
        private var layoutWidth: CGFloat?
        /// After a reload the first measurement is taken as it comes, even if
        /// smaller: the scaled pass is shorter than the clipped one, and
        /// "only grow" would leave the old height as empty space below.
        private var acceptShrink = false

        init(_ parent: HTMLMessageView) { self.parent = parent }

        deinit { observation?.invalidate() }

        func load(_ html: String, designed: Bool, dark: Bool, into webView: WKWebView) {
            current = (html, designed, dark)
            layoutWidth = nil
            self.webView = webView
            webView.loadHTMLString(
                HTMLMessageView.wrap(html, designed: designed, dark: dark, layoutWidth: nil),
                baseURL: nil
            )
        }

        func observe(_ webView: WKWebView) {
            observation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
                guard let self else { return }
                let size = scrollView.contentSize
                let viewWidth = scrollView.bounds.width
                Task { @MainActor in
                    self.measured(size, viewWidth: viewWidth)
                }
            }
        }

        @MainActor
        private func measured(_ size: CGSize, viewWidth: CGFloat) {
            // Wider than the phone on the device-width pass: lay it out at
            // its own width and let WebKit scale it to fit. See "Fitting the
            // phone" above.
            if layoutWidth == nil, viewWidth > 0, size.width > viewWidth + 2,
               let current, let webView {
                let width = min(size.width, viewWidth * HTMLMessageView.maxScaleDown)
                layoutWidth = width
                acceptShrink = true
                webView.loadHTMLString(
                    HTMLMessageView.wrap(
                        current.html, designed: current.designed, dark: current.dark, layoutWidth: width
                    ),
                    baseURL: nil
                )
                return
            }

            if acceptShrink, size.height > 0 {
                acceptShrink = false
                parent.height = size.height
            } else if size.height > parent.height {
                // Only grow. Intermediate layout passes report smaller
                // heights and the message would jump as it settles.
                parent.height = size.height
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
