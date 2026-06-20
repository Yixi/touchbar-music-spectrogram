import AppKit

/// Recognizes a horizontal drag made with **Touch Bar (direct) touches**, used to
/// scrub the system volume on the expanded bar.
///
/// It deliberately stays in `.possible` until the finger travels past a small
/// threshold; only then does it flip to `.began` / `.changed`. That transition is
/// what makes AppKit cancel the hosting `NSButton`'s pending click, so a *swipe*
/// never also fires the collapse-on-tap action — while a *pure tap* (no horizontal
/// travel) never crosses the threshold and lets the button collapse the bar as before.
///
/// `translationX` is the signed horizontal distance (in the view's points) from the
/// touch's start, which the controller maps to a volume delta.
final class HorizontalPanRecognizer: NSGestureRecognizer {

    /// Horizontal travel since the gesture's first touch, in view points (+right).
    private(set) var translationX: CGFloat = 0

    private var startX: CGFloat = 0
    private let threshold: CGFloat = 4   // points of travel before it counts as a drag

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // Touch Bar reports `.direct` touches; recognizers default to `.indirect`
        // (trackpad), so this must be opted in explicitly or no touches arrive.
        allowedTouchTypes = [.direct]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func touchX(_ event: NSEvent) -> CGFloat? {
        guard let view else { return nil }
        // `.touching` = began | moved | stationary. Direct touches carry a real
        // location in the view (unlike indirect touches, which only have a
        // normalized position).
        guard let touch = event.touches(matching: .touching, in: view).first else { return nil }
        return touch.location(in: view).x
    }

    override func touchesBegan(with event: NSEvent) {
        guard let x = touchX(event) else { return }
        startX = x
        translationX = 0
        // Stay `.possible`: a tap that ends here must fall through to the button.
    }

    override func touchesMoved(with event: NSEvent) {
        guard let x = touchX(event) else { return }
        translationX = x - startX
        if state == .possible {
            if abs(translationX) >= threshold { state = .began }   // claims the touch
        } else {
            state = .changed
        }
    }

    override func touchesEnded(with event: NSEvent) {
        state = (state == .possible) ? .failed : .ended
    }

    override func touchesCancelled(with event: NSEvent) {
        state = .cancelled
    }
}
