import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import EmailApp

/// The frames of a GIF survive the trip through `AvatarStore`.
final class AnimatedImageTests: XCTestCase {

    /// A GIF with `frames` solid frames, each shown for `delay` seconds.
    private func gif(frames: Int, delay: Double = 0.2) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)
        )
        for index in 0..<frames {
            let colour = index.isMultiple(of: 2) ? UIColor.red : UIColor.blue
            let frame = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                colour.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let properties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay],
            ] as CFDictionary
            CGImageDestinationAddImage(destination, try XCTUnwrap(frame.cgImage), properties)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testGIFBytesAreRecognised() throws {
        XCTAssertTrue(try gif(frames: 2).isGIF)
        XCTAssertFalse(Data([0x89, 0x50, 0x4E, 0x47]).isGIF)
        XCTAssertFalse(Data().isGIF)
    }

    func testEveryFrameComesBackWithItsTiming() throws {
        let moving = try XCTUnwrap(UIImage.animatedGIF(try gif(frames: 3, delay: 0.2)))
        XCTAssertEqual(moving.images?.count, 3)
        XCTAssertEqual(moving.duration, 0.6, accuracy: 0.01)
    }

    func testAStillGIFIsNotAnAnimation() throws {
        XCTAssertNil(UIImage.animatedGIF(try gif(frames: 1)))
    }

    func testSomethingThatIsNotAGIFIsNotAnAnimation() {
        XCTAssertNil(UIImage.animatedGIF(Data("<html>".utf8)))
    }

    func testALongGIFIsThinnedButKeepsItsPace() throws {
        // 120 frames at 0.05s is six seconds. Kept at sixty frames, each
        // standing for two, it should still take six seconds.
        let moving = try XCTUnwrap(UIImage.animatedGIF(try gif(frames: 120, delay: 0.05)))
        XCTAssertEqual(moving.images?.count, 60)
        XCTAssertEqual(moving.duration, 6, accuracy: 0.05)
    }
}
