// TapSmokeTest.swift — standalone Core Audio process-tap smoke test.
//
// Purpose: on the real Intel MacBook Pro, confirm (before trusting the app) that
// AudioHardwareCreateProcessTap on the WHOLE system mix actually delivers NON-ZERO
// audio. This resolves the "process taps on Intel — likely but unverified" risk.
//
// Run (play some audio first, e.g. music in another app):
//     swift Tools/TapSmokeTest.swift
//   or
//     swiftc -o /tmp/tapsmoke Tools/TapSmokeTest.swift && /tmp/tapsmoke
//
// Caveat: a bare CLI tool has no Info.plist usage string, so macOS may DENY the
// audio-capture TCC permission and the tap will read silence even when audio plays.
// If you see "FAIL: only silence", that may be the CLI permission limitation rather
// than a tap-on-Intel failure — the real verdict is the .app (which carries the
// NSAudioCaptureUsageDescription prompt). A "PASS" here is conclusive; a "FAIL" is
// only suggestive. Either way, the app ships a BlackHole fallback.

import CoreAudio
import AudioToolbox
import Foundation

func defaultOutputUID() -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
          dev != 0 else { return nil }
    var uidAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?; var usize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &usize, &uid) == noErr, let uid else { return nil }
    return uid.takeRetainedValue() as String
}

guard #available(macOS 14.2, *) else {
    print("FAIL: process taps require macOS 14.2+"); exit(1)
}
guard let outputUID = defaultOutputUID() else {
    print("FAIL: no default output device"); exit(1)
}
print("• default output UID: \(outputUID)")

let tapUUID = UUID()
let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
desc.name = "TapSmokeTest"
desc.uuid = tapUUID
desc.muteBehavior = .unmuted
desc.isPrivate = true
desc.isExclusive = true

var tapID = AudioObjectID(0)
let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
guard tapStatus == noErr, tapID != 0 else {
    print("FAIL: AudioHardwareCreateProcessTap → OSStatus \(tapStatus)"); exit(1)
}
print("• created process tap id=\(tapID)")

let aggUID = UUID().uuidString
let dict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "TapSmokeTest-Agg",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: tapUUID.uuidString,
    ]],
]
var aggID = AudioObjectID(0)
let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
guard aggStatus == noErr, aggID != 0 else {
    print("FAIL: AudioHardwareCreateAggregateDevice → OSStatus \(aggStatus)")
    AudioHardwareDestroyProcessTap(tapID); exit(1)
}
print("• created aggregate device id=\(aggID)")

let peak = ManagedAtomicBox()
let queue = DispatchQueue(label: "tapsmoke.io", qos: .userInteractive)
var procID: AudioDeviceIOProcID?
let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, inInput, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    var localPeak: Float = 0
    for b in 0..<abl.count {
        guard let p = abl[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let n = Int(abl[b].mDataByteSize) / MemoryLayout<Float>.size
        for i in 0..<n { localPeak = max(localPeak, abs(p[i])) }
    }
    peak.max(localPeak)
}
guard ioStatus == noErr, let procID else {
    print("FAIL: AudioDeviceCreateIOProcIDWithBlock → OSStatus \(ioStatus)")
    AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID); exit(1)
}
guard AudioDeviceStart(aggID, procID) == noErr else {
    print("FAIL: AudioDeviceStart failed")
    AudioDeviceDestroyIOProcID(aggID, procID)
    AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID); exit(1)
}

print("• capturing 8s — PLAY SOME AUDIO NOW…")
var everNonZero = false
for s in 1...8 {
    Thread.sleep(forTimeInterval: 1)
    let p = peak.takeReset()
    if p > 1e-4 { everNonZero = true }
    print(String(format: "  [%ds] peak=%.5f %@", s, p, p > 1e-4 ? "✓ audio" : "· silence"))
}

AudioDeviceStop(aggID, procID)
AudioDeviceDestroyIOProcID(aggID, procID)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)

if everNonZero {
    print("\nPASS ✓ — process taps deliver real audio on this machine. The app's primary path will work.")
    exit(0)
} else {
    print("\nFAIL — only silence captured. Either no audio was playing, the CLI was denied audio-capture")
    print("permission (likely — bare CLI has no usage string), or the tap is non-functional here.")
    print("Run the .app (it prompts for permission) and/or use the BlackHole fallback.")
    exit(2)
}

// Tiny lock-protected peak holder (the IO block runs on its own queue).
final class ManagedAtomicBox {
    private var value: Float = 0
    private let lock = NSLock()
    func max(_ v: Float) { lock.lock(); if v > value { value = v }; lock.unlock() }
    func takeReset() -> Float { lock.lock(); let v = value; value = 0; lock.unlock(); return v }
}
