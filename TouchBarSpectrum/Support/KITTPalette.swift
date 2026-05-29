import CoreGraphics

/// Look-and-feel tuning for the KITT scanner.
///
/// The metaphor is the Knight Rider front-bumper scanner: a tight bright "eye" of
/// red light sweeping left↔right along a row of dim ember segments, leaving a
/// directional fading trail behind it. Brightness is driven by the sweep (so it
/// looks alive even in silence); audio only modulates each lit segment's vertical
/// thickness and adds a little hot-core punch on transients. Keeping those two
/// concerns separate is what stops it looking like a constantly-maxed EQ.
struct KITTPalette {

    let background: CGColor
    // Four-stop brightness ramp: ember → crimson → signalRed → hotCore.
    let ember: CGColor      // b≈0   trail tail / idle, near-black red
    let crimson: CGColor    // b≈0.22 mid
    let signalRed: CGColor  // b≈0.60 the eye body (#e40116)
    let hotCore: CGColor    // b≈1.0  peak, warm orange-white
    let bloom: CGColor      // additive glow around the eye

    // Geometry / motion.
    let minBarFraction: CGFloat   // idle half-height fraction
    let cornerRadius: CGFloat
    let sweepSpeed: CGFloat       // cycles per second (used by VisualizerEngine)
    let segmentsWide: Int         // segment count at full width (scaled down for the slot)
    let barWidthFrac: CGFloat     // segment width / cell (the rest is the LED gap)
    let eyeSigmaFrac: CGFloat     // ×N → eye-core Gaussian sigma
    let trailLambdaFrac: CGFloat  // ×N → trail exponential decay length
    let trailWeight: CGFloat
    let audioGamma: Float         // >1 compresses low levels so bars rest low
    let audioRelease: Float       // per-frame envelope release (slow fall)

    static let kitt = KITTPalette(
        background:      CGColor(srgbRed: 0,     green: 0,     blue: 0,     alpha: 1),
        ember:           CGColor(srgbRed: 0.28,  green: 0.01,  blue: 0.01,  alpha: 1),
        crimson:         CGColor(srgbRed: 0.62,  green: 0.02,  blue: 0.02,  alpha: 1),
        signalRed:       CGColor(srgbRed: 0.894, green: 0.004, blue: 0.086, alpha: 1),
        hotCore:         CGColor(srgbRed: 1.0,   green: 0.62,  blue: 0.46,  alpha: 1),
        bloom:           CGColor(srgbRed: 1.0,   green: 0.165, blue: 0.078, alpha: 1),
        minBarFraction:  0.10,
        cornerRadius:    2.0,
        sweepSpeed:      0.4,        // ~2.5 s round trip; end-dwell adds clear pauses
        segmentsWide:    48,
        barWidthFrac:    0.80,       // gap = 0.20 → narrower spacing between segments
        eyeSigmaFrac:    0.045,      // ×48 ≈ 2.2 segments — a tight 3–4 segment core
        trailLambdaFrac: 0.12,       // ×48 ≈ 5.8 segments of soft tail
        trailWeight:     0.75,
        audioGamma:      1.0,
        audioRelease:    0.76
    )

    /// Four-stop brightness ramp: ember → crimson → signalRed → hotCore.
    func ramp(_ b: CGFloat) -> CGColor {
        let bb = min(max(b, 0), 1)
        func lerp(_ a: CGColor, _ c: CGColor, _ t: CGFloat) -> CGColor {
            let p = a.components ?? [0, 0, 0, 1]
            let q = c.components ?? [0, 0, 0, 1]
            return CGColor(srgbRed: p[0] + (q[0] - p[0]) * t,
                           green:   p[1] + (q[1] - p[1]) * t,
                           blue:    p[2] + (q[2] - p[2]) * t,
                           alpha:   1)
        }
        if bb < 0.22 { return lerp(ember, crimson, bb / 0.22) }
        if bb < 0.60 { return lerp(crimson, signalRed, (bb - 0.22) / 0.38) }
        return lerp(signalRed, hotCore, (bb - 0.60) / 0.40)
    }
}
