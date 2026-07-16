//
//  AudioCapture.swift
//  OmWhisper
//
//  AVAudioEngine mic capture → AsyncStream of PCM buffers.
//  Replaces the Tauri app's cpal + resampler + VAD worker (engines do their own
//  format conversion / endpointing).
//
//  Concurrency note: the project defaults new declarations to @MainActor
//  isolation (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), but AVAudioEngine's
//  tap callback genuinely runs on its own real-time render thread, not
//  MainActor. This type opts its members out of that default with `nonisolated`
//  and guards the state the tap touches with a lock instead of actor isolation
//  — the correct pattern for real-time audio, which can't tolerate an actor hop
//  or lock contention from something slow. AVAudioPCMBuffer itself isn't
//  Sendable (it's a mutable buffer wrapper), so AVFoundation is imported
//  `@preconcurrency` to avoid fighting the compiler over a framework type we
//  don't control; we uphold the actual safety invariant ourselves (each buffer
//  has exactly one producer — the tap — and is hopped to exactly one consumer).
//

@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import os

nonisolated struct AudioInputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

final class AudioCapture {
    private struct State {
        var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
        var level: Float = 0
    }

    nonisolated(unsafe) private let engine = AVAudioEngine()
    // OSAllocatedUnfairLock is unconditionally Sendable (the lock itself
    // guarantees safety regardless of the wrapped State) — plain `nonisolated`
    // suffices; `AVAudioEngine` above isn't Sendable, so it still needs `(unsafe)`.
    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())

    /// Mic input level (0–1) for the waveform UI. Safe to read from any thread.
    nonisolated var level: Float {
        state.withLock { $0.level }
    }

    /// For the Audio settings picker — persistent UIDs, not just names (the old
    /// Tauri app matched on name alone, which breaks for two same-model mics).
    /// Enumerate input devices via the CoreAudio HAL, NOT
    /// AVCaptureDevice.DiscoverySession — the latter cold-starts AVFoundation's
    /// whole capture stack (camera CMIO DAL included) on first use, a multi-second
    /// stall on the Audio settings tab. The HAL touches only audio and is fast.
    /// UIDs here match the CoreAudio UIDs `coreAudioDeviceID(forUID:)` resolves.
    nonisolated static func availableInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs.compactMap { deviceID in
            guard deviceHasInput(deviceID),
                  let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// Async wrapper so enumeration runs off MainActor. `nonisolated async` runs on
    /// the cooperative pool, not the caller's actor — keeps the settings tab from
    /// stuttering even on a busy system.
    nonisolated static func loadInputDevices() async -> [AudioInputDevice] {
        availableInputDevices()
    }

    /// True if the device exposes at least one input channel (mic-capable).
    nonisolated private static func deviceHasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.contains { $0.mNumberChannels > 0 }
    }

    /// Read a CFString device property (UID / name) via the HAL.
    nonisolated private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// nil/not-found preferredDeviceUID falls back to the system default input —
    /// same semantics as the old app (`audio_input_device: None`).
    nonisolated func start(preferredDeviceUID: String? = nil) throws -> AsyncStream<AVAudioPCMBuffer> {
        let input = engine.inputNode

        // A start() that threw after installTap left its tap behind, and
        // installTap on an already-tapped bus traps ("required condition is
        // false: nullptr == Tap()") — so one failed start poisoned every later
        // one. Bluetooth makes that routine: AirPods bringing up their SCO link
        // fail engine.start() with "_StartIO: Start failed ... error 35".
        // removeTap on an untapped bus is a documented no-op, so this is always
        // safe and makes a leaked tap unable to arm the trap.
        input.removeTap(onBus: 0)

        if let preferredDeviceUID, let deviceID = Self.coreAudioDeviceID(forUID: preferredDeviceUID) {
            try Self.setInputDevice(deviceID, on: input)
        }

        // inputFormat, NOT outputFormat. For a Bluetooth mic these DISAGREE:
        // measured on real AirPods, inputFormat=24000Hz (the actual hardware, in
        // HFP mode) while outputFormat still claims 48000Hz. AVFAudio validates
        // the tap format against the hardware and traps — "Format mismatch: input
        // hw <24000 Hz>, client format <48000 Hz>" — which is the crash selecting
        // AirPods in the mic picker produced. Worse, when it didn't trap it
        // delivered ZERO frames: asking a 24kHz device for 48kHz yields silence.
        // Every non-Bluetooth device reports the two identically, which is why
        // this went unnoticed. BufferConverter resamples whatever arrives, so the
        // engines are unaffected by the rate.
        let format = input.inputFormat(forBus: 0)

        // Bounded so a stalled consumer (converter/ASR falling behind the mic)
        // drops stale audio to recover latency instead of queuing unbounded —
        // otherwise partial lag and memory both grow without limit.
        // ponytail: ~4s cushion at 48kHz/4096-frame buffers; the queue only fills
        // under a pathological stall, never in normal real-time operation.
        let (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self,
            bufferingPolicy: .bufferingNewest(48)
        )
        state.withLock { $0.continuation = continuation }

        // This closure runs on AVAudioEngine's real-time render thread. It must
        // never touch MainActor state directly — only the lock-protected `state`.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [state] buffer, _ in
            let level = Self.rms(of: buffer)
            state.withLock { s in
                s.level = level
                s.continuation?.yield(buffer)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Leave nothing armed for the next start(): an installed tap would
            // trap it, and a live continuation would strand its consumer. This is
            // the routine Bluetooth path, not a corner case — see removeTap above.
            input.removeTap(onBus: 0)
            state.withLock { s in
                s.continuation?.finish()
                s.continuation = nil
                s.level = 0
            }
            throw error
        }
        return stream
    }

    nonisolated func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        state.withLock { s in
            s.continuation?.finish()
            s.continuation = nil
            s.level = 0
        }
    }

    nonisolated private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, sqrt(sum / Float(n)) * 10)
    }

    // MARK: Device selection
    //
    // AVAudioEngine has no cross-platform "pick an input device" API on macOS
    // (unlike AVAudioSession on iOS) — the only way is the underlying input
    // AudioUnit's kAudioOutputUnitProperty_CurrentDevice, set before the engine
    // starts (the node's format/channel count depend on the selected device).

    nonisolated static func coreAudioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return nil
        }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceUID: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &deviceUID) {
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &size, $0)
            }
            if status == noErr, let deviceUID, (deviceUID.takeRetainedValue() as String) == uid {
                return deviceID
            }
        }
        return nil
    }

    nonisolated private static func setInputDevice(_ deviceID: AudioDeviceID, on node: AVAudioInputNode) throws {
        guard let audioUnit = node.audioUnit else { return }
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

