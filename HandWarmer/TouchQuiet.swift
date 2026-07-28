import Foundation

/// How still the touchscreen is, as of the last thing that happened on it.
///
/// A phone held to warm cold hands is covered in skin: a palm across the glass,
/// fingers curled round the edges. What separates a deliberate stop from an
/// accident is not *where* the screen was touched — the button is a big target
/// and a palm finds it easily — but whether the screen was otherwise still. A
/// deliberate tap is preceded by a moment of nothing; an accidental one arrives
/// in the middle of a handful of contacts.
struct TouchQuiet: Equatable {
    /// The screen has to be completely untouched for this long before a tap on
    /// the stop button counts.
    static let required: TimeInterval = 2

    /// How long the button takes to collapse once the screen is touched.
    /// Losing the quiet window is instantaneous; *showing* it happen is not,
    /// because a button that vanishes between two frames reads as a glitch
    /// rather than as a response to the hand that caused it.
    static let collapse: TimeInterval = 0.45

    /// Fingers (or palm) currently down anywhere on the screen.
    var activeTouches: Int = 0
    /// When something last happened: a touch beginning, moving, or lifting.
    /// Starts in the distant past so the app is armed as soon as it opens.
    var lastActivity: Date = .distantPast
    /// When the current run of contact started — the first finger down, not the
    /// most recent, so a second finger landing doesn't restart the collapse.
    var contactStartedAt: Date?
    /// How full the button was at that moment; the collapse falls from here.
    var progressAtContact: Double = 0

    /// How long the screen has been still. Zero while anything is touching it,
    /// however long ago that touch started.
    func stillness(at now: Date) -> TimeInterval {
        guard activeTouches == 0 else { return 0 }
        return max(0, now.timeIntervalSince(lastActivity))
    }

    /// 0 to 1: how big the stop button is drawn — whichever of the two
    /// movements is currently ahead.
    ///
    /// They overlap after a quick tap, which lifts long before the collapse has
    /// finished. Taking the larger lets that collapse play out instead of being
    /// cut off by a regrowth that has only just restarted from zero, which is
    /// what made a tap snap where a long press glided.
    ///
    /// Only the collapse can be ahead, and only while it is on its way down, so
    /// this can never draw a full-size button that a tap would be refused by.
    func progress(at now: Date) -> Double {
        max(collapsing(at: now), regrowing(at: now))
    }

    /// The quiet window filling back up. Zero while anything is touching.
    private func regrowing(at now: Date) -> Double {
        min(stillness(at: now) / Self.required, 1)
    }

    /// The fall from wherever the button was when the screen was touched, over
    /// `collapse` seconds, whether or not the touch is still down.
    private func collapsing(at now: Date) -> Double {
        guard let contactStartedAt else { return 0 }
        let elapsed = now.timeIntervalSince(contactStartedAt)
        guard elapsed < Self.collapse else { return 0 }
        // Cosine ease: leaves full size gently, arrives at nothing gently.
        let eased = 0.5 * (1 + cos(.pi * max(0, elapsed) / Self.collapse))
        return progressAtContact * eased
    }

    /// Whether a tap arriving now would be believed.
    func isArmed(at now: Date) -> Bool {
        stillness(at: now) >= Self.required
    }
}
