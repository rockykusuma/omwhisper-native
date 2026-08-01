//
//  MeetingRecorder.swift
//  OmWhisper
//
//  Dual-track (system audio + mic) recording via CoreAudio process taps and an
//  aggregate device -- NOT ScreenCaptureKit. An earlier version of this file
//  used SCK (matching smriti's reference implementation), but that still
//  triggers macOS's full Screen Recording permission and a system-wide
//  "Currently Sharing" indicator even for pure audio capture -- confirmed live,
//  and correctly flagged by the user as disproportionate for an audio-only
//  feature. A real app (Littlebird) ships audio-only capture under macOS's
//  distinct "System Audio Recording Only" permission tier; this file uses the
//  same underlying API. Verified directly against the macOS 26 SDK's
//  AudioHardwareTapping.h / CATapDescription.h / AudioHardware.h (not guessed):
//
//  1. AudioHardwareCreateProcessTap + CATapDescription
//     .initStereoGlobalTapButExcludeProcesses([ourProcessObjectID]) taps
//     system-wide audio output, excluding this app's own sounds. No screen
//     involvement at all.
//  2. AudioHardwareCreateAggregateDevice combines the real default input
//     device (the physical mic, as a sub-device) and that tap into one
//     virtual input device. Reading through the aggregate rather than the raw
//     mic device sidesteps the same VoIP-app-holds-the-mic-exclusively
//     problem SCK's captureMicrophone solved, without ScreenCaptureKit.
//  3. Read via raw CoreAudio HAL I/O (AudioDeviceCreateIOProcIDWithBlock +
//     AudioDeviceStart directly on the aggregate device) -- NOT AVAudioEngine.
//     An AVAudioEngine-based version was tried first (pointing the engine's
//     input node at the aggregate via kAudioOutputUnitProperty_CurrentDevice,
//     the same mechanism AudioCapture.setInputDevice(_:on:) uses for mic
//     device selection), but it never worked live: the aggregate device
//     itself verifiably has the correct channel count (confirmed via a direct
//     HAL query independent of AVAudioEngine), yet AVAudioEngine's tap
//     callback never fired even once, across three targeted fixes (a settle
//     delay after aggregate creation, and two different attempts at
//     explicit-format construction to route around AVAudioInputNode's stale
//     cached format). AVAudioEngine's higher-level abstraction is evidently
//     not built for exotic freshly-created virtual/tap-backed devices the way
//     it is for real hardware. Raw HAL I/O is the standard, lower-level path
//     other audio-only meeting recorders use for exactly this device shape.
//
//  Net effect: only Microphone permission (already granted for dictation via
//  the existing audio-input entitlement), no Screen Recording prompt, no
//  video frame, no system sharing indicator.
//
//  Each HAL IO cycle delivers an AudioBufferList with two separate
//  AudioBuffers -- confirmed live, not assumed: buffer[0] is the mic
//  sub-device (mono), buffer[1] is the stereo tap (interleaved), in the fixed
//  order this file's own sub-device/tap list construction controls. Not one
//  combined multi-channel buffer, and not two separate callbacks the way SCK
//  gave us -- each buffer is deinterleaved into its own AVAudioPCMBuffer and
//  written straight to me.caf/them.caf, no channel-range slicing needed.
//
//  Two independent .caf files, not one interleaved file -- them.caf (system
//  audio) and me.caf (mic) -- matching the original design, which keeps later
//  per-track transcription simple.
//
//  Concurrency note (the exact lesson the SCK crash taught, still applicable
//  here): the project defaults new declarations to @MainActor
//  (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), but the HAL IOProc block
//  genuinely runs on its own real-time thread, matching AudioCapture's own
//  documented rationale. nonisolated + one OSAllocatedUnfairLock-protected
//  State bundle, not per-property locking.
//

@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

nonisolated private let meetingLog = Logger(subsystem: "com.omwhisper.mac", category: "MeetingRecorder")

