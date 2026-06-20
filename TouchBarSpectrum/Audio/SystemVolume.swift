import CoreAudio
import Foundation

/// Reads and writes the **default output device's** volume via the Core Audio HAL,
/// mirroring how `AudioTapManager` locates that same device. Used by the Touch Bar
/// swipe-to-set-volume gesture.
///
/// Devices expose volume in one of two shapes, so every accessor tries them in order:
///   1. a single *virtual main* scalar on the main element (built-in speakers, AirPods…)
///   2. per-channel scalars on the stereo channels (many aggregate / external devices)
///
/// Setting `kAudioDevicePropertyVolumeScalar` does **not** raise the system volume HUD
/// (that is driven by a private path the media keys use), which is why the Touch Bar
/// view paints its own brief volume readout.
enum SystemVolume {

    /// The current default output device, or nil if none is selected.
    private static func defaultOutputDevice() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return (st == noErr && dev != 0) ? dev : nil
    }

    private static func isSettable(_ dev: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr && settable.boolValue
    }

    /// The volume-scalar property addresses that actually exist on this device:
    /// the main element if present, otherwise the stereo channels. When
    /// `settableOnly` is true, addresses whose value can't be written are dropped.
    private static func volumeAddresses(_ dev: AudioObjectID, settableOnly: Bool) -> [AudioObjectPropertyAddress] {
        var main = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &main), !settableOnly || isSettable(dev, &main) {
            return [main]
        }

        // Per-channel fallback. Default to channels 1/2; refine with the device's
        // own stereo pairing if it advertises one.
        var channels: [UInt32] = [1, 2]
        var prefAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var pref = [UInt32](repeating: 0, count: 2)
        var psize = UInt32(MemoryLayout<UInt32>.size * 2)
        let gotPref = pref.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(dev, &prefAddr, 0, nil, &psize, $0.baseAddress!) == noErr
        }
        if gotPref, pref[0] != 0 || pref[1] != 0 { channels = pref }

        return channels.compactMap { ch in
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: ch)
            guard AudioObjectHasProperty(dev, &a), !settableOnly || isSettable(dev, &a) else { return nil }
            return a
        }
    }

    /// Whether the current output device has a writable volume at all (some digital
    /// / HDMI outputs don't — the swipe is a no-op there).
    static var hasControl: Bool {
        guard let dev = defaultOutputDevice() else { return false }
        return !volumeAddresses(dev, settableOnly: true).isEmpty
    }

    /// Current output volume in 0…1, averaged across channels, or nil if unreadable.
    static func get() -> Float? {
        guard let dev = defaultOutputDevice() else { return nil }
        var total: Float = 0
        var count = 0
        for var a in volumeAddresses(dev, settableOnly: false) {
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr {
                total += v
                count += 1
            }
        }
        return count > 0 ? total / Float(count) : nil
    }

    /// Sets the output volume (clamped to 0…1). Returns true if any channel took it.
    /// Keeps the device's mute flag coherent: unmutes when raising above silence,
    /// mutes at the very bottom — matching the media-key behaviour.
    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let dev = defaultOutputDevice() else { return false }
        let v = max(0, min(1, value))
        let addrs = volumeAddresses(dev, settableOnly: true)
        guard !addrs.isEmpty else { return false }

        var ok = false
        for var a in addrs {
            var vol = Float32(v)
            if AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol) == noErr {
                ok = true
            }
        }
        setMuted(dev, v <= 0.0005)
        return ok
    }

    private static func setMuted(_ dev: AudioObjectID, _ muted: Bool) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &addr), isSettable(dev, &addr) else { return }
        var m: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }
}
