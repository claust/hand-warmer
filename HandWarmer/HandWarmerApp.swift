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
            // Hold the screen awake only while we are frontmost. Tying this to
            // .active also releases it on .inactive (Control Center, call
            // banner, permission prompt), which a .background-only reset misses.
            UIApplication.shared.isIdleTimerDisabled = phase == .active

            if phase == .background {
                // Background execution would be killed by the watchdog anyway;
                // stop cleanly so we don't burn battery while invisible.
                engine.stop()
            }
        }
    }
}
