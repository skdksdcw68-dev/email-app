import UIKit
import WebKit

/// Turns an SVG into a `UIImage`.
///
/// Needed for exactly one thing: BIMI logos are **always** SVG -- the standard
/// requires SVG Tiny PS -- and `UIImage` cannot read SVG at all. Since BIMI is
/// the only place a company's *official, verified* logo can be had for free,
/// not being able to draw one would mean giving up the best source there is.
///
/// ## Why a web view
///
/// iOS ships no SVG rasteriser. The alternatives were a third-party renderer
/// (a dependency, for one file format) or parsing the paths by hand (fragile
/// against every generator Adobe has ever shipped). WebKit is already on the
/// phone and already correct.
///
/// ⚠️ It is genuinely expensive -- a web view, a page load, a snapshot -- so
/// it must run **once per brand, ever**. `BrandIcon` writes the result to disk
/// as a PNG and never comes back. Calling this per row would be indefensible.
@MainActor
enum SVGRasterizer {

    /// Renders at this many points, then relies on the PNG being scaled down.
    /// Bigger than any circle drawn, so one raster serves every size.
    private static let canvas: CGFloat = 256

    /// A page that never finishes loading must not hold the caller forever.
    private static let timeout: Duration = .seconds(10)

    static func image(from svg: Data) async -> UIImage? {
        // Sanity, before handing anything to WebKit: a BIMI logo is a couple
        // of kilobytes. Something enormous here is not a logo.
        guard !svg.isEmpty, svg.count < 512 * 1024 else { return nil }

        let base64 = svg.base64EncodedString()
        // The SVG goes in as an `<img>` with a data URI rather than inline in
        // the document. Inline, an SVG's own `width`/`height` win over the
        // page and a 700-unit viewBox renders 700 points wide inside a 256
        // point canvas -- cropped, not scaled. As an image it is laid out like
        // any other image and fills the box.
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=\(Int(canvas))">
        <style>html,body{margin:0;padding:0;background:transparent}
        img{width:\(Int(canvas))px;height:\(Int(canvas))px;display:block}</style></head>
        <body><img src="data:image/svg+xml;base64,\(base64)"></body></html>
        """

        let configuration = WKWebViewConfiguration()
        // Nothing in a BIMI logo is allowed to be a script, and nothing here
        // should be able to run one anyway.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: canvas, height: canvas),
            configuration: configuration
        )
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter

        webView.loadHTMLString(html, baseURL: nil)

        // Whichever comes first. A snapshot of a half-loaded page is a blank
        // square, which would then be cached as though it were the logo.
        let loaded = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await waiter.wait() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard loaded else { return nil }

        let configurationSnapshot = WKSnapshotConfiguration()
        configurationSnapshot.rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)

        let image: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configurationSnapshot) { image, _ in
                continuation.resume(returning: image)
            }
        }

        // A snapshot that is entirely one colour means the page never drew --
        // an SVG WebKit refused, or a race the timeout did not catch. Caching
        // that would put a blank square in the inbox until the cache expired.
        guard let image, !isBlank(image) else { return nil }
        return image
    }

    /// True when every corner and the centre are the same. Crude on purpose:
    /// it only has to catch "nothing rendered", and any real logo has some
    /// contrast between its middle and its edges.
    private static func isBlank(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return true }
        let width = cgImage.width, height = cgImage.height
        guard width > 2, height > 2 else { return true }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return Array(pixels[offset..<offset + 4])
        }

        let centre = pixel(width / 2, height / 2)
        let corners = [pixel(1, 1), pixel(width - 2, 1), pixel(1, height - 2)]
        return corners.allSatisfy { $0 == centre }
    }

    /// Bridges `WKNavigationDelegate`'s callbacks to one awaitable answer.
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var settled = false

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                if settled {
                    continuation.resume(returning: true)
                } else {
                    self.continuation = continuation
                }
            }
        }

        private func finish(_ success: Bool) {
            guard !settled else { return }
            settled = true
            continuation?.resume(returning: success)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(true)
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            finish(false)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finish(false)
        }
    }
}
