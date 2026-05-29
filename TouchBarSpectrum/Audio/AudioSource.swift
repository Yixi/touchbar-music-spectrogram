import Foundation

/// Abstracts "a source of mono Float32 system audio" so the analyzer / Touch Bar
/// layers don't care whether samples arrive from a Core Audio process tap (the
/// primary path) or from a BlackHole virtual device (the fallback).
///
/// `onSamples` is invoked on a real-time/high-priority thread: implementations
/// must hand it a pointer that is valid only for the duration of the call, and the
/// consumer (a `RingBuffer`) must copy without locking or allocating.
protocol AudioSource: AnyObject {

    /// Mono Float32 callback: (pointer to `count` samples, count). Real-time thread.
    var onSamples: ((UnsafePointer<Float>, Int) -> Void)? { get set }

    /// Called (on the main queue) if the source detects it has stalled and cannot
    /// recover — e.g. the known process-tap all-zero bug. Lets the app fall back.
    var onStalled: (() -> Void)? { get set }

    var sampleRate: Double { get }
    var isRunning: Bool { get }
    var displayName: String { get }

    func start() throws
    func stop()
}
