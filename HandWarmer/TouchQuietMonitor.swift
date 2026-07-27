import SwiftUI
import UIKit

/// Watches every touch on the app's window and keeps a `TouchQuiet` up to date.
///
/// It has to be the whole window rather than the button: the interesting touches
/// are the ones that land *away* from the button — a palm resting on the meters,
/// a finger curled over the flame — because those are the evidence that the
/// phone is being held, not operated.
@MainActor
final class TouchQuietMonitor: ObservableObject {
    @Published private(set) var quiet = TouchQuiet()

    /// Whether the screen was already still when the most recent touch began.
    ///
    /// This, rather than `quiet.isArmed(at:)`, is what a button action must
    /// check. By the time a tap fires, the tapping finger is itself a touch, so
    /// the live reading always says "not still" — the question is what the
    /// screen looked like the instant before the finger landed.
    private(set) var wasArmedAtLatestTouchDown = true

    private weak var watchedWindow: UIWindow?

    func attach(to window: UIWindow) {
        guard watchedWindow !== window else { return }
        watchedWindow?.gestureRecognizers?
            .filter { $0 is TouchObserver }
            .forEach { watchedWindow?.removeGestureRecognizer($0) }
        window.addGestureRecognizer(TouchObserver(monitor: self))
        watchedWindow = window
    }

    // The three below are the whole input to this thing: the window's touch
    // stream, as seen by the recognizer at the bottom of this file.

    func touchesBegan(count: Int, at now: Date) {
        // Decided before the new touches are counted in: this is a statement
        // about the screen the tap arrived on.
        wasArmedAtLatestTouchDown = quiet.isArmed(at: now)
        if quiet.activeTouches == 0 {
            quiet.contactStartedAt = now
            quiet.progressAtContact = quiet.progress(at: now)
        }
        quiet.activeTouches += count
        quiet.lastActivity = now
    }

    func touchesMoved(at now: Date) {
        quiet.lastActivity = now
    }

    func touchesEnded(count: Int, at now: Date) {
        // max() because UIKit can hand back a touch the recognizer never saw
        // begin, e.g. one that started before the recognizer was attached.
        quiet.activeTouches = max(0, quiet.activeTouches - count)
        // `contactStartedAt` deliberately survives the lift: a tap shorter than
        // the collapse still gets to finish collapsing.
        quiet.lastActivity = now
    }
}

/// A gesture recognizer that never recognizes anything. It sits on the window
/// purely to be told about touches, and — with `cancelsTouchesInView` and the
/// delay flags off — passes every one of them through untouched, so the buttons
/// underneath behave exactly as they did before.
private final class TouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let monitor: TouchQuietMonitor

    init(monitor: TouchQuietMonitor) {
        self.monitor = monitor
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    // Staying in `.possible` for the whole sequence is what keeps the touches
    // coming; failing or recognizing would cut delivery short.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        monitor.touchesBegan(count: touches.count, at: .now)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        monitor.touchesMoved(at: .now)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        monitor.touchesEnded(count: touches.count, at: .now)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        monitor.touchesEnded(count: touches.count, at: .now)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

/// Drop this anywhere in the hierarchy to hook the monitor up to the window.
/// It draws nothing and takes no touches of its own.
struct TouchQuietReporter: UIViewRepresentable {
    let monitor: TouchQuietMonitor

    func makeUIView(context: Context) -> UIView {
        let view = WindowFinder()
        view.monitor = monitor
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class WindowFinder: UIView {
        var monitor: TouchQuietMonitor?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let monitor else { return }
            MainActor.assumeIsolated { monitor.attach(to: window) }
        }
    }
}
