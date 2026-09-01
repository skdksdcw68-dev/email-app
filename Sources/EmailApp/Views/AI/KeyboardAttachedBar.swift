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
/// follows an interactive drag frame for frame, with nothing of ours
/// animating on top.
///
/// The hosted SwiftUI view fills the screen above the keyboard and puts the
/// bar at its bottom; everything outside the bar's band passes touches
/// through to whatever is underneath. `height` reports the bar's size so the
/// content behind it can leave room.
struct KeyboardAttachedBar<Bar: View>: UIViewControllerRepresentable {
    @Binding var height: CGFloat
    let bar: Bar

    init(height: Binding<CGFloat>, @ViewBuilder bar: () -> Bar) {
        _height = height
        self.bar = bar()
    }

    func makeUIViewController(context: Context) -> KeyboardBarController {
        KeyboardBarController()
    }

    func updateUIViewController(_ controller: KeyboardBarController, context: Context) {
        controller.hosting.rootView = AnyView(
            BarHost(bar: bar) { [weak controller] measured in
                controller?.report(height: measured)
            }
        )
        controller.onHeightChange = { measured in
            // Off the current update, so a layout pass never writes SwiftUI
            // state while SwiftUI is still evaluating a body.
            DispatchQueue.main.async {
                if abs(height - measured) > 0.5 { height = measured }
            }
        }
    }
}

/// Owns the hosted bar and the one constraint that matters.
final class KeyboardBarController: UIViewController {
    let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    var onHeightChange: ((CGFloat) -> Void)?

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
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gap,
        ])
        hosting.didMove(toParent: self)

        (view as? PassthroughView)?.interactiveBand = { [weak self] in
            self?.barBand ?? .zero
        }

        // The only thing we animate ourselves is the 8pt/12pt gap, and it
        // runs inside the keyboard's own duration and curve so the two are
        // one motion rather than a bar chasing a keyboard.
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

    /// Where the bar actually is: the bottom `barHeight` points of the host.
    private var barBand: CGRect {
        let frame = hosting.view.frame
        return CGRect(x: frame.minX, y: frame.maxY - barHeight, width: frame.width, height: barHeight)
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

        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 7

        gap.constant = target
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: UInt(curve << 16))
        ) {
            self.view.layoutIfNeeded()
        }
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

/// Puts the bar at the bottom of the host and reports how tall it is.
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
