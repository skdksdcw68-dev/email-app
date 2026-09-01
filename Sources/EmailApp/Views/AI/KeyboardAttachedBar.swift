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
/// Four rules, all learned the hard way:
///
/// 1. The host is exactly as tall as the bar and only its *bottom* is
///    constrained, so the keyboard animates the host's position. Pinning the
///    top as well made the keyboard animate the host's height -- and SwiftUI
///    content inside a UIKit view lays out at the final size immediately, so
///    the capsule teleported ~290pt in 42ms while an invisible container
///    animated. Position animates the layer, and everything in it comes along.
///
/// 2. The host's height comes from SwiftUI's own measurement of the bar at
///    its real width, not from UIKit's intrinsic content size. Intrinsic size
///    measures at an unconstrained width, where a vertical text field is
///    always one line -- so the host stayed 48pt and every new line the
///    person typed was squeezed out of sight.
///
/// 3. Nothing here runs its own animation. The guide's constraints update
///    inside the keyboard's animation block and UIKit lays out there; the
///    one constant we change (the 12pt/8pt gap) is set in the notification
///    and picked up by that same pass.
///
/// 4. The hosted view is rebuilt only when `inputs` change. SwiftUI calls
///    `updateUIViewController` on every re-render of the owner -- which,
///    while an answer streams, is dozens of times a second -- and rebuilding
///    a UIKit-hosted view each time was most of the lag on this screen.
///
/// Two measurements come back out: `height`, the bar's own height, so the
/// content behind it can leave room; and `bottom`, how much of the screen
/// the bar and the keyboard together take from the bottom, so anything that
/// wants to centre in the space above them can.
struct KeyboardAttachedBar<Bar: View, Inputs: Equatable>: UIViewControllerRepresentable {
    @Binding var height: CGFloat
    @Binding var bottom: CGFloat
    /// Everything the bar's content depends on.
    let inputs: Inputs
    let bar: Bar

    init(
        height: Binding<CGFloat>,
        bottom: Binding<CGFloat>,
        inputs: Inputs,
        @ViewBuilder bar: () -> Bar
    ) {
        _height = height
        _bottom = bottom
        self.inputs = inputs
        self.bar = bar()
    }

    func makeUIViewController(context: Context) -> KeyboardBarController {
        KeyboardBarController()
    }

    func updateUIViewController(_ controller: KeyboardBarController, context: Context) {
        // Off the current update, so a layout pass never writes SwiftUI
        // state while SwiftUI is still evaluating a body.
        controller.onHeightChange = { measured in
            DispatchQueue.main.async {
                if abs(height - measured) > 0.5 { height = measured }
            }
        }
        controller.onBottomChange = { measured in
            DispatchQueue.main.async {
                if abs(bottom - measured) > 0.5 { bottom = measured }
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

/// Owns the hosted bar and the two constraints that matter: where its
/// bottom is, and how tall it is.
final class KeyboardBarController: UIViewController {
    let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    var onHeightChange: ((CGFloat) -> Void)?
    var onBottomChange: ((CGFloat) -> Void)?
    /// What the hosted view was last built from. See rule 4 above.
    var lastInputs: Any?

    /// Measured from ChatGPT: about 12pt above the keyboard when it is up,
    /// resting closer to the home indicator when it is down.
    static let keyboardGap: CGFloat = 12
    static let restingGap: CGFloat = 8

    private var gap: NSLayoutConstraint?
    private var height: NSLayoutConstraint?
    private var observer: NSObjectProtocol?
    private var barHeight: CGFloat = 0
    private var lastBottom: CGFloat = 0

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

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let guide = view.keyboardLayoutGuide
        guide.usesBottomSafeArea = true

        let gap = hosting.view.bottomAnchor.constraint(
            equalTo: guide.topAnchor, constant: -Self.restingGap
        )
        // Starts at the resting capsule's height; SwiftUI reports the real
        // number on its first layout and every time the bar grows or shrinks.
        let height = hosting.view.heightAnchor.constraint(equalToConstant: 54)
        self.gap = gap
        self.height = height
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gap,
            height,
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // How far up the screen the bar's top edge sits -- keyboard included
        // when it is up. Laid out once per keyboard change with the final
        // values, so whoever animates against it gets one clean move.
        let occupied = view.bounds.maxY - hosting.view.frame.minY
        guard occupied > 0, abs(occupied - lastBottom) > 0.5 else { return }
        lastBottom = occupied
        onBottomChange?(occupied)
    }

    /// SwiftUI measured the bar. The host follows, so the bar is never
    /// squeezed into a smaller frame than it asked for.
    func report(height measured: CGFloat) {
        guard measured > 0, abs(measured - barHeight) > 0.5 else { return }
        barHeight = measured
        height?.constant = measured
        view.setNeedsLayout()
        onHeightChange?(measured)
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

/// The bar at its own ideal height, bottom-aligned in the host, reporting
/// that height back.
///
/// `fixedSize` in the vertical axis is what makes a new line grow the bar:
/// the bar takes the height its content wants regardless of what the host
/// currently offers, the measurement goes to UIKit, and the host catches up
/// a frame later. Bottom-aligned so that catching up happens at the top
/// edge, where nothing is looking, and the buttons never leave the bottom.
private struct BarHost<Bar: View>: View {
    let bar: Bar
    let onHeight: (CGFloat) -> Void

    var body: some View {
        bar
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: BarHeightKey.self, value: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onPreferenceChange(BarHeightKey.self, perform: onHeight)
    }
}

private struct BarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
