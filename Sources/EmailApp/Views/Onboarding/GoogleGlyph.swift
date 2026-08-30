import SwiftUI

/// The Google mark, drawn as four brand-coloured arcs plus the crossbar.
///
/// SF Symbols has no Google glyph -- it is a trademark -- and `g.circle.fill`
/// reads as a generic letter rather than the sign-in mark people recognise.
///
/// This is a faithful approximation, good enough for development. Before
/// shipping, swap it for the official asset from Google's Identity branding
/// guidelines, which their terms require for a real "Sign in with Google"
/// button.
struct GoogleGlyph: View {
    var size: CGFloat = 19

    private let blue = Color(red: 0.259, green: 0.522, blue: 0.957)
    private let green = Color(red: 0.204, green: 0.659, blue: 0.325)
    private let yellow = Color(red: 0.984, green: 0.737, blue: 0.020)
    private let red = Color(red: 0.918, green: 0.263, blue: 0.208)

    var body: some View {
        ZStack {
            // Angles run clockwise from east. The opening sits on the right,
            // where the crossbar meets the ring.
            Arc(from: 46, to: 136).stroke(green, lineWidth: lineWidth)
            Arc(from: 136, to: 226).stroke(yellow, lineWidth: lineWidth)
            Arc(from: 226, to: 313).stroke(red, lineWidth: lineWidth)
            Arc(from: -47, to: 1).stroke(blue, lineWidth: lineWidth)

            Crossbar().fill(blue)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var lineWidth: CGFloat { size * 0.24 }
}

private struct Arc: Shape {
    let from: Double
    let to: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lineWidth = rect.width * 0.24
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: (rect.width - lineWidth) / 2,
            startAngle: .degrees(from),
            endAngle: .degrees(to),
            clockwise: false
        )
        return path
    }
}

/// The horizontal bar of the G, running from the centre out to the ring.
private struct Crossbar: Shape {
    func path(in rect: CGRect) -> Path {
        let lineWidth = rect.width * 0.24
        return Path(CGRect(
            x: rect.midX + rect.width * 0.02,
            y: rect.midY - lineWidth / 2,
            width: rect.width / 2 - rect.width * 0.02,
            height: lineWidth
        ))
    }
}

#Preview {
    VStack(spacing: 20) {
        GoogleGlyph(size: 19)
        GoogleGlyph(size: 44)
        GoogleGlyph(size: 88)
    }
    .padding()
}
