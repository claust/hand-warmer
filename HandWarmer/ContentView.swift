import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: HeatEngine
    @State private var flameIntensity: CGFloat = 0
    @State private var showLowBatteryWarning = false
    @State private var showBoosters = false
    @StateObject private var touches = TouchQuietMonitor()
    /// Bumped every time a tap is refused for arriving on a busy screen; drives
    /// the warning haptic and the explanation under the button.
    @State private var refusals = 0
    @State private var refusing = false

    var body: some View {
        ZStack {
            background
            TouchQuietReporter(monitor: touches)

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
            // Nothing left to explain once the session is over — the engine
            // stops itself at the battery floor and in a critical thermal
            // state, both of which can land mid-refusal.
            if !running { refusing = false }
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

            // While warming, the button's size *is* the guard: it shrinks to
            // almost nothing the moment anything touches the screen and grows
            // back over the quiet window. A palm has almost nothing to hit.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !engine.isRunning)) { context in
                let progress = engine.isRunning ? touches.quiet.progress(at: context.date) : 1
                stopButton(labelled: progress >= 1)
                    .scaleEffect(Self.hiddenScale + (1 - Self.hiddenScale) * progress)
            }
            // Reserved whatever the button is doing, so a shrinking button
            // doesn't drag the layout around with it.
            .frame(width: 176, height: 176)

            refusalNote
        }
    }

    /// How small the button gets on a busy screen: 12% of full size.
    private static let hiddenScale: CGFloat = 0.12

    /// - Parameter labelled: whether the icon and STOP caption are shown. They
    ///   arrive only once the button is back at full size, so the label is a
    ///   statement that the tap will be taken — not decoration on a button that
    ///   would refuse it. Shrunk, they would be an illegible smudge anyway.
    private func stopButton(labelled: Bool) -> some View {
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
                .opacity(labelled ? 1 : 0)
                .scaleEffect(labelled ? 1 : 0.55)
                .blur(radius: labelled ? 0 : 6)
                .animation(.spring(response: 0.4, dampingFraction: 0.7), value: labelled)
            }
        }
        .buttonStyle(.plain)
        // A refused tap is worth a flinch: it says the button felt the tap and
        // turned it down, rather than missing it.
        .modifier(Wobble(trigger: refusals))
        // Below the floor there is nothing to start, so the button becomes a
        // sign rather than a control.
        .disabled(batteryCutoff)
        .opacity(batteryCutoff ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.3), value: batteryCutoff)
        .accessibilityLabel(accessibilityLabel)
        .sensoryFeedback(.impact(weight: .heavy), trigger: engine.isRunning)
        .sensoryFeedback(.warning, trigger: refusals)
        .task(id: refusals) { await explainRefusal() }
    }

    /// Sits under the button in space that is always reserved, so the layout
    /// doesn't jump when a refusal appears.
    private var refusalNote: some View {
        Text("Screen must be still for \(Int(TouchQuiet.required))s before STOP works")
            .font(.footnote.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.orange)
            .opacity(refusing ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: refusing)
            .frame(height: 40)
            .padding(.horizontal)
            .accessibilityHidden(!refusing)
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

    private var accessibilityLabel: String {
        if batteryCutoff { return "Hand warmer unavailable, battery too low" }
        return buttonTitle
    }

    private func toggle() {
        if engine.isRunning {
            // The guard is only on stopping. Starting by accident costs a tap
            // to undo; stopping by accident costs all the heat in the phone.
            guard touches.wasArmedAtLatestTouchDown else {
                refusals += 1
                return
            }
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

    /// Shows the explanation for a few seconds after a refused tap. Keyed on
    /// the count, so a second refusal restarts the clock rather than letting
    /// the first one's timer clear a message that has just been re-shown.
    private func explainRefusal() async {
        guard refusals > 0 else { return }
        refusing = true
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        refusing = false
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
