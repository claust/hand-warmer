import SwiftUI

/// The boosters, moved off the main screen and behind a single button.
///
/// Six chips laid out under the flame pushed the title off the top of the
/// display on a shorter phone, so they now live in a translucent card that
/// floats over the flame instead — the heat and battery bars stay readable
/// through it, which is the point of switching a booster on in the first place.
struct BoosterPanel: View {
    @EnvironmentObject private var engine: HeatEngine
    @Binding var isPresented: Bool

    /// Passed in rather than recomputed: ContentView's `-battery` debug
    /// override has to move the status line here in step with the main screen.
    let batteryCutoff: Bool

    var body: some View {
        ZStack {
            // Dims what is behind and takes the tap that dismisses. Explicitly
            // a button so VoiceOver can reach the dismiss action at all — a
            // bare `onTapGesture` on a decorative shape is invisible to it.
            Button {
                dismiss()
            } label: {
                Color.black.opacity(0.35).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close boosters")

            card
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            Text("BOOSTERS")
                .font(.caption.weight(.heavy))
                .tracking(2)
                .foregroundStyle(.secondary)

            // Two rows of three: six across a phone would squeeze every chip
            // narrower than its own label. Silicon on the top row, the
            // peripherals that hang off it below.
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    chip("CPU", icon: "cpu", isOn: .constant(true), locked: true)
                    chip(
                        "GPU", icon: "memorychip", isOn: $engine.gpuBoost,
                        available: GPUBurner.isSupported)
                    chip(
                        "Neural", icon: "brain", isOn: $engine.neuralBoost,
                        available: NeuralBurner.isSupported)
                }
                HStack(spacing: 12) {
                    chip("GPS", icon: "location.fill", isOn: $engine.gpsBoost)
                    chip("Bluetooth", icon: "dot.radiowaves.left.and.right", isOn: $engine.bluetoothBoost)
                    chip("Torch", icon: "flashlight.on.fill", isOn: $engine.torchBoost)
                }
            }

            status

            Button("Done") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        .padding(.horizontal, 20)
    }

    private var status: some View {
        Group {
            if engine.isRunning {
                Text("Warming on all \(engine.coreCount) cores · \(formattedTime)")
            } else if batteryCutoff {
                Text("Cold hands beat a dead phone. Find a charger.")
            } else {
                Text("Once started, it keeps warming in your pocket")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    /// `locked` marks a booster that is always on and cannot be switched off;
    /// `available: false` marks one this device cannot run at all. Both end up
    /// disabled, but they read differently to VoiceOver and to the eye.
    private func chip(
        _ title: String, icon: String,
        isOn: Binding<Bool>, locked: Bool = false, available: Bool = true
    ) -> some View {
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
                    .fill(isOn.wrappedValue ? Color.orange.opacity(0.25) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isOn.wrappedValue ? Color.orange : Color.white.opacity(0.15))
            )
            .foregroundStyle(isOn.wrappedValue ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        // CPU load is always on while warming, so its chip is a status
        // indicator rather than a control: disabling it stops the tap
        // highlight and makes VoiceOver announce it as unavailable.
        .disabled(locked || !available)
        .opacity(available ? (locked ? 0.9 : 1) : 0.35)
        .accessibilityLabel(label(title, locked: locked, available: available))
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func label(_ title: String, locked: Bool, available: Bool) -> String {
        if !available { return "\(title) booster, unavailable on this device" }
        return locked ? "\(title) booster, always on" : "\(title) booster"
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.2)) { isPresented = false }
    }

    private var formattedTime: String {
        let m = engine.sessionSeconds / 60
        let s = engine.sessionSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
