import SwiftUI

extension View {
    /// The surface the system gives its own bar buttons on this OS: Liquid
    /// Glass on iOS 26, a material before it. For the few places that draw
    /// their own bar -- a header that has to hold a title, a capsule of
    /// buttons and a row of chips on one line -- so a hand-made control
    /// looks like the ones the toolbar draws for free.
    @ViewBuilder
    func barGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}
