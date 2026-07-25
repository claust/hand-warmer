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
                .onAppear {
                    // onChange fires on transitions only, so the first active
                    // session would otherwise never disable the idle timer.
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Hold the screen awake only while we are frontmost. Tying this to
            // .active also releases it on .inactive (Control Center, call
            // banner, permission prompt), which a .background-only reset misses.
            UIApplication.shared.isIdleTimerDisabled = phase == .active

            // Backgrounding no longer stops the warmer — the engine holds an
            // audio session to stay scheduled, and the session moves to the
            // Dynamic Island. Drive the island harder once it is what the user
            // is actually looking at.
            //
            // Keyed on .background rather than "not .active": .inactive covers
            // Control Center, permission prompts and call banners, where the
            // island is usually covered anyway, and the fast cadence is pure
            // ActivityKit traffic for nobody's benefit.
            engine.setBackgrounded(phase == .background)
        }
    }
}
