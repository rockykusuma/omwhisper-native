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
        /// ONE-WAY for the remainder of a recording -- there is deliberately no
        /// unmute. A reversible mute would have to either drop frames (shifting
        /// every later "You" timestamp earlier and corrupting the interleaved
        /// transcript) or write silence (worse: the meeting path has no VAD, and
        /// Whisper is on record inventing "Thank you." out of silence). Keeping
        /// the retained audio a clean PREFIX avoids both.
        var micMuted = false
        /// Frames actually written to me.caf. The observable the mute gate is
        /// tested on -- "the file exists" would pass with the gate broken.
        var micFramesWritten: AVAudioFramePosition = 0
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
        // Which device this recording is actually tapping. Nothing recorded it
        // before, so "why does my own track sound like a room?" was
        // unanswerable after the fact -- the same gap the consent-latency stamp
        // filled. Device NAME only: config, never content, per DebugInfo's rule.
        meetingLog.notice("""
            recording mic device: \(Self.deviceName(of: micDeviceID) ?? "unknown", privacy: .public) \
            (requested: \(preferredMicUID == nil ? "system default" : "specific device", privacy: .public))
            """)
        watchMicDeviceAlive(micDeviceID)

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

        beginWriting(to: dir)

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
    /// Open a recording at `directory` and reset every per-recording mic value.
    /// Not test-only: `start()` is the production caller, and resetting here is
    /// what stops a previous recording's muted state leaking into the next one.
    nonisolated func beginWriting(to directory: URL) {
        state.withLock { s in
            s.meetingDirectory = directory
            s.micMuted = false
            s.micFramesWritten = 0
            s.micPeak = 0
        }
    }

    nonisolated var isMicMuted: Bool { state.withLock { $0.micMuted } }

    nonisolated var micFramesWritten: AVAudioFramePosition {
        state.withLock { $0.micFramesWritten }
    }

    /// Stop capturing the mic for the rest of this recording. One-way by design
    /// -- see the comment on State.micMuted. Closing micFile here is safe
    /// precisely because the gate in handle() will never reopen it.
    nonisolated func muteMic() {
        state.withLock { s in
            s.micMuted = true
            s.micFile = nil
        }
        meetingLog.notice("mic muted for the remainder of this recording")
    }

    /// Delete the mic track outright and mute. Discarding WITHOUT muting would
    /// immediately re-accumulate what was just deleted.
    nonisolated func discardMicTrack() {
        // The URL is read under the lock; the file is removed outside it. This
        // lock is taken by the real-time audio callback and must never hold I/O.
        let url: URL? = state.withLock { s in
            s.micMuted = true
            s.micFile = nil
            s.micFramesWritten = 0
            return s.meetingDirectory?.appendingPathComponent("me.caf")
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        meetingLog.notice("mic track discarded at the user's request")
    }

    /// Did any mic audio survive into this recording.
    ///
    /// Read from the FILE, never from the settings that led here, so the stored
    /// flag cannot drift from what is actually on disk. Length rather than byte
    /// size: an AVAudioFile that was created and never written still has a CAF
    /// header, so `size > 0` would answer true for an empty track.
    nonisolated var micCaptured: Bool {
        guard let dir = state.withLock({ $0.meetingDirectory }) else { return false }
        let url = dir.appendingPathComponent("me.caf")
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    /// Close both files so a test can read back what was written. Production
    /// closes them in stop(); this is the same two assignments without the
    /// hardware teardown, which no test has started.
    nonisolated func finishFilesForTesting() {
        state.withLock { s in
            s.systemFile = nil
            s.micFile = nil
        }
    }

    nonisolated private func handleRaw(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard abl.count >= 2,
              let micBuffer = Self.pcmBuffer(from: abl[0], sampleRate: streamSampleRate),
              let systemBuffer = Self.pcmBuffer(from: abl[1], sampleRate: streamSampleRate) else { return }
        handle(mic: micBuffer, system: systemBuffer)
    }

    nonisolated func handle(mic micBuffer: AVAudioPCMBuffer, system systemBuffer: AVAudioPCMBuffer) {
        let peak = Self.peak(of: micBuffer)
        state.withLock { s in
            // The single place mic buffers reach a file, and therefore the only
            // place the gate has to be. Muting upstream would leave this open.
            if !s.micMuted {
                s.micPeak = max(s.micPeak, peak)
                if let url = s.meetingDirectory?.appendingPathComponent("me.caf") {
                    if s.micFile == nil {
                        s.micFile = try? AVAudioFile(forWriting: url, settings: micBuffer.format.settings)
                    }
                    if let file = s.micFile, (try? file.write(from: micBuffer)) != nil {
                        s.micFramesWritten += AVAudioFramePosition(micBuffer.frameLength)
                    }
                }
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

    /// Human-readable device name, for the log line at record start. Returns
    /// nil rather than throwing: not knowing the name must never stop a
    /// recording.
    nonisolated private static func deviceName(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Log the moment the recorded mic device stops being alive.
    ///
    /// The device is a SNAPSHOT taken here: it is baked into the aggregate's
    /// sub-device list and nothing follows a later change. So switching input
    /// mid-call silently keeps recording the original device -- which is what
    /// happened on 2026-08-11, where a call moved to a headset was captured on
    /// the built-in mic for its whole 8m53s, and the opening transcribed as
    /// room noise. Unplugging is the worse case, and until this listener
    /// existed it was invisible: the track simply went quiet.
    ///
    /// This only REPORTS. Rebuilding the aggregate on a live recording is a
    /// separate piece of work; naming the failure comes first.
    nonisolated private func watchMicDeviceAlive(_ deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, nil) { _, _ in
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &alive)
            meetingLog.error(
                "recorded mic device is no longer alive (alive=\(alive, privacy: .public)) — the rest of this recording's own-voice track may be silent")
        }
        if status != noErr {
            meetingLog.warning("could not watch mic device liveness: \(status)")
        }
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
