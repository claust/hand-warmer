import UIKit
import XCTest

@testable import HandWarmer

final class HeatEngineTests: XCTestCase {

    private let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

    // MARK: - Heat meter bands

    /// The bands are the contract between the bar and its label: laid end to
    /// end they must cover the whole meter with no gap, or some fill level
    /// would sit under a label that contradicts it. They are closed ranges, so
    /// neighbours share their boundary value — a level exactly on a tick
    /// belongs to both bands, which is fine, since both agree on where it sits.
    func testBandsTileTheMeterWithoutGaps() {
        var bands = states.map(HeatEngine.band(for:))

        XCTAssertEqual(bands.first?.lowerBound, 0)
        XCTAssertEqual(bands.last?.upperBound, 1)

        let first = bands.removeFirst()
        _ = bands.reduce(first) { previous, next in
            XCTAssertEqual(previous.upperBound, next.lowerBound, accuracy: 0.0001)
            return next
        }
    }

    func testEveryBandHasWidth() {
        for state in states {
            let band = HeatEngine.band(for: state)
            XCTAssertGreaterThan(band.upperBound, band.lowerBound, "empty band for \(state)")
        }
    }

    /// The ticks ContentView draws on the heat bar are hard-coded, so pin them
    /// to the bands they are supposed to mark.
    func testTicksMatchBandBoundaries() {
        let boundaries = states.dropFirst().map { HeatEngine.band(for: $0).lowerBound }
        XCTAssertEqual(boundaries, [0.30, 0.60, 0.85])
    }

    // MARK: - Thermal labels

    /// These strings are a cross-process contract, not cosmetics: they travel
    /// to the widget inside `ContentState.thermalLabel`, and the Live Activity
    /// picks its colour by matching them. A silent rename here would leave the
    /// island rendering everything in the fallback grey.
    func testLabelsMatchTheStringsTheWidgetMatchesOn() {
        XCTAssertEqual(states.map(HeatEngine.label(for:)), ["Cool", "Warm", "Hot", "Very hot"])
    }

    func testEveryStateHasADistinctLabel() {
        XCTAssertEqual(Set(states.map(HeatEngine.label(for:))).count, states.count)
    }

    /// A thermal state this build does not know about has to fall through the
    /// `@unknown default` to "Unknown" rather than trapping.
    func testUnknownStateFallsBackToUnknown() throws {
        let future = try XCTUnwrap(
            ProcessInfo.ThermalState(rawValue: 99),
            "ThermalState rejects unknown raw values on this OS; nothing to check")
        XCTAssertEqual(HeatEngine.label(for: future), "Unknown")
    }

    // MARK: - Battery floor

    /// The floor is the one number the disabled button, the auto-stop and the
    /// alert copy all read from, so pin it.
    func testBatteryFloorIsTenPercent() {
        XCTAssertEqual(HeatEngine.batteryFloor, 0.10)
    }

    /// `batteryLevel` arrives in 5% steps as a Float, so an exact 10% reading
    /// must count as at-the-floor despite the rounding.
    func testFloorCatchesTenPercentAndBelow() {
        for level: Float in [0, 0.05, 0.10] {
            XCTAssertTrue(
                HeatEngine.atBatteryFloor(level: level, state: .unplugged),
                "\(level) should be at the floor")
        }
    }

    /// The tolerance is there for Float noise, not to move the floor: anything
    /// a user would read as 11% still gets to warm.
    func testFloorDoesNotCreepAboveTenPercent() {
        XCTAssertFalse(HeatEngine.atBatteryFloor(level: 0.102, state: .unplugged))
    }

    func testAboveTheFloorIsFine() {
        for level: Float in [0.15, 0.20, 1.0] {
            XCTAssertFalse(
                HeatEngine.atBatteryFloor(level: level, state: .unplugged),
                "\(level) should be above the floor")
        }
    }

    /// A device on the charger is refilling, so the floor does not apply — and
    /// an unknown level (-1, the simulator) is not a reading at all.
    func testChargingAndUnknownLevelsAreNotAtTheFloor() {
        XCTAssertFalse(HeatEngine.atBatteryFloor(level: 0.05, state: .charging))
        XCTAssertFalse(HeatEngine.atBatteryFloor(level: 0.05, state: .full))
        XCTAssertFalse(HeatEngine.atBatteryFloor(level: -1, state: .unknown))
    }

    // MARK: - Lifecycle

    // The engine drives the Live Activity controller, which is main-actor
    // isolated, so these have to run there too — the isolation is what makes
    // that a compile error instead of an occasional flake.

    @MainActor
    func testStartThenStopTogglesIsRunning() throws {
        let engine = HeatEngine()
        try XCTSkipIf(
            ProcessInfo.processInfo.thermalState == .critical,
            "start() refuses to run while the host is thermally critical")

        engine.start()
        XCTAssertTrue(engine.isRunning)

        engine.stop()
        XCTAssertFalse(engine.isRunning)
    }

    @MainActor
    func testStopWithoutStartIsHarmless() {
        let engine = HeatEngine()
        engine.stop()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.sessionSeconds, 0)
    }

    /// The initial heat level has to start inside the band for the current
    /// thermal state, otherwise the bar contradicts its own label on launch.
    @MainActor
    func testInitialHeatLevelSitsInsideItsBand() {
        let engine = HeatEngine()
        let band = HeatEngine.band(for: engine.thermalState)
        XCTAssertTrue(band.contains(engine.heatLevel))
    }

    @MainActor
    func testCoreCountIsPositive() {
        XCTAssertGreaterThan(HeatEngine().coreCount, 0)
    }
}
