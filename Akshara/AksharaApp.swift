import SwiftUI

@main
struct AksharaApp: App {
    init() {
        CrashReportManager.shared.start()
    }

    var body: some Scene { WindowGroup { HomeView() } }
}
