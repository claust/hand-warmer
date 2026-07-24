import Foundation
import UIKit
import CoreBluetooth
import CoreLocation
import AVFoundation
import Combine

/// Drives everything that makes the device warm: a busy-loop worker per CPU
/// core, plus optional radio/sensor "boosters". Also publishes battery and
/// thermal telemetry for the UI.
final class HeatEngine: NSObject, ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var sessionSeconds = 0
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var batteryState: UIDevice.BatteryState = .unknown
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var criticalShutdown = false

    // Boosters (CPU load is always on while running).
    @Published var gpsBoost = false { didSet { syncBoosters() } }
    @Published var bluetoothBoost = false { didSet { syncBoosters() } }
    @Published var torchBoost = false { didSet { syncBoosters() } }

    let coreCount = ProcessInfo.processInfo.activeProcessorCount

    /// Shared stop flag read by the worker threads. NSLock-guarded; workers
    /// check it once per chunk of math so the lock cost is negligible.
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set(_ v: Bool) {
            lock.lock(); value = v; lock.unlock()
        }
    }

    private var stopFlag = Flag()
    private var timer: AnyCancellable?
    private var centralManager: CBCentralManager?
    private var locationManager: CLLocationManager?

    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBattery()
        thermalState = ProcessInfo.processInfo.thermalState

        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshBattery),
            name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshBattery),
            name: UIDevice.batteryStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    deinit {
        // The worker threads hold the flag, not self, so nothing else would
        // ever stop them if this engine went away mid-session — they would
        // spin for the lifetime of the process.
        stopFlag.set(true)
        setTorch(on: false)
        NotificationCenter.default.removeObserver(self)
    }

    var lowBattery: Bool {
        batteryLevel >= 0 && batteryLevel < 0.2 && batteryState != .charging && batteryState != .full
    }

    // MARK: - Control

    func start() {
        guard !isRunning else { return }

        // thermalStateDidChange only fires on transitions, so a device that is
        // already critical would sail past the safety valve and never trip it.
        // Check the live state before spinning anything up.
        thermalState = ProcessInfo.processInfo.thermalState
        guard thermalState != .critical else {
            criticalShutdown = true
            return
        }

        isRunning = true
        criticalShutdown = false
        sessionSeconds = 0

        stopFlag = Flag()
        let flag = stopFlag
        for core in 0..<coreCount {
            let thread = Thread {
                Self.burn(flag: flag, seed: core)
            }
            thread.name = "heat.worker.\(core)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }

        timer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.sessionSeconds += 1 }

        syncBoosters()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopFlag.set(true)
        timer = nil
        syncBoosters()
    }

    /// Pure math busy loop. The work is meaningless on purpose — its only job
    /// is to keep the ALU and FPU of one core saturated until told to stop.
    private static func burn(flag: Flag, seed: Int) {
        var x = Double(seed + 2)
        var i: UInt64 = 0
        while !flag.isSet {
            for _ in 0..<200_000 {
                x = (x * 1.0000001).truncatingRemainder(dividingBy: 1e12) + 1.0001
                i = i &* 2862933555777941757 &+ 3037000493
            }
            if i == 0 { x += 1 } // keep the optimizer from deleting the loop
        }
    }

    // MARK: - Boosters

    private func syncBoosters() {
        let active = isRunning

        if active && bluetoothBoost {
            if centralManager == nil {
                // Deliver delegate callbacks on main, the same queue that
                // syncBoosters and the UI toggles run on, so the manager is
                // only ever touched from one thread. Scanning itself still
                // happens on the Bluetooth hardware, and we implement no
                // discovery callback, so nothing floods main.
                centralManager = CBCentralManager(delegate: self, queue: .main)
            } else {
                startScanIfPoweredOn()
            }
        } else {
            centralManager?.stopScan()
            centralManager = nil
        }

        if active && gpsBoost {
            if locationManager == nil {
                let lm = CLLocationManager()
                lm.delegate = self
                lm.desiredAccuracy = kCLLocationAccuracyBestForNavigation
                locationManager = lm
            }
            if locationManager?.authorizationStatus == .notDetermined {
                locationManager?.requestWhenInUseAuthorization()
            }
            locationManager?.startUpdatingLocation()
        } else {
            locationManager?.stopUpdatingLocation()
        }

        setTorch(on: active && torchBoost)
    }

    private func startScanIfPoweredOn() {
        guard let cm = centralManager, cm.state == .poweredOn, !cm.isScanning else { return }
        // Allowing duplicates keeps the radio continuously busy.
        cm.scanForPeripherals(withServices: nil,
                              options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func setTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        // Only unlock if the lock was actually acquired, and unlock on every
        // exit path — leaving the device locked would break later torch and
        // camera use for the rest of the process.
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }

        do {
            if on {
                try device.setTorchModeOn(level: 1.0)
            } else {
                device.torchMode = .off
            }
        } catch {
            // Torch is best-effort; ignore failures (e.g. camera in use).
        }
    }

    // MARK: - Telemetry

    @objc private func refreshBattery() {
        DispatchQueue.main.async {
            self.batteryLevel = UIDevice.current.batteryLevel
            self.batteryState = UIDevice.current.batteryState
        }
    }

    @objc private func thermalChanged() {
        DispatchQueue.main.async {
            self.thermalState = ProcessInfo.processInfo.thermalState
            // Safety valve: if iOS reports critical heat, shut down rather
            // than fight the system's own throttling.
            if self.thermalState == .critical, self.isRunning {
                self.stop()
                self.criticalShutdown = true
            }
        }
    }
}

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
