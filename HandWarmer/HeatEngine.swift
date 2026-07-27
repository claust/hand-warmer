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
    @Published var batteryShutdown = false

    /// Continuous 0...1 stand-in for temperature, for the heat meter.
    /// `thermalState` only has four steps and changes minutes apart, so the
    /// raw value would make the bar sit still and then jump. Instead each
    /// state owns a band of the bar and we creep through that band while
    /// warming, so the meter always moves and never contradicts the label.
    @Published private(set) var heatLevel: Double = 0

    // Boosters (CPU load is always on while running). Everything that only
    // heats the phone starts on — that is what the app is for. The torch is
    // the exception: it is the one booster that is visible across a room and
    // would surprise someone who just wanted warm hands.
    // Seeded from support rather than a flat `true`, so a device that cannot
    // run one of them doesn't show a chip that reads "on" while it is dimmed
    // out and producing nothing.
    @Published var gpuBoost = GPUBurner.isSupported { didSet { syncBoosters() } }
    @Published var neuralBoost = NeuralBurner.isSupported { didSet { syncBoosters() } }
    @Published var gpsBoost = true { didSet { syncBoosters() } }
    @Published var bluetoothBoost = true { didSet { syncBoosters() } }
    @Published var torchBoost = false { didSet { syncBoosters() } }

    let coreCount = ProcessInfo.processInfo.activeProcessorCount

    private var stopFlag = StopFlag()
    private var timer: AnyCancellable?
    private var heatTimer: AnyCancellable?
    private var bandEntered = Date()
    private var startedAt = Date()
    private var centralManager: CBCentralManager?
    private var locationManager: CLLocationManager?
    private let gpuBurner = GPUBurner()
    private let neuralBurner = NeuralBurner()
    private let keepAlive = BackgroundKeepAlive()
    private let island = HeatActivityController()

    @MainActor
    override init() {
        super.init()
        // Weak, not unowned: the controller's in-flight request task holds the
        // controller, so it can outlive this engine by a moment and pull one
        // last snapshot on the way out.
        island.snapshot = { [weak self] in self?.activityState() }
        UIDevice.current.isBatteryMonitoringEnabled = true
        // Seeded here rather than through `refreshBattery`, whose hop to main
        // would leave the level at -1 for a runloop turn — long enough for a
        // start on the first frame to sail past the battery floor.
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
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
        // The GPU worker is stopped by the burner's own deinit, which runs as
        // this property is released a moment from now.
        Self.setTorch(on: false)
        keepAlive.stop()
        NotificationCenter.default.removeObserver(self)

        // No `island.end()` here. A deinit cannot touch the main-actor-isolated
        // controller, and the call was close to theatre anyway: ending an
        // activity is async, so at process teardown — the only time the
        // retained engine deinits — it could never have completed. The engines
        // SwiftUI discards never started a session, so they have nothing to
        // end. `stop()` remains the real path, and `begin()` sweeps anything a
        // crash leaves behind.
    }

    /// Told by the scene phase. Only affects how hard the Dynamic Island is
    /// driven — the heat itself runs the same either way.
    @MainActor
    func setBackgrounded(_ backgrounded: Bool) {
        island.setBackgrounded(backgrounded)
    }

    var lowBattery: Bool {
        batteryLevel >= 0 && batteryLevel < 0.2 && batteryState != .charging && batteryState != .full
    }

    /// Refuse to run at or below this: a dead phone is worse than cold hands.
    static let batteryFloor: Float = 0.10

    /// Shared by the engine and the UI so the button and the auto-stop can never
    /// disagree. The epsilon covers Float noise at 0.1 and nothing more.
    static func atBatteryFloor(level: Float, state: UIDevice.BatteryState) -> Bool {
        level >= 0 && level <= batteryFloor + 0.0001 && state != .charging && state != .full
    }

    var atBatteryFloor: Bool { Self.atBatteryFloor(level: batteryLevel, state: batteryState) }

    // MARK: - Control

    @MainActor
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

        // The UI blocks this too, but the floor is the engine's to enforce.
        guard !atBatteryFloor else {
            batteryShutdown = true
            return
        }

        isRunning = true
        criticalShutdown = false
        batteryShutdown = false
        sessionSeconds = 0
        bandEntered = Date()
        startedAt = Date()

        // Before the workers, so we are already holding the audio session by
        // the time the user can plausibly swipe up out of the app.
        keepAlive.start()

        stopFlag = StopFlag()
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

    @MainActor
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
    private static func burn(flag: StopFlag, seed: Int) {
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

        if active && gpuBoost {
            gpuBurner.start()
        } else {
            gpuBurner.stop()
        }

        if active && neuralBoost {
            neuralBurner.start()
        } else {
            neuralBurner.stop()
        }

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

        Self.setTorch(on: active && torchBoost)
    }

    /// Not private: the Bluetooth delegate lives in HeatEngine+Radios.swift.
    func startScanIfPoweredOn() {
        guard let cm = centralManager, cm.state == .poweredOn, !cm.isScanning else { return }
        // Allowing duplicates keeps the radio continuously busy.
        cm.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// Static because `deinit` has to switch the torch off and cannot call
    /// instance members of an isolated type; it touches no engine state anyway.
    private static func setTorch(on: Bool) {
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

    /// Current readings for the island. `flamePhase` is filled in by the
    /// controller, which owns the animation clock.
    private func activityState() -> HeatActivityAttributes.ContentState {
        // CPU is unconditional while warming, matching the locked chip in the
        // booster bar.
        var symbols = ["cpu"]
        if gpuBoost { symbols.append("memorychip") }
        if neuralBoost { symbols.append("brain") }
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
        // Battery notifications arrive on an arbitrary thread; hop to main the
        // same way `thermalChanged` does, and for the same reasons.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.batteryLevel = UIDevice.current.batteryLevel
                self.batteryState = UIDevice.current.batteryState

                // The other safety valve, alongside the thermal one: at the
                // floor the session ends itself rather than taking the phone
                // with it.
                if self.atBatteryFloor, self.isRunning {
                    self.stop()
                    self.batteryShutdown = true
                }
            }
        }
    }

    @objc private func thermalChanged() {
        // Thermal notifications arrive on an arbitrary thread, so the work is
        // queued onto main either way. This goes via the main runloop rather
        // than a `Task` to stay ordered with the rest of the engine's
        // main-queue work — the battery refresh and the heat-level tick — not
        // because it arrives any sooner. `assumeIsolated` is what lets it call
        // the main-actor-bound `stop()` as a checked fact rather than something
        // Swift 5.9's minimal concurrency checking merely lets through.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.applyThermalChange()
            }
        }
    }

    @MainActor
    private func applyThermalChange() {
        let new = ProcessInfo.processInfo.thermalState
        if new != thermalState {
            bandEntered = Date()
            // Snap into the new band rather than easing across it: while the
            // level drifted from Hot down to Warm the bar would sit in the Hot
            // band under a "Warm" label, which is exactly the contradiction the
            // bands exist to prevent. The view animates the jump, so it still
            // reads as a glide.
            let band = Self.band(for: new)
            heatLevel = min(max(heatLevel, band.lowerBound), band.upperBound)
        }
        thermalState = new
        // Safety valve: if iOS reports critical heat, shut down rather than
        // fight the system's own throttling.
        if thermalState == .critical, isRunning {
            stop()
            criticalShutdown = true
        }
    }
}
