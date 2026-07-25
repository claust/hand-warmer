import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: HeatEngine
    @State private var flameIntensity: CGFloat = 0
    @State private var showLowBatteryWarning = false
    @State private var showBoosters = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 24) {
                header
                Spacer()
                flameAndButton
                Spacer()
                boosterButton
            }
            .padding()

            if showBoosters {
                BoosterPanel(isPresented: $showBoosters, batteryCutoff: batteryCutoff)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .alert("Low battery", isPresented: $showLowBatteryWarning) {
            Button("Warm me anyway", role: .destructive) { activate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Battery is below 20%. The hand warmer drains power very quickly — "
                    + "your phone may shut down completely while it runs."
            )
        }
        .alert("Out of juice", isPresented: $engine.batteryShutdown) {
            Button("Fine") {}
        } message: {
            // Covers both ways the engine raises this: a session stopping at
            // the floor, and a start refused there.
            Text(
                "The warmer stops at \(Int(HeatEngine.batteryFloor * 100))% and won't start "
                    + "below it. Your phone would like to survive long enough to call "
                    + "someone about those cold hands."
            )
        }
        .alert("Too hot!", isPresented: $engine.criticalShutdown) {
            Button("OK") {}
        } message: {
            Text(
                "iOS is reporting a critical thermal state, so the warmer is not running. "
                    + "Let the phone cool down for a bit before warming again."
            )
        }
        .onChange(of: engine.isRunning) { _, running in
            withAnimation(.easeInOut(duration: running ? 2.2 : 0.8)) {
                flameIntensity = running ? 1 : 0
            }
        }
        .onAppear {
            // Debug hooks so automated runs can exercise the active state.
            // `-boosters gpu,neural` switches boosters on before the session
            // starts, which is the only way to reach them on a device the
            // test harness cannot tap.
            applyBoosterOverrides()
            if ProcessInfo.processInfo.arguments.contains("-autostart") {
                toggle()
            }
        }
    }

    // MARK: - Pieces

    private var background: some View {
        LinearGradient(
            colors: engine.isRunning
                ? [Color(red: 0.14, green: 0.04, blue: 0.01), .black]
                : [Color(red: 0.05, green: 0.07, blue: 0.12), .black],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 2), value: engine.isRunning)
    }

    private var header: some View {
        VStack(spacing: 14) {
            Text("Hand Warmer")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))

            VStack(spacing: 14) {
                MeterBar(
                    title: "HEAT",
                    systemImage: "thermometer.medium",
                    valueText: thermalText,
                    fraction: engine.heatLevel,
                    gradient: .heat,
                    valueColor: thermalColor,
                    ticks: [0.30, 0.60, 0.85],
                    accessibilityValue: "\(thermalText), \(Int(engine.heatLevel * 100)) percent")

                MeterBar(
                    title: "BATTERY",
                    systemImage: batteryIcon,
                    valueText: batteryText,
                    fraction: batteryFraction,
                    gradient: .battery(batteryColor),
                    span: .fill,
                    valueColor: batteryColor)
            }
            .padding(.horizontal, 4)
        }
    }

    private var flameAndButton: some View {
        VStack(spacing: 0) {
            FlameView(intensity: flameIntensity)
                .frame(width: 220, height: 240)

            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: engine.isRunning
                                    ? [Color.orange, Color(red: 0.75, green: 0.15, blue: 0.0)]
                                    : [
                                        Color(red: 0.25, green: 0.3, blue: 0.4),
                                        Color(red: 0.1, green: 0.12, blue: 0.18),
                                    ],
                                center: .center, startRadius: 8, endRadius: 90)
                        )
                        .frame(width: 150, height: 150)
                        .shadow(color: engine.isRunning ? .orange.opacity(0.7) : .clear, radius: 35)
                    VStack(spacing: 6) {
                        Image(systemName: buttonIcon)
                            .font(.system(size: 44))
                        Text(buttonTitle)
                            .font(.caption.weight(.heavy))
                            .tracking(2)
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            // Below the floor there is nothing to start, so the button becomes
            // a sign rather than a control.
            .disabled(batteryCutoff)
            .opacity(batteryCutoff ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.3), value: batteryCutoff)
            .accessibilityLabel(batteryCutoff ? "Hand warmer unavailable, battery too low" : buttonTitle)
            .sensoryFeedback(.impact(weight: .heavy), trigger: engine.isRunning)
        }
    }

    /// The only thing left where the chip grid used to be. It carries the
    /// count as well as the icon, so the state of the boosters is still
    /// legible without opening anything.
    private var boosterButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showBoosters = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(boosterSummary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
            .foregroundStyle(activeBoosters > 0 ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Boosters")
        .accessibilityValue(boosterSummary)
        .accessibilityHint("Opens the booster controls")
    }

    /// CPU is excluded: it is always on, so counting it would make "1 on" the
    /// resting state and mean nothing.
    private var activeBoosters: Int {
        [
            engine.gpuBoost, engine.neuralBoost, engine.gpsBoost,
            engine.bluetoothBoost, engine.torchBoost,
        ]
        .filter { $0 }.count
    }

    private var boosterSummary: String {
        activeBoosters == 0 ? "Boosters · CPU only" : "Boosters · \(activeBoosters + 1) on"
    }

    // MARK: - Actions & formatting

    /// Read off the view's `batteryLevel` rather than the engine's, so the
    /// `-battery` debug override moves the button and the readout together.
    private var batteryCutoff: Bool {
        HeatEngine.atBatteryFloor(level: batteryLevel, state: engine.batteryState)
    }

    private var buttonIcon: String {
        if batteryCutoff { return "bolt.slash.fill" }
        return engine.isRunning ? "flame.fill" : "flame"
    }

    private var buttonTitle: String {
        if batteryCutoff { return "NO JUICE" }
        return engine.isRunning ? "STOP" : "WARM ME"
    }

    private func toggle() {
        if engine.isRunning {
            engine.stop()
        } else if batteryCutoff {
            // Belt and braces: the button is disabled, but -autostart calls
            // this directly.
            return
        } else if engine.lowBattery {
            showLowBatteryWarning = true
        } else {
            activate()
        }
    }

    private func activate() {
        engine.start()
    }

    private func applyBoosterOverrides() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-boosters"), i + 1 < args.count else { return }
        let names = Set(args[i + 1].split(separator: ",").map(String.init))
        engine.gpuBoost = names.contains("gpu")
        engine.neuralBoost = names.contains("neural")
        engine.gpsBoost = names.contains("gps")
        engine.bluetoothBoost = names.contains("bluetooth")
        engine.torchBoost = names.contains("torch")
    }

    private var thermalText: String { HeatEngine.label(for: engine.thermalState) }

    private var thermalColor: Color {
        switch engine.thermalState {
        case .nominal: return .cyan
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    /// Debug hook, like `-autostart`: `-battery 0.15` pins the readout so the
    /// low-battery colours can be checked without draining a real phone.
    private var batteryLevel: Float {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-battery"), i + 1 < args.count,
            let override = Float(args[i + 1])
        {
            // A negative value still means "unknown", matching
            // UIDevice.batteryLevel, but nothing above full is a real reading.
            return min(override, 1)
        }
        return engine.batteryLevel
    }

    private var batteryColor: Color {
        guard batteryLevel >= 0 else { return .secondary }
        // Same thresholds as `Gradient.battery`, so the number and the tip of
        // the bar are never two different colours.
        switch batteryLevel {
        case ..<0.10: return .red
        case ..<0.20: return .yellow
        default: return .green
        }
    }

    private var batteryText: String {
        batteryLevel < 0 ? "– %" : "\(Int(batteryLevel * 100)) %"
    }

    /// A device that reports no battery (the simulator) leaves the bar empty
    /// rather than pretending to be full.
    private var batteryFraction: Double {
        batteryLevel < 0 ? 0 : Double(batteryLevel)
    }

    private var batteryIcon: String {
        if engine.batteryState == .charging { return "battery.100percent.bolt" }
        guard batteryLevel >= 0 else { return "battery.50percent" }
        switch batteryLevel {
        case ..<0.25: return "battery.25percent"
        case ..<0.55: return "battery.50percent"
        case ..<0.85: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

#Preview {
    ContentView().environmentObject(HeatEngine())
}
