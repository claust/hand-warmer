import SwiftUI

/// A labelled horizontal gauge. Used for the paired heat / battery readout,
/// where one bar filling as the other empties is the whole point.
struct MeterBar: View {
    /// What the gradient is spread across — the full track (so position on the
    /// track carries the meaning) or just the filled part (so the bar is one
    /// colour at a time).
    enum GradientSpan { case track, fill }

    let title: String
    let systemImage: String
    let valueText: String
    /// 0...1, clamped on the way in.
    let fraction: Double
    let gradient: Gradient
    var span: GradientSpan = .track
    /// Colour of the readout text. Tracks the current value, not the end of
    /// the gradient — "Cool" printed in red would be its own little lie.
    let valueColor: Color
    /// Fractions to mark on the track (thermal band boundaries).
    var ticks: [Double] = []
    var accessibilityValue: String?

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
                    .tracking(1.5)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            track
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? valueText)
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))

                Capsule()
                    .fill(LinearGradient(
                        gradient: gradient,
                        startPoint: .leading,
                        endPoint: gradientEndPoint))
                    .frame(width: fillWidth(in: width))
                    .shadow(color: valueColor.opacity(0.5), radius: 8)

                ForEach(ticks, id: \.self) { tick in
                    Capsule()
                        .fill(Color.black.opacity(0.45))
                        .frame(width: 1.5)
                        .offset(x: width * tick)
                }
            }
            .animation(.easeInOut(duration: 0.9), value: clamped)
        }
        .frame(height: 14)
    }

    /// Where the gradient ends, in the *fill's* coordinate space.
    ///
    /// `.track` pushes the end point out past the fill (hence the 1/fraction)
    /// so the ramp spans the whole track and a colour always means the same
    /// reading. `.fill` keeps it inside the fill, so the bar shades within one
    /// colour instead of showing the whole scale at once.
    private var gradientEndPoint: UnitPoint {
        switch span {
        case .track: return UnitPoint(x: min(1 / max(clamped, 0.05), 20), y: 0.5)
        case .fill: return .trailing
        }
    }

    /// Never let a non-zero reading round down to an invisible sliver, but do
    /// let a true zero disappear completely.
    private func fillWidth(in width: CGFloat) -> CGFloat {
        clamped <= 0 ? 0 : max(14, width * clamped)
    }
}

extension Gradient {
    /// Cool → very hot, evenly spread over the track.
    static let heat = Gradient(colors: [.cyan, .yellow, .orange, .red])

    /// One colour for the whole bar, shaded from deep to bright along its
    /// length. The bar reads as a single state — green, yellow or red — rather
    /// than showing the entire scale at every battery level.
    static func battery(_ color: Color) -> Gradient {
        Gradient(colors: [color.opacity(0.55), color])
    }
}

#Preview {
    VStack(spacing: 18) {
        MeterBar(title: "HEAT", systemImage: "thermometer.medium",
                 valueText: "Warm", fraction: 0.45,
                 gradient: .heat, valueColor: .yellow,
                 ticks: [0.30, 0.60, 0.85])
        ForEach([(0.72, Color.green), (0.35, .green), (0.15, .yellow), (0.08, .red)],
                id: \.0) { level, color in
            MeterBar(title: "BATTERY", systemImage: "battery.75percent",
                     valueText: "\(Int(level * 100)) %", fraction: level,
                     gradient: .battery(color), span: .fill, valueColor: color)
        }
    }
    .padding()
    .background(.black)
}
