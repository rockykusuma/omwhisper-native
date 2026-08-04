//
//  AudioProcesses.swift
//  OmWhisper
//
//  Which processes are capturing microphone input right now, from CoreAudio's
//  process objects. This is the meeting-detection signal: direct evidence that
//  an app has the mic open, rather than an inference from a window title.
//
//  Needs no permission -- probed live 2026-08-03 from a process holding neither
//  Accessibility nor Screen Recording, and every property read returned 0.
//  Costs ~12ms steady state over 36 processes; the FIRST call costs ~211ms
//  establishing the connection to coreaudiod, which is why the caller runs this
//  off MainActor.
//
//  Reads only. The tap-and-record side of this same CoreAudio process family
//  lives in MeetingRecorder.
//

import CoreAudio
import Foundation

nonisolated enum AudioProcesses {
    struct AudioProcess: Equatable, Sendable {
        /// The bundle ID of the capturing process, which is often a HELPER --
        /// com.microsoft.teams2.modulehost, not com.microsoft.teams2. Callers
        /// must match by prefix, never exact equality.
        let bundleID: String
        let pid: pid_t
    }

    /// Processes capturing microphone input right now. Empty when any property
    /// read fails: a detection miss, never a crash. The caller treats that
    /// identically to "no call", and manual recording still works.
    static func capturingInput() -> [AudioProcess] {
        processObjects().compactMap { object in
            guard isRunningInput(object), let bundleID = bundleID(object) else { return nil }
            guard let pid = pid(object) else { return nil }
            return AudioProcess(bundleID: bundleID, pid: pid)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
            size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    /// Unmanaged<CFString>? rather than CFString?: passing `&value` where the
    /// variable holds an object reference is a real Swift 6 warning
    /// ("forming UnsafeMutableRawPointer to a variable of type Optional<CFString>").
    /// Unmanaged is a pointer-wrapping struct, so this form compiles clean.
    private static func bundleID(_ object: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var out: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out) == noErr,
              let value = out?.takeRetainedValue() as String?,
              !value.isEmpty else { return nil }
        return value
    }

    private static func pid(_ object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }
}
