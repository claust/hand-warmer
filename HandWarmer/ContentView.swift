import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: HeatEngine
    @State private var flameIntensity: CGFloat = 0
    @State private var showLowBatteryWarning = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 24) {
                header
                Spacer()
                flameAndButton
                Spacer()
                boosterBar
                statusFooter
            }
            .padding()
        }
        .alert("Low battery", isPresented: $showLowBatteryWarning) {
            Button("Warm me anyway", role: .destructive) { activate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Battery is below 20%. The hand warmer drains power very quickly — your phone may shut down completely while it runs.")
        }
        .alert("Too hot!", isPresented: $engine.criticalShutdown) {
            Button("OK") {}
        } message: {
            Text("iOS is reporting a critical thermal state, so the warmer is not running. Let the phone cool down for a bit before warming again.")
        }
        .onChange(of: engine.isRunning) { _, running in
            withAnimation(.easeInOut(duration: running ? 2.2 : 0.8)) {
                flameIntensity = running ? 1 : 0
            }
        }
        .onAppear {
            // Debug hook so automated runs can exercise the active state.
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
            startPoint: .top, endPoint: .bottom)
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
                                    : [Color(red: 0.25, green: 0.3, blue: 0.4), Color(red: 0.1, green: 0.12, blue: 0.18)],
                                center: .center, startRadius: 8, endRadius: 90))
                        .frame(width: 150, height: 150)
                        .shadow(color: engine.isRunning ? .orange.opacity(0.7) : .clear, radius: 35)
                    VStack(spacing: 6) {
                        Image(systemName: engine.isRunning ? "flame.fill" : "flame")
                            .font(.system(size: 44))
                        Text(engine.isRunning ? "STOP" : "WARM ME")
                            .font(.caption.weight(.heavy))
                            .tracking(2)
                    }
                    .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .heavy), trigger: engine.isRunning)
        }
    }

    private var boosterBar: some View {
        HStack(spacing: 12) {
            boosterToggle("CPU", icon: "cpu", isOn: .constant(true), locked: true)
            boosterToggle("GPS", icon: "location.fill", isOn: $engine.gpsBoost)
            boosterToggle("Bluetooth", icon: "dot.radiowaves.left.and.right", isOn: $engine.bluetoothBoost)
            boosterToggle("Torch", icon: "flashlight.on.fill", isOn: $engine.torchBoost)
        }
    }

    private func boosterToggle(_ title: String, icon: String,
                               isOn: Binding<Bool>, locked: Bool = false) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isOn.wrappedValue ? Color.orange.opacity(0.25) : Color.white.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isOn.wrappedValue ? Color.orange : Color.white.opacity(0.15)))
            .foregroundStyle(isOn.wrappedValue ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        // CPU load is always on while warming, so its chip is a status
        // indicator rather than a control: disabling it stops the tap
        // highlight and makes VoiceOver announce it as unavailable.
        .disabled(locked)
        .opacity(locked ? 0.9 : 1)
        .accessibilityLabel(locked ? "\(title) booster, always on" : "\(title) booster")
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private var statusFooter: some View {
        Group {
            if engine.isRunning {
                Text("Warming on all \(engine.coreCount) cores · \(formattedTime)")
            } else {
                Text("Once started, it keeps warming in your pocket")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    // MARK: - Actions & formatting

    private func toggle() {
        if engine.isRunning {
            engine.stop()
        } else if engine.lowBattery {
            showLowBatteryWarning = true
        } else {
            activate()
        }
    }

    private func activate() {
        engine.start()
    }

    private var formattedTime: String {
        let m = engine.sessionSeconds / 60, s = engine.sessionSeconds % 60
        return String(format: "%d:%02d", m, s)
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
           let override = Float(args[i + 1]) {
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
