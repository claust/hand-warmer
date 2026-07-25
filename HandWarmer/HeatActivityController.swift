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
    /// Returns nil once the engine is gone — `begin`'s task holds this
    /// controller, so it can briefly outlive its owner.
    var snapshot: (() -> HeatActivityAttributes.ContentState?)?

    private func currentState() -> HeatActivityAttributes.ContentState? {
        snapshot?() ?? nil
    }

    private var activity: Activity<HeatActivityAttributes>?
    private var ticker: AnyCancellable?
    /// The update currently in flight, if any, so ticks can be dropped instead
    /// of queued behind a slow one.
    private var updateTask: Task<Void, Never>?
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
    /// Leaving two live activities around makes the island pick between them
    /// and show neither reliably, so strays are swept rather than tolerated.
    /// `keeping` is our own activity, which must survive the sweep.
    private func endStrays(except keeping: String? = nil) async {
        for stray in Activity<HeatActivityAttributes>.activities where stray.id != keeping {
            await stray.end(nil, dismissalPolicy: .immediate)
        }
    }

    // A launch-time sweep — clearing a crashed session's flame even when the
    // user never warms again this launch — was tried and removed. Every variant
    // ended up racing the session that was starting and killing the live
    // activity a second or two after it appeared, which is how the island came
    // to be blank for whole sessions. Sweeping only from `begin`, after our own
    // request has succeeded, is the version that behaves. The cost is that a
    // stray flame lingers until the next time warming starts.

    func begin(coreCount: Int) {
        // `wantsActivity`, not `activity`, is the guard: the request below is
        // async, so two begins in quick succession would both still see a nil
        // activity and each ask for one, leaving a duplicate flame behind.
        guard !wantsActivity, activity == nil,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        phase = 0
        wantsActivity = true
        Task { @MainActor in
            guard self.wantsActivity, self.activity == nil,
                  let state = self.currentState() else { return }
            do {
                let new = try Activity.request(
                    attributes: HeatActivityAttributes(coreCount: coreCount),
                    content: ActivityContent(state: state,
                                             staleDate: Date().addingTimeInterval(Self.staleAfter)),
                    pushType: nil)
                self.activity = new
                self.restartTicker()

                // Sweep afterwards, never before: ending a stray can stall, and
                // when it did, the request behind it never ran and the island
                // stayed empty for the whole session. Ours is already live by
                // this point, so a slow sweep costs nothing.
                await self.endStrays(except: new.id)
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
        updateTask?.cancel()
        updateTask = nil
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
        // Skip the tick while an update is still in flight rather than stacking
        // another one behind it. At 2 Hz a queue would only grow, and for an
        // animation a dropped frame is always better than a backlog of stale
        // ones arriving late.
        guard let activity, updateTask == nil, var state = currentState() else { return }
        phase &+= 1
        state.flamePhase = phase
        let content = ActivityContent(state: state,
                                      staleDate: Date().addingTimeInterval(Self.staleAfter))
        updateTask = Task { @MainActor in
            await activity.update(content)
            self.updateTask = nil
        }
    }
}
