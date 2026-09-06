import UIKit
import XCTest
@testable import EmailApp

/// Whether a logo may be drawn edge to edge like a face, or needs a plate.
final class BrandImageShapeTests: XCTestCase {

    private func picture(opaque: Bool, _ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = opaque
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
        return renderer.image { draw($0.cgContext) }
    }

    func testAnOpaqueIconFillsItsFrame() {
        let icon = picture(opaque: true) { context in
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        XCTAssertFalse(icon.hasAlphaChannel)
        XCTAssertTrue(icon.fillsItsFrame)
    }

    func testARoundedIconFillsItsFrame() {
        // Transparent corners, opaque sides. The circle an avatar is cropped
        // to never reaches the corners, so this is drawn edge to edge.
        let icon = picture(opaque: false) { context in
            context.setFillColor(UIColor.black.cgColor)
            let rounded = UIBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: 64, height: 64), cornerRadius: 14
            )
            context.addPath(rounded.cgPath)
            context.fillPath()
        }
        XCTAssertTrue(icon.hasAlphaChannel)
        XCTAssertTrue(icon.fillsItsFrame)
    }

    func testAGlyphOnNothingDoesNot() {
        // A mark floating in a transparent square: edge to edge it would sit
        // ragged among the circles, so it keeps the plate.
        let glyph = picture(opaque: false) { context in
            context.setFillColor(UIColor.red.cgColor)
            context.fillEllipse(in: CGRect(x: 16, y: 16, width: 32, height: 32))
        }
        XCTAssertTrue(glyph.hasAlphaChannel)
        XCTAssertFalse(glyph.fillsItsFrame)
    }
}
