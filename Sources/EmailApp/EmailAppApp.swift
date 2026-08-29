import SwiftUI

@main
struct EmailAppApp: App {
    /// Starts empty and disconnected -- the Mail tab shows the connect screen
    /// until `MailStore.connect()` succeeds.
    @State private var store = MailStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
