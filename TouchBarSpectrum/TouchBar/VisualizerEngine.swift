import AppKit

/// The single 60 fps heartbeat for the whole visualizer.
///
/// One central driver — rather than each view owning a timer — guarantees the FFT
/// runs exactly once per frame regardless of how many views are on screen (the
/// always-on control-strip slot, the wide expanded bar, or both). Every tick it
/// advances the analysis, steps the scanner state machine, and pushes the snapshot
/// (bands + scanner eye position/direction) to all registered views.
///
/// A plain main-thread `Timer` in `.common` modes is used instead of CVDisplayLink
/// (deprecated on macOS 15) or an `NSView` CADisplayLink (the control strip's view
/// has no reliable screen association). Per-frame work is a 2048-pt FFT plus a
/// couple of tiny Core Graphics passes — trivial for the 2019 MBP's CPU.
final class VisualizerEngine {

    let analyzer: SpectrumAnalyzer
    let ring: RingBuffer

    private let frameRate: Double = 60
    private var timer: Timer?
    private let views = NSHashTable<TouchBarSpectrumView>.weakObjects()
    private let scanner = ScannerModel()

    init(analyzer: SpectrumAnalyzer, ring: RingBuffer) {
        self.analyzer = analyzer
        self.ring = ring
    }

    func register(_ view: TouchBarSpectrumView) { views.add(view) }
    func unregister(_ view: TouchBarSpectrumView) { views.remove(view) }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / frameRate, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        analyzer.update(from: ring)
        scanner.advance(dt: CGFloat(1.0 / frameRate))

        let bands = analyzer.bands
        let peaks = analyzer.peaks
        let pos = scanner.position
        let dir = scanner.direction
        for view in views.allObjects {
            view.apply(bands: bands, peaks: peaks, eyePos: pos, eyeDir: dir)
        }
    }
}

/// Stateful KITT scanner so the motion isn't mechanical: the eye sweeps a RANDOM
/// number of passes (1–4 one-way crossings, i.e. "one round trip or a few"), then
/// pauses for a RANDOM duration at the end, and each crossing takes a slightly
/// randomized time. Driven frame-by-frame from the engine.
final class ScannerModel {

    /// Eye position, 0 (left) … 1 (right).
    private(set) var position: CGFloat = 0
    /// +1 / −1 while moving, 0 while paused (so the trail vanishes during a pause).
    private(set) var direction: CGFloat = 0

    // Tunables.
    var minCrossings = 1
    var maxCrossings = 6
    var minPause: CGFloat = 0.3
    var maxPause: CGFloat = 2.6
    var minCrossDuration: CGFloat = 0.4      // sometimes a quick dart…
    var maxCrossDuration: CGFloat = 1.3      // …sometimes a slow glide

    private var moving = false
    private var dirSign: CGFloat = 1          // travel direction of the current crossing
    private var t: CGFloat = 0                // 0…1 progress of the current crossing
    private var crossDuration: CGFloat = 0.7
    private var crossingsLeft = 0
    private var pauseLeft: CGFloat = 0

    init() {
        crossingsLeft = Int.random(in: minCrossings...maxCrossings)
        startCrossing()
    }

    func advance(dt: CGFloat) {
        if moving {
            t += dt / crossDuration
            if t >= 1 {
                // Reached an end — finished one crossing.
                position = dirSign > 0 ? 1 : 0
                dirSign = -dirSign
                crossingsLeft -= 1
                if crossingsLeft <= 0 {
                    crossingsLeft = Int.random(in: minCrossings...maxCrossings)
                    startPause()
                } else {
                    startCrossing()
                }
            } else {
                let e = t * t * (3 - 2 * t)            // smoothstep ease
                position = dirSign > 0 ? e : 1 - e
            }
        } else {
            pauseLeft -= dt
            direction = 0
            if pauseLeft <= 0 { startCrossing() }
        }
    }

    private func startCrossing() {
        t = 0
        crossDuration = CGFloat.random(in: minCrossDuration...maxCrossDuration)
        moving = true
        direction = dirSign
    }

    private func startPause() {
        moving = false
        direction = 0
        pauseLeft = CGFloat.random(in: minPause...maxPause)
    }
}
