import ActivityKit
import SwiftUI
import WidgetKit

/// The warmer as a Live Activity: a flame in the Dynamic Island while the app
/// is in your pocket, and a banner on the Lock Screen, the same way a running
/// timer presents itself.
struct HeatLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HeatActivityAttributes.self) { context in
            LockScreenBanner(context: context)
                .activityBackgroundTint(Color(red: 0.10, green: 0.03, blue: 0.01))
                .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        LiveFlame(phase: context.state.flamePhase,
                                  intensity: context.state.heatLevel)
                            .frame(width: 26, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Warming")
                                .font(.caption.weight(.semibold))
                            Text("\(context.attributes.coreCount) cores")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        elapsed(from: context.state.startedAt)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(context.state.thermalLabel)
                            .font(.caption2)
                            .foregroundStyle(heatColor(context.state.thermalLabel))
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        MeterBar(
                            title: "HEAT",
                            systemImage: "thermometer.medium",
                            valueText: context.state.thermalLabel,
                            fraction: context.state.heatLevel,
                            gradient: .heat,
                            valueColor: heatColor(context.state.thermalLabel),
                            ticks: [0.30, 0.60, 0.85])

                        HStack(spacing: 10) {
                            ForEach(context.state.boosterSymbols, id: \.self) { symbol in
                                Image(systemName: symbol)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Label(batteryText(context.state.batteryLevel),
                                  systemImage: "battery.50percent")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(batteryColor(context.state.batteryLevel))
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                LiveFlame(phase: context.state.flamePhase,
                          intensity: context.state.heatLevel)
                    .frame(width: 16, height: 21)
            } compactTrailing: {
                elapsed(from: context.state.startedAt)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
                    // The compact area sizes itself to its content, and a
                    // timer's width changes as the digits do; pin it so the
                    // island doesn't twitch every time the minute rolls over.
                    .frame(width: 42)
            } minimal: {
                LiveFlame(phase: context.state.flamePhase,
                          intensity: context.state.heatLevel)
                    .frame(width: 14, height: 19)
            }
            .keylineTint(.orange)
        }
    }
}

/// Lock Screen / Notification Centre presentation of the same session.
private struct LockScreenBanner: View {
    let context: ActivityViewContext<HeatActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            LiveFlame(phase: context.state.flamePhase,
                      intensity: context.state.heatLevel)
                .frame(width: 34, height: 46)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Hand Warmer")
                        .font(.headline)
                    Spacer()
                    elapsed(from: context.state.startedAt)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.orange)
                }

                MeterBar(
                    title: "HEAT",
                    systemImage: "thermometer.medium",
                    valueText: context.state.thermalLabel,
                    fraction: context.state.heatLevel,
                    gradient: .heat,
                    valueColor: heatColor(context.state.thermalLabel),
                    ticks: [0.30, 0.60, 0.85])

                HStack(spacing: 10) {
                    ForEach(context.state.boosterSymbols, id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("\(context.attributes.coreCount) cores · \(batteryText(context.state.batteryLevel))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}

// MARK: - Shared bits

/// A count-up clock the system runs itself. Without it we would have to push a
/// new activity state every second just to move the seconds digit.
private func elapsed(from start: Date) -> Text {
    // Open-ended rather than capped: any fixed end is a cliff where the clock
    // silently stops while the warmer is still running.
    Text(timerInterval: start...Date.distantFuture, countsDown: false)
}

/// Matches `ContentView.thermalColor`. Keyed off the label rather than a
/// re-derived number so the colour and the word can never disagree.
private func heatColor(_ label: String) -> Color {
    switch label {
    case "Cool": return .cyan
    case "Warm": return .yellow
    case "Hot": return .orange
    case "Very hot": return .red
    default: return .gray
    }
}

private func batteryText(_ level: Float) -> String {
    level < 0 ? "– %" : "\(Int(level * 100)) %"
}

private func batteryColor(_ level: Float) -> Color {
    guard level >= 0 else { return .secondary }
    switch level {
    case ..<0.10: return .red
    case ..<0.20: return .yellow
    default: return .green
    }
}
