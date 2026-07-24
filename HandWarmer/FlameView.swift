import SwiftUI

/// A procedurally animated flame. Three layered teardrop shapes whose edges
/// wobble over time, drawn in a Canvas each frame. `intensity` (0...1) scales
/// the whole flame so it can grow in softly when the warmer starts.
struct FlameView: View {
    var intensity: CGFloat

    var body: some View {
        // TimelineView(.animation) redraws every frame for as long as it is in
        // the hierarchy, so while the warmer is off keep it out entirely rather
        // than spending a frame's work drawing nothing.
        Group {
            if intensity > 0.01 {
                flame
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
    }

    private var flame: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let base = CGPoint(x: size.width / 2, y: size.height * 0.96)
                let height = size.height * 0.88 * intensity
                let width = size.width * 0.62 * intensity

                drawFlame(ctx: &ctx, base: base, w: width, h: height, t: t, phase: 0,
                          colors: [Color(red: 0.95, green: 0.25, blue: 0.05).opacity(0.85),
                                   Color(red: 1.0, green: 0.45, blue: 0.0).opacity(0.9)])
                drawFlame(ctx: &ctx, base: base, w: width * 0.66, h: height * 0.72, t: t, phase: 1.7,
                          colors: [Color(red: 1.0, green: 0.55, blue: 0.05),
                                   Color(red: 1.0, green: 0.75, blue: 0.1)])
                drawFlame(ctx: &ctx, base: base, w: width * 0.36, h: height * 0.45, t: t, phase: 3.1,
                          colors: [Color(red: 1.0, green: 0.85, blue: 0.3),
                                   Color(red: 1.0, green: 0.98, blue: 0.75)])
            }
            .blur(radius: 1.5)
            .shadow(color: .orange.opacity(0.6 * intensity), radius: 30 * intensity)
        }
    }

    private func drawFlame(ctx: inout GraphicsContext, base: CGPoint,
                           w: CGFloat, h: CGFloat, t: TimeInterval, phase: Double,
                           colors: [Color]) {
        // Flicker: several out-of-phase sines so it never visibly repeats.
        let flick = sin(t * 9 + phase) * 0.06 + sin(t * 5.3 + phase * 2) * 0.05
        let sway = CGFloat(sin(t * 3.1 + phase) * 0.10 + sin(t * 7.7 + phase) * 0.04)
        let hh = h * (1 + CGFloat(flick))
        let tip = CGPoint(x: base.x + w * sway * 0.5, y: base.y - hh)

        var path = Path()
        path.move(to: CGPoint(x: base.x - w / 2, y: base.y))
        // Left side up to the tip.
        path.addCurve(to: tip,
                      control1: CGPoint(x: base.x - w * 0.62, y: base.y - hh * 0.45),
                      control2: CGPoint(x: base.x - w * 0.10 + w * sway, y: base.y - hh * 0.8))
        // Right side back down.
        path.addCurve(to: CGPoint(x: base.x + w / 2, y: base.y),
                      control1: CGPoint(x: base.x + w * 0.10 + w * sway, y: base.y - hh * 0.8),
                      control2: CGPoint(x: base.x + w * 0.62, y: base.y - hh * 0.45))
        // Rounded bottom.
        path.addQuadCurve(to: CGPoint(x: base.x - w / 2, y: base.y),
                          control: CGPoint(x: base.x, y: base.y + w * 0.30))
        path.closeSubpath()

        let gradient = Gradient(colors: colors)
        ctx.fill(path, with: .linearGradient(
            gradient,
            startPoint: CGPoint(x: base.x, y: base.y),
            endPoint: CGPoint(x: base.x, y: base.y - hh)))
    }
}

#Preview {
    ZStack {
        Color.black
        FlameView(intensity: 1)
            .frame(width: 200, height: 260)
    }
    .ignoresSafeArea()
}
