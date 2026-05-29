import AppKit

/// The KITT scanner renderer. Deliberately "dumb": it owns no timer and pulls no
/// data — a `VisualizerEngine` pushes the latest band snapshot and a shared sweep
/// phase each frame, then triggers a redraw. The same class renders both the small
/// control-strip slot and the wide expanded bar; layout derives from `bounds`.
///
/// Visual model (Knight Rider scanner, not a graphic EQ):
///   * A bright "eye" sweeps left↔right along a row of dim ember segments, with a
///     directional exponential trail behind it. This is the dominant element and
///     keeps the bar alive even in silence.
///   * Audio only modulates each lit segment's vertical thickness (with a γ curve
///     so quiet sits low and transients spike) plus a touch of hot-core brightness.
///   * A single additive radial bloom sits on the eye.
///
/// The view never intercepts clicks (`hitTest` returns nil) — its hosting NSButton
/// owns the tap, because the out-of-process control-strip agent only delivers taps
/// through NSControl target/action, not to a bare NSView.
final class TouchBarSpectrumView: NSView {

    var palette: KITTPalette = .kitt

    private var bands: [Float] = []
    private var eyePos: CGFloat = 0           // scanner eye position 0…1 (from engine)
    private var eyeDir: CGFloat = 0           // +1 / −1 moving, 0 paused
    private var audioEnv: [Float] = []        // per-segment attack/release envelope

    private let preferredSize: NSSize

    init(preferredSize: NSSize) {
        self.preferredSize = preferredSize
        super.init(frame: NSRect(origin: .zero, size: preferredSize))
        wantsLayer = true
        layer?.backgroundColor = palette.background
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var intrinsicContentSize: NSSize { preferredSize }
    override var isOpaque: Bool { true }
    override var isFlipped: Bool { false }

    /// Let clicks fall through to the hosting NSButton.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Called by the engine on the main thread once per frame. `peaks` is accepted
    /// for engine-contract compatibility but unused by the scanner render.
    func apply(bands: [Float], peaks: [Float], eyePos: CGFloat, eyeDir: CGFloat) {
        self.bands = bands
        self.eyePos = eyePos
        self.eyeDir = eyeDir
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        ctx.setFillColor(palette.background)
        ctx.fill(bounds)
        guard w > 1, h > 1 else { return }

        let nBands = bands.count
        // Segment count: ~48 at full width, scaling down to ~8 in the slot.
        let n = max(8, min(palette.segmentsWide, Int(w / 13.0)))
        let cellW = w / CGFloat(n)
        let barW = max(1, cellW * palette.barWidthFrac)
        let radius = min(palette.cornerRadius, barW / 2)
        let midY = h / 2

        // Max-pool the analyzer bands into `n` segments, then γ-compress and run a
        // fast-attack / slow-release envelope so quiet rests low and beats spike.
        if audioEnv.count != n { audioEnv = [Float](repeating: 0, count: n) }
        let floorE: Float = 0.03
        // Symmetric layout: bass sits at the CENTER, higher bands expand outward to
        // both edges, mirrored left/right — the KITT "voice box" look. Each segment's
        // frequency band is chosen by its distance from the center.
        let center = CGFloat(n - 1) / 2
        let perSide = max(1, Int(center) + 1)
        for i in 0..<n {
            let dist = min(perSide - 1, Int(abs(CGFloat(i) - center)))
            var raw: Float = 0
            if nBands > 0 {
                let lo = dist * nBands / perSide
                let hi = max(lo + 1, (dist + 1) * nBands / perSide)
                for k in lo..<min(hi, nBands) { raw = max(raw, bands[k]) }
            }
            let comp = powf(max(0, raw - floorE), palette.audioGamma)
            audioEnv[i] = comp >= audioEnv[i] ? comp : audioEnv[i] * palette.audioRelease
        }

        // Scanner eye position/direction come from the engine's ScannerModel
        // (random passes + random pauses), so the motion isn't mechanical.
        let eye = CGFloat(n - 1) * eyePos
        let dir = eyeDir
        let sigma = max(0.5, CGFloat(n) * palette.eyeSigmaFrac)
        let lambda = max(0.5, CGFloat(n) * palette.trailLambdaFrac)

        // Main pass — one horizontal pill per segment.
        ctx.setBlendMode(.normal)
        for i in 0..<n {
            let d = CGFloat(i) - eye
            let core = exp(-(d * d) / (2 * sigma * sigma))
            // Trail only behind the moving eye; none during the end dwell.
            let behind = (d < 0 && dir > 0) || (d > 0 && dir < 0)
            let trail = (behind && dir != 0) ? palette.trailWeight * exp(-abs(d) / lambda) : 0
            let sweepB = max(core, trail)

            let a = CGFloat(audioEnv[i])
            // The SPECTRUM (audio) is the primary visual: a loud band lights up red
            // and grows on its own, independent of the eye. The scanning eye is an
            // ACCENT that mostly intensifies bars already carrying signal (energizing
            // the music as it passes) plus a faint moving glow so the KITT eye stays
            // visible when quiet — it must not wash a bright blob over silence.
            let sweepHi = sweepB * (0.22 + 0.50 * a)
            let brightness = min(1.2, 0.08 + 0.98 * a + sweepHi)
            // Height is almost entirely the spectrum; the eye adds only a small lift.
            let halfH = min(0.47 * h, (palette.minBarFraction + 0.66 * a + 0.10 * sweepB) * h)

            let x = CGFloat(i) * cellW + (cellW - barW) / 2
            let rect = CGRect(x: x, y: midY - halfH, width: barW, height: 2 * halfH)
            ctx.setFillColor(palette.ramp(brightness))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }

        // Single additive bloom centered on the eye.
        let eyeX = (eye + 0.5) * cellW
        let bloomW = 8 * cellW
        let bloomH = 3 * palette.minBarFraction * h
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let grad = CGGradient(colorsSpace: space,
                                 colors: [palette.bloom.copy(alpha: 0.5) ?? palette.bloom,
                                          palette.bloom.copy(alpha: 0.0) ?? palette.bloom] as CFArray,
                                 locations: [0, 1]) {
            ctx.saveGState()
            ctx.setBlendMode(.plusLighter)
            ctx.addRect(CGRect(x: eyeX - bloomW / 2, y: midY - bloomH / 2, width: bloomW, height: bloomH))
            ctx.clip()
            ctx.drawRadialGradient(grad,
                                   startCenter: CGPoint(x: eyeX, y: midY), startRadius: 0,
                                   endCenter: CGPoint(x: eyeX, y: midY), endRadius: bloomW / 2,
                                   options: [])
            ctx.restoreGState()
        }
        ctx.setBlendMode(.normal)
    }
}
