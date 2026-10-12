import SwiftUI

@main
struct SSHDashApp: App {
    init() {
        Theme.setupAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
