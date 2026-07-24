import ActivityKit
import Foundation

/// Contract between the app and the widget extension that draws the Dynamic
/// Island. Both targets compile this file, so any change here has to stay
/// `Codable` — ActivityKit serialises the state across the process boundary.
struct HeatActivityAttributes: ActivityAttributes {

    /// Everything that changes while the warmer runs.
    struct ContentState: Codable, Hashable {
        /// When this session started, so the island can run its own clock with
        /// `Text(timerInterval:)` instead of us pushing a new state per second.
        var startedAt: Date

        /// 0...1, same scale as `HeatEngine.heatLevel`.
        var heatLevel: Double
        /// "Cool" / "Warm" / "Hot" / "Very hot".
        var thermalLabel: String
        /// Raw `UIDevice.batteryLevel`; negative means "unknown".
        var batteryLevel: Float

        /// Monotonic counter, bumped a few times a second while backgrounded.
        /// The island cannot animate on its own — it only redraws when a new
        /// state arrives — so this is what actually makes the flame flicker:
        /// every value maps to a different set of wobble offsets, and SwiftUI
        /// interpolates between them.
        var flamePhase: Int

        /// SF Symbol names for the boosters that are switched on.
        var boosterSymbols: [String]
    }

    /// Fixed for the lifetime of the activity.
    var coreCount: Int
}
