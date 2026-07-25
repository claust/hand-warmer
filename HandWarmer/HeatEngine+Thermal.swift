import Foundation

// How a thermal state is presented — the band it owns on the heat meter and the
// word that goes with it. Both are pure functions of the state and are read by
// the main screen, the widget and the tests, so they live apart from the engine
// that produces the state. Splitting them out also keeps HeatEngine.swift within
// its length budget.

extension HeatEngine {

    /// Slice of the meter owned by each thermal state.
    static func band(for state: ProcessInfo.ThermalState) -> ClosedRange<Double> {
        switch state {
        case .nominal: return 0.00...0.30
        case .fair: return 0.30...0.60
        case .serious: return 0.60...0.85
        case .critical: return 0.85...1.00
        @unknown default: return 0.00...0.30
        }
    }

    /// Short label for a thermal state, shared by the main screen and the
    /// Dynamic Island so the two readouts can never disagree.
    static func label(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        @unknown default: return "Unknown"
        }
    }
}
