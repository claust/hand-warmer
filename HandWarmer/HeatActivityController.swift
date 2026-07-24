import ActivityKit
import Combine
import Foundation

/// Owns the Live Activity that puts the warmer in the Dynamic Island (and on
/// the Lock Screen), the way a running timer does.
///
/// The island has no clock of its own for anything but `Text(timerInterval:)`:
/// it redraws only when a new `ContentState` arrives. So the flame's animation
/// is literally this class's tick — we push a new `flamePhase` a few times a
/// second and let SwiftUI interpolate the shapes in between.
final class HeatActivityController {

    /// Pulled on every tick for the current readings. Set by `HeatEngine`.
    var snapshot: (() -> HeatActivityAttributes.ContentState)?

    private var activity: Activity<HeatActivityAttributes>?
    private var ticker: AnyCancellable?
    private var phase = 0
    /// Whether a session is meant to be showing. `begin` completes
    /// asynchronously, so without this a stop that lands mid-request would be
    /// followed by an activity nobody ever ends.
    private var wantsActivity = false

    /// While the app is frontmost the island is not on screen at all, so only
    /// the data has to stay honest.
    private static let foregroundInterval: TimeInterval = 5.0
    /// Backgrounded, every update is also an animation frame — the island has
    /// no clock of its own, so this cadence *is* the flame's frame rate.
    private static let backgroundInterval: TimeInterval = 0.5

    /// Marks the activity stale if we ever get suspended anyway, so the island
    /// dims instead of confidently showing a frozen flame.
    private static let staleAfter: TimeInterval = 30

    private var isBackgrounded = false

    // MARK: - Lifecycle

    /// Clears activities left behind by a previous run. `end()` only happens
    /// while we are alive, so a force-quit or a crash strands the island with a
    /// flame that will never stop flickering and a clock counting up from a
    /// session that ended hours ago.
    ///
    /// Awaited from `begin` rather than fired off at launch: `Activity.activities`
    /// is populated asynchronously from `liveactivitiesd`, so a cleanup started
    /// at init routinely reads an empty list, misses the orphan, and leaves the
    /// island with two live activities to choose between — at which point it
    /// shows neither of them reliably.
    private func endStrays() async {
        for stray in Activity<HeatActivityAttributes>.activities {
            await stray.end(nil, dismissalPolicy: .immediate)
        }
    }

    func begin(coreCount: Int) {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        phase = 0
        wantsActivity = true
        Task { @MainActor in
            await endStrays()
            // The warmer may have been switched off again while we waited.
            guard self.wantsActivity, self.activity == nil,
                  let state = self.snapshot?() else { return }
            do {
                self.activity = try Activity.request(
                    attributes: HeatActivityAttributes(coreCount: coreCount),
                    content: ActivityContent(state: state,
                                             staleDate: Date().addingTimeInterval(Self.staleAfter)),
                    pushType: nil)
                self.restartTicker()
            } catch {
                // Activities can be off system-wide or refused under load. The
                // warmer itself is unaffected, so carry on without the island.
                self.activity = nil
            }
        }
    }

    func end() {
        ticker = nil
        wantsActivity = false
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Drives the tick rate: fast while the island is actually visible.
    func setBackgrounded(_ backgrounded: Bool) {
        guard backgrounded != isBackgrounded else { return }
        isBackgrounded = backgrounded
        guard activity != nil else { return }
        restartTicker()
        // Don't make the user wait a whole interval to see the island wake up.
        push()
    }

    // MARK: - Updates

    private func restartTicker() {
        let interval = isBackgrounded ? Self.backgroundInterval : Self.foregroundInterval
        // .common so the tick survives a scroll or a drag on the island itself.
        ticker = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.push() }
    }

    private func push() {
        guard let activity, var state = snapshot?() else { return }
        phase &+= 1
        state.flamePhase = phase
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }
}
