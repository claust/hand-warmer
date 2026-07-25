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

    /// Continuous 0...1 stand-in for temperature, for the heat meter.
    /// `thermalState` only has four steps and changes minutes apart, so the
    /// raw value would make the bar sit still and then jump. Instead each
    /// state owns a band of the bar and we creep through that band while
    /// warming, so the meter always moves and never contradicts the label.
    @Published private(set) var heatLevel: Double = 0

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
    private var heatTimer: AnyCancellable?
    private var bandEntered = Date()
    private var startedAt = Date()
    private var centralManager: CBCentralManager?
    private var locationManager: CLLocationManager?
    private let keepAlive = BackgroundKeepAlive()
    private let island = HeatActivityController()

    override init() {
        super.init()
        // Weak, not unowned: the controller's in-flight request task holds the
        // controller, so it can outlive this engine by a moment and pull one
        // last snapshot on the way out.
        island.snapshot = { [weak self] in self?.activityState() }
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBattery()
        thermalState = ProcessInfo.processInfo.thermalState
        heatLevel = Self.band(for: thermalState).lowerBound

        // Runs whether or not the warmer is on: the bar also has to ease back
        // down while the phone cools off.
        heatTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.stepHeatLevel() }

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
        keepAlive.stop()
        island.end()
        NotificationCenter.default.removeObserver(self)
    }

    /// Told by the scene phase. Only affects how hard the Dynamic Island is
    /// driven — the heat itself runs the same either way.
    func setBackgrounded(_ backgrounded: Bool) {
        island.setBackgrounded(backgrounded)
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
        bandEntered = Date()
        startedAt = Date()

        // Before the workers, so we are already holding the audio session by
        // the time the user can plausibly swipe up out of the app.
        keepAlive.start()

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
        island.begin(coreCount: coreCount)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopFlag.set(true)
        timer = nil
        syncBoosters()
        island.end()
        keepAlive.stop()
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
            if i == 0 { x += 1 }  // keep the optimizer from deleting the loop
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
        cm.scanForPeripherals(
            withServices: nil,
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

    // MARK: - Heat meter

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

    /// Seconds of warming it takes to cross one band. Chosen so the bar is
    /// visibly moving from the first second without racing ahead of reality.
    private static let bandCrossing: TimeInterval = 150

    private func stepHeatLevel() {
        let band = Self.band(for: thermalState)
        let target: Double
        if isRunning {
            let progress = min(1, Date().timeIntervalSince(bandEntered) / Self.bandCrossing)
            target = band.lowerBound + (band.upperBound - band.lowerBound) * progress
        } else {
            target = band.lowerBound
        }
        // Exponential ease, so a band change glides instead of snapping.
        let rate = isRunning ? 0.3 : 0.06
        let next = heatLevel + (target - heatLevel) * rate
        if abs(next - heatLevel) > 0.0005 { heatLevel = next }
    }

    // MARK: - Live Activity

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

    /// Current readings for the island. `flamePhase` is filled in by the
    /// controller, which owns the animation clock.
    private func activityState() -> HeatActivityAttributes.ContentState {
        // CPU is unconditional while warming, matching the locked chip in the
        // booster bar.
        var symbols = ["cpu"]
        if gpsBoost { symbols.append("location.fill") }
        if bluetoothBoost { symbols.append("dot.radiowaves.left.and.right") }
        if torchBoost { symbols.append("flashlight.on.fill") }

        return HeatActivityAttributes.ContentState(
            startedAt: startedAt,
            heatLevel: heatLevel,
            thermalLabel: Self.label(for: thermalState),
            batteryLevel: batteryLevel,
            flamePhase: 0,
            boosterSymbols: symbols)
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
            let new = ProcessInfo.processInfo.thermalState
            if new != self.thermalState {
                self.bandEntered = Date()
                // Snap into the new band rather than easing across it: while
                // the level drifted from Hot down to Warm the bar would sit in
                // the Hot band under a "Warm" label, which is exactly the
                // contradiction the bands exist to prevent. The view animates
                // the jump, so it still reads as a glide.
                let band = Self.band(for: new)
                self.heatLevel = min(max(self.heatLevel, band.lowerBound), band.upperBound)
            }
            self.thermalState = new
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
