import SwiftUI
import UIKit

/// Plays an animated `UIImage`.
///
/// SwiftUI's `Image` draws the first frame of an animated image and stops
/// there; `UIImageView` plays it. This is the smallest possible bridge, for
/// the one kind of avatar that moves -- an animated GIF profile photo, which
/// Google serves at every size and which `AvatarStore` keeps frame-complete.
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        // The frames are 256px and would otherwise win the layout argument
        // against a 44pt frame: the picture takes the size it is given.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        // Assigning the same image restarts the animation from frame one.
        if view.image !== image { view.image = image }
    }
}
