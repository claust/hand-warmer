import XCTest

@testable import HandWarmer

final class TouchQuietTests: XCTestCase {

    private let touchedAt = Date(timeIntervalSinceReferenceDate: 1_000)

    private func moment(_ elapsed: TimeInterval) -> Date {
        touchedAt.addingTimeInterval(elapsed)
    }

    /// The state after a single finger has lifted.
    private var justLifted: TouchQuiet {
        TouchQuiet(activeTouches: 0, lastActivity: touchedAt)
    }

    // MARK: - Arming

    func testArmsOnlyAfterTheFullQuietWindow() {
        XCTAssertFalse(justLifted.isArmed(at: moment(0)))
        XCTAssertFalse(justLifted.isArmed(at: moment(TouchQuiet.required - 0.01)))
        XCTAssertTrue(justLifted.isArmed(at: moment(TouchQuiet.required)))
        XCTAssertTrue(justLifted.isArmed(at: moment(60)))
    }

    /// The case the whole guard exists for: a palm flat on the glass. However
    /// long ago it landed, the screen is not still while it is there.
    func testNeverArmsWhileAnythingIsTouchingTheScreen() {
        let palmDown = TouchQuiet(activeTouches: 3, lastActivity: touchedAt)
        for elapsed in [0.0, 1, 5, 600] {
            XCTAssertFalse(palmDown.isArmed(at: moment(elapsed)))
            XCTAssertEqual(palmDown.progress(at: moment(elapsed)), 0)
        }
    }

    /// A fresh launch is armed: there is nothing to protect against yet, and a
    /// user who opens the app and taps should be obeyed.
    func testStartsArmed() {
        XCTAssertTrue(TouchQuiet().isArmed(at: touchedAt))
    }

    // MARK: - The ring

