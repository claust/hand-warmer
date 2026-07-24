import SwiftUI

@main
struct HandWarmerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var engine = HeatEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Keep the screen awake as long as the app is visible.
                UIApplication.shared.isIdleTimerDisabled = true
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                // Background execution would be killed by the watchdog anyway;
                // stop cleanly so we don't burn battery while invisible.
                engine.stop()
            default:
                break
            }
        }
    }
}
