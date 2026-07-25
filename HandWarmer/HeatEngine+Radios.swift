import CoreBluetooth
import CoreLocation

// The radio boosters' delegate callbacks, split out of HeatEngine.swift to keep
// that file within its length budget.

extension HeatEngine: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // A late state update (Bluetooth switched back on, say) must not
        // resurrect a scan the user has since turned off.
        guard isRunning, bluetoothBoost else { return }
        startScanIfPoweredOn()
    }
}

extension HeatEngine: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isRunning && gpsBoost { manager.startUpdatingLocation() }
    }
}