    func testRingFillsAcrossTheWindowAndStopsAtFull() {
        XCTAssertEqual(justLifted.progress(at: moment(0)), 0, accuracy: 0.0001)
        XCTAssertEqual(
            justLifted.progress(at: moment(TouchQuiet.required / 2)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(justLifted.progress(at: moment(TouchQuiet.required)), 1, accuracy: 0.0001)
        XCTAssertEqual(justLifted.progress(at: moment(90)), 1, accuracy: 0.0001)
    }

    /// Clocks can hand back a slightly earlier "now" than the timestamp being
    /// measured against; the ring must not run backwards past empty.
    func testRingStaysWithinBoundsIfTimeGoesBackwards() {
        XCTAssertEqual(justLifted.progress(at: moment(-5)), 0, accuracy: 0.0001)
    }

    // MARK: - The collapse

    /// A hand landing on a full-size button shrinks it smoothly rather than
    /// snapping it away, and it is fully gone by the end of the collapse.
    @MainActor
    func testButtonEasesDownToNothingWhenTheScreenIsTouched() {
        let monitor = fullyArmedMonitor()
        monitor.touchesBegan(count: 1, at: touchedAt)

        XCTAssertEqual(monitor.quiet.progress(at: touchedAt), 1, accuracy: 0.0001)
        XCTAssertEqual(
            monitor.quiet.progress(at: moment(TouchQuiet.collapse / 2)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(monitor.quiet.progress(at: moment(TouchQuiet.collapse)), 0, accuracy: 0.0001)
        XCTAssertEqual(monitor.quiet.progress(at: moment(30)), 0, accuracy: 0.0001)
    }

    @MainActor
    func testCollapseOnlyEverShrinks() {
        let monitor = fullyArmedMonitor()
        monitor.touchesBegan(count: 1, at: touchedAt)

        var previous = 1.0
        for step in stride(from: 0.0, through: TouchQuiet.collapse, by: 0.02) {
            let value = monitor.quiet.progress(at: moment(step))
            XCTAssertLessThanOrEqual(value, previous + 0.0001, "grew again at \(step)s")
            previous = value
        }
    }

    /// A quick tap lifts long before the collapse is over. It must still glide
    /// down the same way a long press does — the lift is not a reason to jump
    /// the button to its smallest size.
    @MainActor
    func testAQuickTapCollapsesJustLikeALongPress() {
        let tapped = fullyArmedMonitor()
        tapped.touchesBegan(count: 1, at: touchedAt)
        tapped.touchesEnded(count: 1, at: moment(0.08))

        let held = fullyArmedMonitor()
        held.touchesBegan(count: 1, at: touchedAt)

        // They part company only near the bottom, where the quiet window has
        // been refilling since the lift and overtakes the collapse on its way
        // down. Until then the two are the same movement.
        for step in stride(from: 0.0, through: 0.25, by: 0.01) {
            XCTAssertEqual(
                tapped.quiet.progress(at: moment(step)),
                held.quiet.progress(at: moment(step)),
                accuracy: 0.0001,
                "tap and hold diverged at \(step)s")
        }
    }

    /// The bug this replaced: a lift mid-collapse dropped the button straight
    /// to its smallest size in one frame. Nothing either curve does should move
    /// the button more than a few percent per frame.
    @MainActor
    func testNothingJumpsWhenAQuickTapLifts() {
        let monitor = fullyArmedMonitor()
        monitor.touchesBegan(count: 1, at: touchedAt)
        monitor.touchesEnded(count: 1, at: moment(0.08))

        let frame = 1.0 / 60
        var previous = monitor.quiet.progress(at: touchedAt)
        for step in stride(from: frame, through: TouchQuiet.collapse + 0.2, by: frame) {
            let value = monitor.quiet.progress(at: moment(step))
            XCTAssertLessThan(abs(value - previous), 0.06, "jumped at \(step)s")
            previous = value
        }
    }

    /// And once it has landed, the quiet window takes over and grows it back.
    @MainActor
    func testTheCollapseHandsOverToTheQuietWindow() {
        let monitor = fullyArmedMonitor()
        monitor.touchesBegan(count: 1, at: touchedAt)
        monitor.touchesEnded(count: 1, at: moment(0.08))

        // Still falling while the collapse runs, then rising on the window.
        XCTAssertGreaterThan(monitor.quiet.progress(at: moment(0.2)), 0)
        XCTAssertLessThan(
            monitor.quiet.progress(at: moment(TouchQuiet.collapse + 0.1)),
            monitor.quiet.progress(at: moment(TouchQuiet.collapse + 0.5)))
        XCTAssertEqual(
            monitor.quiet.progress(at: moment(0.08 + TouchQuiet.required)), 1, accuracy: 0.0001)
    }

    /// A palm is several contacts arriving over a few frames. The collapse
    /// belongs to the first of them; later ones must not restart it, or a
    /// settling hand would hold the button open.
    @MainActor
    func testExtraFingersDoNotRestartTheCollapse() {
        let monitor = fullyArmedMonitor()
        monitor.touchesBegan(count: 1, at: touchedAt)
        monitor.touchesBegan(count: 2, at: moment(TouchQuiet.collapse / 2))

        XCTAssertEqual(monitor.quiet.progress(at: moment(TouchQuiet.collapse)), 0, accuracy: 0.0001)
    }

    /// A monitor whose quiet window has fully run out, so the button is at
    /// full size and a tap would be taken.
    @MainActor
    private func fullyArmedMonitor() -> TouchQuietMonitor {
        let monitor = TouchQuietMonitor()
        monitor.touchesEnded(count: 0, at: touchedAt.addingTimeInterval(-TouchQuiet.required))
        return monitor
    }

    // MARK: - The monitor

    @MainActor
    func testMonitorJudgesATapByTheScreenItLandedOn() {
        let monitor = TouchQuietMonitor()
        XCTAssertTrue(monitor.wasArmedAtLatestTouchDown, "a fresh launch should accept a tap")

        // A palm lands, and a finger taps a moment later: refused.
        monitor.touchesBegan(count: 2, at: touchedAt)
        monitor.touchesBegan(count: 1, at: moment(0.3))
        XCTAssertFalse(monitor.wasArmedAtLatestTouchDown)

        // Everything lifts, the screen goes quiet, and the next tap is taken.
        monitor.touchesEnded(count: 3, at: moment(1))
        monitor.touchesBegan(count: 1, at: moment(1 + TouchQuiet.required))
        XCTAssertTrue(monitor.wasArmedAtLatestTouchDown)
    }

    /// A tap that lands too soon after the hand lifts is still an accident —
    /// most likely the same hand rearranging itself.
    @MainActor
    func testMonitorRefusesATapInTheGapAfterAHandLifts() {
        let monitor = TouchQuietMonitor()
        monitor.touchesBegan(count: 1, at: touchedAt)
        monitor.touchesEnded(count: 1, at: moment(0.5))
        monitor.touchesBegan(count: 1, at: moment(0.5 + TouchQuiet.required - 0.1))
        XCTAssertFalse(monitor.wasArmedAtLatestTouchDown)
    }

    /// UIKit can report the end of a touch the recognizer never saw begin —
    /// one that started before it was attached to the window. Left unguarded
    /// that would drive the count negative and arm the button under a palm.
    @MainActor
    func testMonitorCannotBeDrivenBelowZeroTouches() {
        let monitor = TouchQuietMonitor()
        monitor.touchesEnded(count: 4, at: touchedAt)
        monitor.touchesBegan(count: 1, at: moment(0.1))
        XCTAssertEqual(monitor.quiet.activeTouches, 1)
        XCTAssertFalse(monitor.wasArmedAtLatestTouchDown)
    }
}