final class MeetingRecorder: @unchecked Sendable {
    private struct State {
        var systemFile: AVAudioFile?
        var micFile: AVAudioFile?
        var meetingDirectory: URL?
        /// Loudest mic sample seen this recording, in linear amplitude (0...1) --
        /// logged as a warning on stop() if it never exceeds roughly -100dBFS,
        /// the "calling app blocked mic capture" self-check ported from smriti.
        var micPeak: Float = 0
    }

    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) private var tapID: AudioObjectID = kAudioObjectUnknown
    nonisolated(unsafe) private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    nonisolated(unsafe) private var ioProcID: AudioDeviceIOProcID?
    /// The aggregate delivers each stream (mic sub-device, stereo tap) as its
    /// own separate AudioBuffer within one AudioBufferList -- NOT one combined
    /// multi-channel buffer -- confirmed live: mNumberBuffers=2, buffer[0] 1ch
    /// (mic), buffer[1] 2ch interleaved (tap). Only the sample rate is shared
    /// across streams; each buffer's own channel count comes from the HAL callback.
    nonisolated(unsafe) private var streamSampleRate: Double = 48000

    nonisolated var meetingDirectory: URL? {
        state.withLock { $0.meetingDirectory }
    }

    /// `preferredMicUID` — the app's selected input device (from the Audio settings
    /// / menu-bar mic picker). Falls back to the system default when nil or the UID
    /// no longer resolves (e.g. the device was unplugged).
    nonisolated func start(appName: String, preferredMicUID: String? = nil) throws {
        let dir = try Self.makeMeetingDirectory(appName: appName)

        let micDeviceID: AudioDeviceID
        if let preferredMicUID, let resolved = AudioCapture.coreAudioDeviceID(forUID: preferredMicUID) {
            micDeviceID = resolved
        } else {
            micDeviceID = try Self.defaultInputDeviceID()
        }
        let micUID = try Self.deviceUID(of: micDeviceID)

        let ownProcessID = try Self.ownProcessObjectID()
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessID])
        tapDescription.isPrivate = true
        var newTapID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr else {
            throw Self.error("AudioHardwareCreateProcessTap", tapStatus)
        }
        tapID = newTapID
        // NOT tapDescription.uuid.uuidString -- that's just the client-set
        // description identifier. kAudioTapPropertyUID is the actual
        // persistent UID CoreAudio expects in kAudioSubTapUIDKey below,
        // queried the same way deviceUID(of:) reads a real device's UID.
        let tapUID = try Self.tapUID(of: newTapID)

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "OmWhisper Meeting Capture",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
        ]
        var newAggregateID = kAudioObjectUnknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard aggregateStatus == noErr else {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            throw Self.error("AudioHardwareCreateAggregateDevice", aggregateStatus)
        }
        aggregateDeviceID = newAggregateID

        do {
            let asbd = try Self.inputStreamFormat(of: aggregateDeviceID)
            streamSampleRate = asbd.mSampleRate
        } catch {
            teardownHardware()
            throw error
        }

        state.withLock { s in
            s.meetingDirectory = dir
        }

        var newIOProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, nil) { [weak self] _, inInputData, _, _, _ in
            self?.handleRaw(inInputData)
        }
        guard procStatus == noErr, let newIOProcID else {
            teardownHardware()
            throw Self.error("AudioDeviceCreateIOProcIDWithBlock", procStatus)
        }
        ioProcID = newIOProcID

        let startStatus = AudioDeviceStart(aggregateDeviceID, newIOProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, newIOProcID)
            ioProcID = nil
            teardownHardware()
            throw Self.error("AudioDeviceStart", startStatus)
        }
    }

    nonisolated func stop() async {
        if let ioProcID {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        teardownHardware()

        let peak = state.withLock { s -> Float in
            s.systemFile = nil
            s.micFile = nil
            return s.micPeak
        }
        if peak < 0.00001 {  // roughly -100dBFS
            meetingLog.warning("stop() — mic track peak was near-silent (\(peak)); the calling app may have blocked mic capture")
        }
    }

    nonisolated private func teardownHardware() {
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// Runs on the HAL's real-time IO thread -- must never touch MainActor
    /// state directly, matching AudioCapture's tap callback rationale.
    /// The aggregate delivers exactly two streams as separate AudioBuffers
    /// (confirmed live) -- buffer[0] is the mic sub-device, buffer[1] is the
    /// stereo tap, in the fixed order this file's own sub-device/tap list
    /// construction controls. No channel-range slicing needed.
    nonisolated private func handleRaw(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard abl.count >= 2,
              let micBuffer = Self.pcmBuffer(from: abl[0], sampleRate: streamSampleRate),
              let systemBuffer = Self.pcmBuffer(from: abl[1], sampleRate: streamSampleRate) else { return }
        handle(mic: micBuffer, system: systemBuffer)
    }

    nonisolated private func handle(mic micBuffer: AVAudioPCMBuffer, system systemBuffer: AVAudioPCMBuffer) {
        let peak = Self.peak(of: micBuffer)
        state.withLock { s in
            s.micPeak = max(s.micPeak, peak)
            if let url = s.meetingDirectory?.appendingPathComponent("me.caf") {
                if s.micFile == nil {
                    s.micFile = try? AVAudioFile(forWriting: url, settings: micBuffer.format.settings)
                }
                try? s.micFile?.write(from: micBuffer)
            }
            if let url = s.meetingDirectory?.appendingPathComponent("them.caf") {
                if s.systemFile == nil {
                    s.systemFile = try? AVAudioFile(forWriting: url, settings: systemBuffer.format.settings)
                }
                try? s.systemFile?.write(from: systemBuffer)
            }
        }
    }

    /// Deinterleaves one raw HAL AudioBuffer into a fresh, standalone
    /// AVAudioPCMBuffer -- AVAudioFile.write(from:) and floatChannelData both
    /// expect non-interleaved buffers, matching every other buffer in this
    /// codebase (AudioCapture, BufferConverter).
    nonisolated private static func pcmBuffer(from audioBuffer: AudioBuffer, sampleRate: Double) -> AVAudioPCMBuffer? {
        let channelCount = Int(audioBuffer.mNumberChannels)
        let bytesPerSample = MemoryLayout<Float>.size
        guard channelCount > 0,
              let sourceData = audioBuffer.mData,
              audioBuffer.mDataByteSize > 0 else { return nil }
        let frameCount = Int(audioBuffer.mDataByteSize) / bytesPerSample / channelCount
        guard frameCount > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: AVAudioChannelCount(channelCount), interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let destData = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let source = sourceData.assumingMemoryBound(to: Float.self)
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                destData[channel][frame] = source[frame * channelCount + channel]
            }
        }
        return buffer
    }

    nonisolated private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var result: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<frameCount {
                result = max(result, abs(channelData[channel][frame]))
            }
        }
        return result
    }

    // MARK: HAL plumbing

    nonisolated private static func ownProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr else { throw error("kAudioHardwarePropertyProcessObjectList size", status) }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs)
        guard status == noErr else { throw error("kAudioHardwarePropertyProcessObjectList", status) }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        for processID in processIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let pidStatus = AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &pid)
            if pidStatus == noErr, pid == ourPID { return processID }
        }
        throw error("own process not found in kAudioHardwarePropertyProcessObjectList", -1)
    }

    nonisolated private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        guard status == noErr else { throw error("kAudioHardwarePropertyDefaultInputDevice", status) }
        return deviceID
    }

    nonisolated private static func deviceUID(of deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else { throw error("kAudioDevicePropertyDeviceUID", status) }
        return uid.takeRetainedValue() as String
    }

    nonisolated private static func tapUID(of tapObjectID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tapObjectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else { throw error("kAudioTapPropertyUID", status) }
        return uid.takeRetainedValue() as String
    }

    /// Only the sample rate is read from this -- per-buffer channel counts
    /// come from the HAL callback itself (see handleRaw), since the aggregate
    /// delivers the mic and tap as two separately-shaped AudioBuffers, not
    /// one stream this ASBD alone could fully describe.
    /// kAudioDevicePropertyStreamFormat is deprecated in favor of querying
    /// the stream object directly, but still functions correctly and is far
    /// simpler for what this needs.
    nonisolated private static func inputStreamFormat(of deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw error("kAudioDevicePropertyStreamFormat", status) }
        return asbd
    }

    nonisolated private static func makeMeetingDirectory(appName: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let stamp = formatter.string(from: Date())
        // Shared bundle-ID-aware root, not an inline lookup — keeps dev-build
        // recordings out of the installed app's data directory.
        guard let root = AppSupportDirectory.resolve() else {
            throw error("makeMeetingDirectory: no Application Support directory", -1)
        }
        let base = root
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("\(stamp)_\(appName)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated private static func error(_ context: String, _ status: OSStatus) -> NSError {
        NSError(domain: "MeetingRecorder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(context) failed: \(status)"])
    }
}
