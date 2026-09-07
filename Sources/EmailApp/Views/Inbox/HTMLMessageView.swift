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
    /// Whether this message may fetch its pictures from the sender's servers.
    /// False until somebody says otherwise -- see `RemoteContentBlocker`.
    var loadsRemoteContent = false
    /// A tapped link, handed back rather than opened here, so the screen can
    /// show where it actually goes first.
    var onLink: ((URL) -> Void)? = nil

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
        // A long press on a link shows WebKit's own preview, which names the
        // destination. That is the cheapest honest answer to "where does this
        // actually go", and it costs nothing to allow.
        webView.allowsLinkPreview = true
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
        coordinator.onLink = onLink
        guard coordinator.loadedHTML != html
                || coordinator.loadedDark != dark
                || coordinator.loadedRemote != loadsRemoteContent
        else { return }
        coordinator.loadedHTML = html
        coordinator.loadedDark = dark
        coordinator.loadedRemote = loadsRemoteContent

        let designed = Self.isDesigned(html)
        // A designed email in light mode keeps its white canvas. Everything
        // else is transparent so the app's own surface shows through -- in
        // dark mode that surface is what the inverted email sits on.
        let whiteCanvas = designed && !dark
        webView.isOpaque = whiteCanvas
        webView.backgroundColor = whiteCanvas ? .white : .clear
        webView.scrollView.backgroundColor = whiteCanvas ? .white : .clear

        coordinator.load(
            html, designed: designed, dark: dark,
            remote: loadsRemoteContent, into: webView
        )
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
        var loadedRemote = false
        /// Reassigned on every update, because a SwiftUI view is a value and
        /// the closure captured at `makeCoordinator` time is the first one.
        var onLink: ((URL) -> Void)?

        private var observation: NSKeyValueObservation?
        private weak var webView: WKWebView?
        private var current: (html: String, designed: Bool, dark: Bool)?
        /// Whether the HTML being shown had its remote references cut out
        /// rather than blocked by WebKit. Remembered so the second,
        /// width-corrected pass loads the same thing as the first.
        private var strippedRemote = false
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

        func load(
            _ html: String, designed: Bool, dark: Bool, remote: Bool, into webView: WKWebView
        ) {
            current = (html, designed, dark)
            layoutWidth = nil
            self.webView = webView

            guard !remote else {
                webView.configuration.userContentController.removeAllContentRuleLists()
                strippedRemote = false
                show(html, designed: designed, dark: dark, in: webView)
                return
            }

            // ⚠️ Nothing is loaded until the blocker is in place. Loading now
            // and applying the rule list when it arrives would fetch exactly
            // the pictures this is here to refuse -- the tracking request is
            // made once, and it is made on the first paint.
            Task { @MainActor in
                let list = await RemoteContentBlocker.list()
                guard let webView = self.webView, self.current?.html == html else { return }

                webView.configuration.userContentController.removeAllContentRuleLists()
                if let list {
                    webView.configuration.userContentController.add(list)
                    self.strippedRemote = false
                    self.show(html, designed: designed, dark: dark, in: webView)
                } else {
                    // No rule list. Cut the references out of the HTML rather
                    // than let them through.
                    self.strippedRemote = true
                    self.show(
                        HTMLMessageView.strippingRemoteContent(html),
                        designed: designed, dark: dark, in: webView
                    )
                }
            }
        }

        private func show(_ body: String, designed: Bool, dark: Bool, in webView: WKWebView) {
            webView.loadHTMLString(
                HTMLMessageView.wrap(body, designed: designed, dark: dark, layoutWidth: nil),
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
                // The same body as the first pass. When the references were
                // stripped rather than blocked, reloading the original here
                // would quietly fetch them on the second pass.
                let body = strippedRemote
                    ? HTMLMessageView.strippingRemoteContent(current.html)
                    : current.html
                webView.loadHTMLString(
                    HTMLMessageView.wrap(
                        body, designed: current.designed, dark: current.dark, layoutWidth: width
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

        /// A tapped link never navigates inside the message, and never opens
        /// straight away unless it is safe to and the person asked for that.
        ///
        /// 🔴 This used to be `UIApplication.shared.open(url)` for any scheme
        /// at all. The visible text of a link and its `href` are unrelated
        /// strings -- that is the entire mechanism of a phishing email -- and
        /// a scheme this app does not understand had no business being handed
        /// to the system from inside somebody else's HTML.
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
            decisionHandler(.cancel)

            switch url.scheme?.lowercased() {
            case "http", "https":
                if AppSettings.confirmsLinks, let onLink {
                    onLink(url)
                } else {
                    UIApplication.shared.open(url)
                }
            // Writing to somebody or ringing them is what the link says it
            // is, and iOS asks before placing a call anyway.
            case "mailto", "tel":
                UIApplication.shared.open(url)
            // Everything else -- a custom scheme aimed at another app, or
            // `javascript:`, or `file:` -- is refused in silence.
            default:
                break
            }
        }
    }
}
