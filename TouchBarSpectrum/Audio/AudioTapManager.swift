import CoreAudio
import AudioToolbox
import Foundation
import Synchronization

/// Captures the entire system output mix using Core Audio process taps
/// (macOS 14.2+). Pipeline:
///
///   CATapDescription(stereoGlobalTapButExcludeProcesses: [])  // whole-system mix
///     → AudioHardwareCreateProcessTap → read kAudioTapPropertyFormat
///     → AudioHardwareCreateAggregateDevice (main sub-device = default output,
///        tap list references the tap's UUID string)
///     → AudioDeviceCreateIOProcIDWithBlock → AudioDeviceStart
///
/// The IO block down-mixes to mono Float32 and forwards to `onSamples`. The tap is
/// created `.unmuted` so playback is never silenced.
///
/// A lightweight watchdog covers the known long-session "all-zero buffer" bug:
/// if no non-zero audio is seen for a grace period after start, it rebuilds the
/// tap once; if still silent, it reports `onStalled` so the app can fall back to
/// BlackHole. (Mid-session stalls are indistinguishable from genuine silence, so
/// those are handled by the user via "Restart Capture".)
final class AudioTapManager: AudioSource {

    enum TapError: Error, CustomStringConvertible {
        case unsupportedOS
        case noOutputDevice
        case createTapFailed(OSStatus)
        case readFormatFailed(OSStatus)
        case createAggregateFailed(OSStatus)
        case createIOProcFailed(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .unsupportedOS:            return "Process taps require macOS 14.2+."
            case .noOutputDevice:           return "No default system output device found."
            case .createTapFailed(let s):   return "AudioHardwareCreateProcessTap failed (\(s))."
            case .readFormatFailed(let s):  return "Reading tap format failed (\(s))."
            case .createAggregateFailed(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))."
            case .createIOProcFailed(let s):    return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))."
            case .startFailed(let s):       return "AudioDeviceStart failed (\(s))."
            }
        }
    }

    // MARK: AudioSource

    var onSamples: ((UnsafePointer<Float>, Int) -> Void)?
    var onStalled: (() -> Void)?
    private(set) var sampleRate: Double = 48_000
    var displayName: String { "System Audio (Core Audio Tap)" }
    var isRunning: Bool { aggregateID != 0 }

    // MARK: Core Audio handles

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID = UUID()

    private let ioQueue = DispatchQueue(label: "com.yixi.TouchBarSpectrum.audioIO", qos: .userInteractive)

    // MARK: Mono scratch (reused, never reallocated on the audio thread)

    private let maxFrames = 16_384
    private let mono: UnsafeMutableBufferPointer<Float>

    // MARK: Watchdog

    private let nonZeroCallbacks = Atomic<UInt64>(0)
    private var watchdog: DispatchSourceTimer?
    private var didAutoRebuild = false
    private var watchTick = 0

    init() {
        mono = .allocate(capacity: maxFrames)
        mono.initialize(repeating: 0)
    }

    deinit {
        stop()
        mono.deinitialize()
        mono.deallocate()
    }

    // MARK: Lifecycle

    func start() throws {
        guard #available(macOS 14.2, *) else { throw TapError.unsupportedOS }
        guard !isRunning else { return }
        try buildPipeline()
        startWatchdog()
    }

    func stop() {
        stopWatchdog()
        teardownPipeline()
        onStalled = nil           // no stale fallback callbacks after an explicit stop
    }

    /// Full restart from the menu / source switch: rebuild and reset the watchdog
    /// to a fresh grace window. A failed rebuild escalates via onStalled.
    func restart() {
        let wasRunning = isRunning
        stopWatchdog()
        teardownPipeline()
        guard wasRunning else { return }
        do {
            try buildPipeline()
            startWatchdog()
        } catch {
            NSLog("[TouchBarSpectrum] restart rebuild failed: \(error)")
            DispatchQueue.main.async { [weak self] in self?.onStalled?() }
        }
    }

    /// Watchdog-only rebuild: rebuilds WITHOUT resetting the watchdog counters, so
    /// the cumulative "have we ever heard audio?" signal and the post-rebuild grace
    /// window are preserved. A failed rebuild escalates to fallback immediately.
    private func autoRebuild() {
        teardownPipeline()
        do {
            try buildPipeline()
        } catch {
            NSLog("[TouchBarSpectrum] watchdog rebuild failed: \(error)")
            stopWatchdog()
            DispatchQueue.main.async { [weak self] in self?.onStalled?() }
        }
    }

    // MARK: Pipeline build / teardown

    private func buildPipeline() throws {
        guard let outputUID = Self.defaultOutputDeviceUID() else { throw TapError.noOutputDevice }

        // 1. Describe a global tap of the whole system mix, excluding nothing.
        tapUUID = UUID()
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "TouchBarSpectrum System Tap"
        desc.uuid = tapUUID
        desc.muteBehavior = .unmuted          // never silence playback
        desc.isPrivate = true
        desc.isExclusive = true

        // 2. Create the process tap.
        var newTap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTap)
        guard tapStatus == noErr, newTap != 0 else { throw TapError.createTapFailed(tapStatus) }
        tapID = newTap

        // 3. Read the tap's stream format (from the TAP, not the aggregate).
        if let asbd = Self.tapFormat(tapID) {
            sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : sampleRate
        }

        // 4. Build a private aggregate device whose main sub-device is the default
        //    output and whose tap list references the tap's UUID string.
        let aggUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TouchBarSpectrum Aggregate",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]
            ],
        ]
        var newAgg: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAgg)
        guard aggStatus == noErr, newAgg != 0 else {
            AudioHardwareDestroyProcessTap(tapID); tapID = 0
            throw TapError.createAggregateFailed(aggStatus)
        }
        aggregateID = newAgg

        // 5. Install the IO block.
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handle(inInputData)
        }
        guard ioStatus == noErr, let procID else {
            teardownPipeline()
            throw TapError.createIOProcFailed(ioStatus)
        }
        ioProcID = procID

        // 6. Go.
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            teardownPipeline()
            throw TapError.startFailed(startStatus)
        }
    }

    private func teardownPipeline() {
        if aggregateID != 0, let procID = ioProcID {
            checkStatus(AudioDeviceStop(aggregateID, procID), "AudioDeviceStop")
            // Drain any IO block already in flight on ioQueue before destroying, so
            // it can't run against freed handles or race a freshly-built pipeline.
            ioQueue.sync {}
            checkStatus(AudioDeviceDestroyIOProcID(aggregateID, procID), "AudioDeviceDestroyIOProcID")
        }
        ioProcID = nil
        if aggregateID != 0 {
            checkStatus(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
            aggregateID = 0
        }
        if tapID != 0 {
            checkStatus(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
            tapID = 0
        }
    }

    private func checkStatus(_ status: OSStatus, _ label: String) {
        if status != noErr { NSLog("[TouchBarSpectrum] \(label) → OSStatus \(status)") }
    }

    // MARK: Real-time IO

    private func handle(_ inInputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard abl.count > 0 else { return }
        let dst = mono.baseAddress!
        var frames = 0

        if abl.count > 1 {
            // Non-interleaved: one buffer per channel, each mNumberChannels == 1.
            let channels = abl.count
            frames = min(Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size, maxFrames)
            for f in 0..<frames { dst[f] = 0 }
            for ch in 0..<channels {
                guard let p = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                // Guard against a short sub-buffer during format renegotiation.
                let chFrames = min(frames, Int(abl[ch].mDataByteSize) / MemoryLayout<Float>.size)
                for f in 0..<chFrames { dst[f] += p[f] }
            }
            let scale = 1 / Float(channels)
            for f in 0..<frames { dst[f] *= scale }
        } else {
            let buf = abl[0]
            let channels = max(1, Int(buf.mNumberChannels))
            guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            if channels == 1 {
                frames = min(Int(buf.mDataByteSize) / MemoryLayout<Float>.size, maxFrames)
                dst.update(from: p, count: frames)
            } else {
                // Interleaved.
                frames = min(Int(buf.mDataByteSize) / MemoryLayout<Float>.size / channels, maxFrames)
                let scale = 1 / Float(channels)
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += p[f * channels + c] }
                    dst[f] = sum * scale
                }
            }
        }

        guard frames > 0 else { return }

        // Watchdog: note whether this block carried real signal.
        var peak: Float = 0
        for f in 0..<frames { peak = max(peak, abs(dst[f])) }
        if peak > 1e-4 { nonZeroCallbacks.add(1, ordering: .relaxed) }

        onSamples?(dst, frames)
    }

    // MARK: Watchdog

    private func startWatchdog() {
        didAutoRebuild = false
        watchTick = 0
        nonZeroCallbacks.store(0, ordering: .relaxed)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.watchdogFired() }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchdogFired() {
        watchTick += 1
        let count = nonZeroCallbacks.load(ordering: .relaxed)
        if count > 0 { return }                 // audio is flowing — all good

        // Prolonged silence is AMBIGUOUS: almost always it just means nothing is
        // playing. So we self-heal the known zero-buffer bug with a SINGLE rebuild
        // after a long quiet stretch, then stop. We deliberately do NOT auto-switch
        // to BlackHole — that would wrongly fire every time the user pauses their
        // music. Switching the source stays a manual menu action.
        if !didAutoRebuild, watchTick >= 5 {     // ~15s of continuous silence
            didAutoRebuild = true
            DispatchQueue.main.async { [weak self] in self?.autoRebuild() }
        } else if didAutoRebuild, watchTick >= 10 {
            stopWatchdog()                       // give up quietly
        }
    }

    // MARK: Core Audio property helpers

    private static func defaultOutputDeviceUID() -> String? {
        // The default *output* device (where music/media plays), not the
        // system-sounds/alerts device — using the latter can clock the aggregate
        // off the wrong device and produce all-zero buffers.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard st == noErr, device != 0 else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st2 = AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &uidSize, &uid)
        guard st2 == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let st = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        return st == noErr ? asbd : nil
    }
}
