import Accelerate
import Foundation

/// Turns a stream of mono PCM samples into a compact set of log-spaced, smoothed
/// spectrum bands suitable for the narrow KITT-style Touch Bar visualizer.
///
/// Pipeline, run once per display frame on the display thread:
///   ring → latest `fftSize` window → Hann window → real FFT (vDSP) →
///   power spectrum → log-frequency band averaging → dB normalize →
///   fast-attack / slow-release smoothing + slow peak-hold decay.
///
/// A 2048-point FFT costs only a few microseconds, so running it synchronously
/// at 60 fps on the main thread is cheaper than any cross-thread hand-off.
final class SpectrumAnalyzer {

    // MARK: Configuration

    let fftSize: Int
    let bandCount: Int
    var sampleRate: Double {
        didSet { if sampleRate != oldValue { rebuildBandTable() } }
    }

    /// Adaptive loudness normalization. The display floor sits `dynamicRangeDb`
    /// below an auto-tracked ceiling, so bars rest LOW and spike with the music
    /// instead of pinning to the top. The ceiling jumps up to new peaks and decays
    /// slowly; `headroomDb` is kept above the loudest band so peaks rarely saturate.
    var dynamicRangeDb: Float = 40       // tighter window → more contrast / punchier peaks
    var headroomDb: Float = 5            // peaks map closer to full scale
    var ceilingDecay: Float = 0.992      // per frame; ~2 s time constant at 60 fps
    var minCeilingDb: Float = -58        // floor on the ceiling so silence stays dark
    /// Per-band high-frequency lift (dB) so treble isn't visually crushed by bass.
    var trebleTiltDb: Float = 0.18
    /// Exponential smoothing: rising edges snap up, falling edges ease down.
    var attack: Float = 0.55
    var release: Float = 0.20            // a touch faster fall → more "dancing"
    /// Peak cap descent per frame (fraction of full scale). Lower = slower fall.
    var peakFall: Float = 0.011

    // MARK: Output (read on the display thread)

    private(set) var bands: [Float]
    private(set) var peaks: [Float]

    // MARK: FFT state

    private let halfN: Int
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let hann: [Float]

    private var windowed: [Float]
    private var sampleWindow: [Float]
    private let realIn: UnsafeMutableBufferPointer<Float>
    private let imagIn: UnsafeMutableBufferPointer<Float>
    private let realOut: UnsafeMutableBufferPointer<Float>
    private let imagOut: UnsafeMutableBufferPointer<Float>
    private var power: [Float]

    private var bandRanges: [(lo: Int, hi: Int)] = []

    private var rawDb: [Float]
    private var ceilingDb: Float = -45
    private let debug = ProcessInfo.processInfo.environment["TBS_DEBUG"] != nil
    private var frameCounter = 0

    // MARK: Init

    init(fftSize: Int = 2048, bandCount: Int = 64, sampleRate: Double = 48_000) {
        precondition(fftSize.nonzeroBitCount == 1, "fftSize must be a power of two")
        self.fftSize = fftSize
        self.bandCount = bandCount
        self.sampleRate = sampleRate
        self.halfN = fftSize / 2

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("Unable to create vDSP FFT setup for size \(fftSize)")
        }
        self.fft = fft

        self.hann = vDSP.window(ofType: Float.self,
                                usingSequence: .hanningDenormalized,
                                count: fftSize,
                                isHalfWindow: false)

        self.windowed = [Float](repeating: 0, count: fftSize)
        self.sampleWindow = [Float](repeating: 0, count: fftSize)
        self.realIn = .allocate(capacity: halfN)
        self.imagIn = .allocate(capacity: halfN)
        self.realOut = .allocate(capacity: halfN)
        self.imagOut = .allocate(capacity: halfN)
        self.realIn.initialize(repeating: 0)
        self.imagIn.initialize(repeating: 0)
        self.realOut.initialize(repeating: 0)
        self.imagOut.initialize(repeating: 0)
        self.power = [Float](repeating: 0, count: halfN)

        self.bands = [Float](repeating: 0, count: bandCount)
        self.peaks = [Float](repeating: 0, count: bandCount)
        self.rawDb = [Float](repeating: -120, count: bandCount)

