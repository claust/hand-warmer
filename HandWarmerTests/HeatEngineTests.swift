import XCTest

@testable import HandWarmer

final class HeatEngineTests: XCTestCase {

    private let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

    // MARK: - Heat meter bands

    /// The bands are the contract between the bar and its label: they must tile
    /// the whole meter with no gap and no overlap, or some fill level would sit
    /// under a label that contradicts it.
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

    // MARK: - Lifecycle

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

    func testStopWithoutStartIsHarmless() {
        let engine = HeatEngine()
        engine.stop()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.sessionSeconds, 0)
    }

    /// The initial heat level has to start inside the band for the current
    /// thermal state, otherwise the bar contradicts its own label on launch.
    func testInitialHeatLevelSitsInsideItsBand() {
        let engine = HeatEngine()
        let band = HeatEngine.band(for: engine.thermalState)
        XCTAssertTrue(band.contains(engine.heatLevel))
    }

    func testCoreCountIsPositive() {
        XCTAssertGreaterThan(HeatEngine().coreCount, 0)
    }
}
