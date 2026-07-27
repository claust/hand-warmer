import SwiftUI

/// A short side-to-side shake, played whenever `trigger` changes. The stop
/// button uses it to refuse a tap: the movement says the tap was received and
/// turned down, which a button that simply does nothing cannot.
struct Wobble: ViewModifier, Animatable {
    var trigger: Int

    /// Animating the trigger itself means one shake per increment, with no
    /// separate "am I shaking" state to keep in step.
    var animatableData: Double = 0

    init(trigger: Int) {
        self.trigger = trigger
        self.animatableData = Double(trigger)
    }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .animation(.easeInOut(duration: 0.45), value: trigger)
    }

    /// Three diminishing swings across the width of one increment.
    private var offset: CGFloat {
        let phase = animatableData - animatableData.rounded(.down)
        guard phase > 0 else { return 0 }
        return sin(phase * .pi * 6) * 14 * (1 - phase)
    }
}
