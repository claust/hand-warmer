import SwiftUI

/// A single teardrop flame, sized to fill the rect it is given, standing on its
/// bottom edge.
///
/// `FlameView` draws its flame into a `Canvas` because it can afford to redraw
/// every frame. The Dynamic Island cannot — the system only re-renders it when
/// a new activity state arrives — so the island version is built from plain
/// shapes instead, which SwiftUI can *interpolate* between two states. That is
/// the whole reason this is a `Shape` and not more Canvas code.
struct FlameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let base = CGPoint(x: rect.midX, y: rect.maxY)
        let w = rect.width
        let h = rect.height
        let tip = CGPoint(x: base.x, y: base.y - h)

        var path = Path()
        path.move(to: CGPoint(x: base.x - w / 2, y: base.y))
        // Left side up to the tip.
        path.addCurve(
            to: tip,
            control1: CGPoint(x: base.x - w * 0.62, y: base.y - h * 0.45),
            control2: CGPoint(x: base.x - w * 0.10, y: base.y - h * 0.80))
        // Right side back down.
        path.addCurve(
            to: CGPoint(x: base.x + w / 2, y: base.y),
            control1: CGPoint(x: base.x + w * 0.10, y: base.y - h * 0.80),
            control2: CGPoint(x: base.x + w * 0.62, y: base.y - h * 0.45))
        // Rounded bottom.
        path.addQuadCurve(
            to: CGPoint(x: base.x - w / 2, y: base.y),
            control: CGPoint(x: base.x, y: base.y + w * 0.30))
        path.closeSubpath()
        return path
    }
}

/// Three layered `FlameShape`s whose scale and lean are derived from
/// `phase`, so each pushed state draws a different flicker. The implicit
/// animation is what turns a handful of updates per second into continuous
/// motion: SwiftUI tweens the scale/rotation between the old phase and the new
/// one, so the flame keeps moving even between updates.
struct LiveFlame: View {
    /// `ContentState.flamePhase`.
    var phase: Int
    /// 0...1. Scales how violently the flame flickers — a barely-warm phone
    /// gets a lazy flame, a hot one gets an angry one.
    var intensity: Double = 1

    var body: some View {
        // Out-of-phase sines with irrational-ish ratios, so the loop is long
        // enough that the eye never catches it repeating.
        let p = Double(phase)
        let a = sin(p * 0.83)
        let b = sin(p * 1.31 + 1.1)
        let c = sin(p * 2.07 + 2.4)
        let amp = 0.55 + 0.45 * min(max(intensity, 0), 1)

        ZStack {
            layer(
                colors: [
                    Color(red: 0.95, green: 0.25, blue: 0.05),
                    Color(red: 1.0, green: 0.45, blue: 0.0),
                ],
                width: 0.86, height: 1.0,
                wobbleX: b, wobbleY: a, lean: a, amp: amp)

            layer(
                colors: [
                    Color(red: 1.0, green: 0.55, blue: 0.05),
                    Color(red: 1.0, green: 0.78, blue: 0.12),
                ],
                // Leans against the outer layer rather than with it, which is
                // what makes the flame look like it is folding over itself.
                // Kept narrow so the swing stays inside the outer silhouette.
                width: 0.44, height: 0.70,
                wobbleX: c, wobbleY: b, lean: -b * 1.1, amp: amp)

            layer(
                colors: [
                    Color(red: 1.0, green: 0.85, blue: 0.35),
                    Color(red: 1.0, green: 0.98, blue: 0.80),
                ],
                width: 0.26, height: 0.44,
                wobbleX: a, wobbleY: c, lean: c * 2.2, amp: amp)
        }
        // Matched to the controller's background tick, so the flame is still
        // travelling toward one phase as the next arrives and never visibly
        // parks between updates. Linear rather than eased for the same reason —
        // an ease would stall at both ends of every single frame.
        .animation(.linear(duration: 0.5), value: phase)
        .compositingGroup()
    }

    private func layer(
        colors: [Color], width: Double, height: Double,
        wobbleX: Double, wobbleY: Double, lean: Double,
        amp: Double
    ) -> some View {
        FlameShape()
            .fill(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
            .scaleEffect(
                x: width * (1 + 0.20 * wobbleX * amp),
                y: height * (1 + 0.30 * wobbleY * amp),
                anchor: .bottom
            )
            // Rotating about the base is what throws the tip side to side; at
            // island size a few degrees is invisible, so lean hard.
            .rotationEffect(.degrees(9 * lean * amp), anchor: .bottom)
    }
}

#Preview {
    ZStack {
        Color.black
        HStack(spacing: 24) {
            ForEach(0..<4) { i in
                LiveFlame(phase: i * 3)
                    .frame(width: 40, height: 54)
            }
        }
    }
    .ignoresSafeArea()
}
