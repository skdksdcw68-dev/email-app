import SwiftUI
import UIKit

/// Pins a SwiftUI bar to the top of the system keyboard the way UIKit does
/// it: through `UIKeyboardLayoutGuide`.
///
/// This is the whole difference between a bar that *reacts* to the keyboard
/// and one that is *attached* to it. `safeAreaInset` was the wrong primitive:
/// the keyboard changed the safe area, the ScrollView relaid out, SwiftUI
/// recomputed the composer, and only then did it move -- measured on a real
/// recording, the gap to the keyboard drifted from 8pt to 40pt mid-dismissal
/// before settling. A layout guide is a constraint straight onto the
/// keyboard's frame, so the bar rides the keyboard's own animation curve and
/// follows an interactive drag frame for frame.
///
/// Three rules, all learned the hard way:
///
/// 1. The host is sized to the bar and only its *bottom* is constrained, so
///    the keyboard animates the host's position. Pinning the top as well
///    made the keyboard animate the host's height -- and SwiftUI content
///    inside a UIKit view lays out at the final size immediately, so the
///    capsule teleported ~290pt in 42ms while an invisible container
///    animated. Position animates the layer, and everything in it comes along.
///
/// 2. Nothing here runs its own animation. The guide's constraints update
///    inside the keyboard's animation block and UIKit lays out there; the
///    one constant we change (the 12pt/8pt gap) is set in the notification
///    and picked up by that same pass.
///
/// 3. The hosted view is rebuilt only when `inputs` change. SwiftUI calls
///    `updateUIViewController` on every re-render of the owner -- which,
///    while an answer streams, is dozens of times a second -- and rebuilding
///    a UIKit-hosted view each time was most of the lag on this screen.
struct KeyboardAttachedBar<Bar: View, Inputs: Equatable>: UIViewControllerRepresentable {
    @Binding var height: CGFloat
    /// Everything the bar's content depends on.
    let inputs: Inputs
    let bar: Bar

    init(height: Binding<CGFloat>, inputs: Inputs, @ViewBuilder bar: () -> Bar) {
        _height = height
        self.inputs = inputs
        self.bar = bar()
    }

    func makeUIViewController(context: Context) -> KeyboardBarController {
        KeyboardBarController()
    }

    func updateUIViewController(_ controller: KeyboardBarController, context: Context) {
        controller.onHeightChange = { measured in
            // Off the current update, so a layout pass never writes SwiftUI
            // state while SwiftUI is still evaluating a body.
            DispatchQueue.main.async {
                if abs(height - measured) > 0.5 { height = measured }
            }
        }

        if let last = controller.lastInputs as? Inputs, last == inputs { return }
        controller.lastInputs = inputs
        controller.hosting.rootView = AnyView(
            BarHost(bar: bar) { [weak controller] measured in
                controller?.report(height: measured)
            }
        )
    }
}

/// Owns the hosted bar and the one constraint that matters.
final class KeyboardBarController: UIViewController {
    let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    var onHeightChange: ((CGFloat) -> Void)?
    /// What the hosted view was last built from. See rule 3 above.
    var lastInputs: Any?

    /// Measured from ChatGPT: about 12pt above the keyboard when it is up,
    /// resting closer to the home indicator when it is down.
    static let keyboardGap: CGFloat = 12
    static let restingGap: CGFloat = 8

    private var gap: NSLayoutConstraint?
    private var observer: NSObjectProtocol?
    private var barHeight: CGFloat = 0

    override func loadView() {
        view = PassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        hosting.view.backgroundColor = .clear
        // The guide already places the bar above the keyboard. Letting the
        // hosting controller also avoid it would inset the bar twice.
        hosting.safeAreaRegions = .container
        // The host is exactly as tall as the bar, from SwiftUI's own
        // measurement. This is what makes the keyboard move the host rather
        // than resize it.
        hosting.sizingOptions = .intrinsicContentSize
        hosting.view.setContentCompressionResistancePriority(.required, for: .vertical)
        hosting.view.setContentHuggingPriority(.required, for: .vertical)

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let guide = view.keyboardLayoutGuide
        guide.usesBottomSafeArea = true

        let gap = hosting.view.bottomAnchor.constraint(
            equalTo: guide.topAnchor, constant: -Self.restingGap
        )
        self.gap = gap
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gap,
        ])
        hosting.didMove(toParent: self)

        (view as? PassthroughView)?.interactiveBand = { [weak self] in
            self?.hosting.view.frame ?? .zero
        }

        // Only the gap constant changes here. No animation block: the
        // keyboard's own layout pass, which runs inside its animation, picks
        // the new constant up along with the guide's new position.
        observer = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.keyboardWillChange(note)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func report(height: CGFloat) {
        guard abs(height - barHeight) > 0.5 else { return }
        barHeight = height
        onHeightChange?(height)
    }

    private func keyboardWillChange(_ note: Notification) {
        guard let gap,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }

        let endInView = view.convert(end, from: nil)
        let visible = endInView.minY < view.bounds.maxY - 1
        let target = visible ? -Self.keyboardGap : -Self.restingGap
        guard gap.constant != target else { return }

        gap.constant = target
        view.setNeedsLayout()
    }
}

/// A full-screen host whose only tappable region is the bar itself. A touch
/// anywhere else falls through to the conversation underneath, which is what
/// lets "tap the chat to put the keyboard away" keep working.
private final class PassthroughView: UIView {
    var interactiveBand: () -> CGRect = { .zero }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard interactiveBand().contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// The bar, bottom-aligned inside the host, reporting how tall it is.
///
/// Bottom-aligned on purpose: when the bar grows a line, SwiftUI animates
/// the growth while the host has already taken its final height. Anchoring
/// the bar to the bottom of that space is what keeps the buttons on the
/// bottom edge and sends the growth upward, the way the real thing does.
private struct BarHost<Bar: View>: View {
    let bar: Bar
    let onHeight: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            bar.background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BarHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .onPreferenceChange(BarHeightKey.self, perform: onHeight)
    }
}

private struct BarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
