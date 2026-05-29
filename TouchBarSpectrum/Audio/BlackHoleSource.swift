import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Fallback capture path for when Core Audio process taps are unavailable or
/// misbehave (e.g. on hardware where the tap delivers only zeros). Reads from the
/// BlackHole virtual audio device via `AVAudioEngine`.
///
/// User setup (documented in the README): install BlackHole 2ch and create a
/// Multi-Output Device (Built-in Output + BlackHole 2ch) as the system output, so
/// audio is still audible while a copy flows into BlackHole for capture.
final class BlackHoleSource: AudioSource {

    enum BlackHoleError: Error, CustomStringConvertible {
        case deviceNotFound
        case engineStartFailed(Error)
        var description: String {
            switch self {
            case .deviceNotFound:        return "BlackHole audio device not found. Install BlackHole 2ch."
            case .engineStartFailed(let e): return "AVAudioEngine failed to start: \(e.localizedDescription)"
            }
        }
    }

    /// Substring used to locate the loopback device among the system's inputs.
    var deviceNameMatch = "BlackHole"

    // MARK: AudioSource

    var onSamples: ((UnsafePointer<Float>, Int) -> Void)?
    var onStalled: (() -> Void)?
    private(set) var sampleRate: Double = 48_000
    var displayName: String { "System Audio (BlackHole)" }
    private(set) var isRunning = false

    // MARK: Engine

    private let engine = AVAudioEngine()
    private let maxFrames = 16_384
    private let mono: UnsafeMutableBufferPointer<Float>

    init() {
        mono = .allocate(capacity: maxFrames)
        mono.initialize(repeating: 0)
    }

    deinit {
        stop()
        mono.deinitialize()
        mono.deallocate()
    }

    func start() throws {
        guard !isRunning else { return }
        guard let deviceID = Self.findInputDevice(matching: deviceNameMatch) else {
            throw BlackHoleError.deviceNotFound
        }

        // Point the engine's input AudioUnit at BlackHole, then reset the engine so
        // the input node re-derives its format from the new device rather than a
        // cached one (otherwise the built-in mic's 44.1 kHz can leak through).
        let input = engine.inputNode
        if let unit = input.audioUnit {
            var dev = deviceID
            let st = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            if st != noErr { NSLog("[TouchBarSpectrum] set BlackHole input device failed: OSStatus \(st)") }
        }
        engine.reset()

        // Prefer the device's authoritative nominal sample rate.
        let nodeFormat = input.inputFormat(forBus: 0)
        if let nominal = Self.deviceNominalSampleRate(deviceID) {
            sampleRate = nominal
        } else if nodeFormat.sampleRate > 0 {
            sampleRate = nodeFormat.sampleRate
        }

        // Use the node's own format when valid; otherwise pass nil and let the
        // engine pick the node format, avoiding a format-mismatch throw.
        let tapFormat: AVAudioFormat? =
            (nodeFormat.sampleRate > 0 && nodeFormat.channelCount > 0) ? nodeFormat : nil
        input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw BlackHoleError.engineStartFailed(error)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    // MARK: Capture

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frames = min(Int(buffer.frameLength), maxFrames)
        guard frames > 0, channelCount > 0 else { return }
        let dst = mono.baseAddress!

        if channelCount == 1 {
            dst.update(from: channels[0], count: frames)
        } else {
            let scale = 1 / Float(channelCount)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][f] }
                dst[f] = sum * scale
            }
        }
        onSamples?(dst, frames)
    }

    // MARK: Device lookup

    private static func findInputDevice(matching name: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices) == noErr else { return nil }

        for dev in devices {
            guard Self.hasInputChannels(dev), let devName = Self.deviceName(dev) else { continue }
            if devName.localizedCaseInsensitiveContains(name) { return dev }
        }
        return nil
    }

    private static func hasInputChannels(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let ablPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, ablPtr) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func deviceName(_ dev: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name)
        guard st == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func deviceNominalSampleRate(_ dev: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &rate)
        return (st == noErr && rate > 0) ? Double(rate) : nil
    }
}