        rebuildBandTable()
    }

    deinit {
        realIn.deallocate(); imagIn.deallocate()
        realOut.deallocate(); imagOut.deallocate()
    }

    // MARK: Band table

    /// Pre-compute, for each output band, the contiguous FFT bin range it averages.
    private func rebuildBandTable() {
        let minFreq: Float = 38
        let maxFreq = Float(min(sampleRate * 0.5 * 0.94, 18_000))
        let ratio = maxFreq / minFreq

        func bin(for freq: Float) -> Int {
            let b = Int((freq / Float(sampleRate)) * Float(fftSize) + 0.5)
            return min(max(b, 1), halfN - 1)
        }

        var ranges: [(lo: Int, hi: Int)] = []
        ranges.reserveCapacity(bandCount)
        for b in 0..<bandCount {
            let f0 = minFreq * pow(ratio, Float(b) / Float(bandCount))
            let f1 = minFreq * pow(ratio, Float(b + 1) / Float(bandCount))
            var lo = bin(for: f0)
            var hi = bin(for: f1)
            if hi <= lo { hi = lo + 1 }                 // guarantee >= 1 bin
            lo = min(lo, halfN - 1)
            hi = min(hi, halfN)
            ranges.append((lo, hi))
        }
        bandRanges = ranges
    }

    // MARK: Per-frame update

    /// Pull the newest window from `ring`, analyze it, and advance the smoothed
    /// band / peak state. If the ring hasn't filled yet, only the decay runs so
    /// the visualizer still settles toward zero.
    func update(from ring: RingBuffer) {
        if ring.latestWindow(into: &sampleWindow) {
            analyze(sampleWindow)
        } else {
            decayOnly()
        }
    }

    private func analyze(_ samples: [Float]) {
        // 1. Apply the Hann window.
        vDSP.multiply(samples, hann, result: &windowed)

        // 2. Pack the real signal into split-complex form and run the real FFT.
        var input = DSPSplitComplex(realp: realIn.baseAddress!, imagp: imagIn.baseAddress!)
        var output = DSPSplitComplex(realp: realOut.baseAddress!, imagp: imagOut.baseAddress!)
        windowed.withUnsafeBytes { raw in
            let interleaved = raw.bindMemory(to: DSPComplex.self)
            vDSP_ctoz(interleaved.baseAddress!, 2, &input, 1, vDSP_Length(halfN))
        }
        fft.forward(input: input, output: &output)

        // 3. Power spectrum (|z|^2). Bin 0 holds DC/Nyquist and is ignored below.
        vDSP_zvmags(&output, 1, &power, 1, vDSP_Length(halfN))

        // 4. Average power per log-spaced band → dB; track the frame's loudest band.
        let scale = 2 / Float(fftSize) / Float(fftSize)     // FFT + window normalization
        var frameMaxDb: Float = -300
        for b in 0..<bandCount {
            let (lo, hi) = bandRanges[b]
            var acc: Float = 0
            for bin in lo..<hi { acc += power[bin] }
            let meanPower = acc / Float(hi - lo) * scale
            let db = 10 * log10f(meanPower + 1e-12) + trebleTiltDb * Float(b)
            rawDb[b] = db
            if db > frameMaxDb { frameMaxDb = db }
        }

        // 5. Adaptive ceiling: jump up to peaks, decay slowly; clamped so silence
        //    stays dark rather than amplifying the noise floor.
        let target = max(frameMaxDb + headroomDb, minCeilingDb)
        ceilingDb = target > ceilingDb ? target
                                       : ceilingDb * ceilingDecay + target * (1 - ceilingDecay)
        let floorDb = ceilingDb - dynamicRangeDb
        let span = max(1, ceilingDb - floorDb)

        // 6. Normalize into 0...1, then fast-attack / slow-release smooth + peak hold.
        for b in 0..<bandCount {
            let norm = min(max((rawDb[b] - floorDb) / span, 0), 1)
            let prev = bands[b]
            let coeff = norm > prev ? attack : release
            let value = prev + (norm - prev) * coeff
            bands[b] = value

            if value >= peaks[b] {
                peaks[b] = value
            } else {
                peaks[b] = max(value, peaks[b] - peakFall)
            }
        }

        if debug {
            frameCounter += 1
            if frameCounter % 60 == 0 {
                NSLog("[TBS_DEBUG] frameMaxDb=%.1f ceiling=%.1f floor=%.1f maxBand=%.2f",
                      frameMaxDb, ceilingDb, floorDb, bands.max() ?? 0)
            }
        }
    }

    private func decayOnly() {
        for b in 0..<bandCount {
            bands[b] *= (1 - release)
            peaks[b] = max(bands[b], peaks[b] - peakFall)
        }
    }
}
