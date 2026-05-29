import Foundation
import Synchronization

/// A single-producer / single-consumer float ring buffer tuned for real-time audio.
///
/// The audio render thread is the sole producer; it appends mono samples without
/// ever taking a lock or allocating. The display thread is the sole consumer; it
/// copies the most recent `n` samples (a sliding analysis window) on each frame.
///
/// Correctness relies on:
///   * `written` being a monotonically increasing total-sample counter published
///     with release semantics by the producer and read with acquire semantics by
///     the consumer (so the sample stores are visible before the count update is).
///   * the backing storage being large relative to the analysis window, so the
///     producer cannot lap the consumer's window mid-copy. With a 48 kHz stream
///     the producer writes ~800 samples per 60 fps frame, while `capacity` is many
///     multiples of the FFT window, leaving a wide safety margin.
final class RingBuffer {

    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    /// Total number of samples ever written. `position = written % capacity`.
    private let written = Atomic<UInt64>(0)

    init(capacity: Int) {
        // Round up to a power of two so `% capacity` is a cheap mask if needed,
        // and to give the consumer plenty of head-room over the analysis window.
        let cap = max(1024, capacity).nextPowerOfTwo
        self.capacity = cap
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0)
    }

    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    /// Producer side. Called from the Core Audio render thread. Lock-free, no allocation.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let cap = capacity
        var w = Int(written.load(ordering: .relaxed) % UInt64(cap))
        let base = storage.baseAddress!
        for i in 0..<count {
            base[w] = samples[i]
            w += 1
            if w == cap { w = 0 }
        }
        // Publish: release pairs with the consumer's acquire load below.
        written.add(UInt64(count), ordering: .releasing)
    }

    /// Consumer side. Copies the most recent `out.count` samples into `out`.
    /// Returns false (leaving `out` untouched) until enough samples have arrived.
    func latestWindow(into out: inout [Float]) -> Bool {
        let n = out.count
        // Do the modular arithmetic in UInt64; only the small wrapped index is
        // narrowed to Int, so the monotonic total never traps on conversion.
        let total = written.load(ordering: .acquiring)
        guard total >= UInt64(n) else { return false }
        let cap = capacity
        let start = Int((total - UInt64(n)) % UInt64(cap))
        let base = storage.baseAddress!
        out.withUnsafeMutableBufferPointer { dst in
            let d = dst.baseAddress!
            if start + n <= cap {
                d.update(from: base + start, count: n)
            } else {
                let firstChunk = cap - start
                d.update(from: base + start, count: firstChunk)
                (d + firstChunk).update(from: base, count: n - firstChunk)
            }
        }
        return true
    }
}

private extension Int {
    /// Smallest power of two >= self (for self >= 1).
    var nextPowerOfTwo: Int {
        guard self > 1 else { return 1 }
        return 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
