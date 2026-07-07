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
//     problem SCK's captureMicrophone solved, without ScreenCaptureKit: VoIP
//     apps (Zoom, Teams, WhatsApp, etc.) hold the input device exclusively
//     during a call, so a plain AVAudioEngine tap on the raw device records
//     silence while a call is active -- the aggregate's own HAL-level
//     composition doesn't compete for that same exclusive grab.
//  3. AVAudioEngine's input node is pointed at the aggregate device via
//     kAudioOutputUnitProperty_CurrentDevice -- the exact mechanism
//     AudioCapture.setInputDevice(_:on:) already uses for mic device
//     selection, reused rather than reimplemented.
//
//  Net effect: only Microphone permission (already granted for dictation via
//  the existing audio-input entitlement), no Screen Recording prompt, no
//  video frame, no system sharing indicator.
//
//  The aggregate delivers ONE multi-channel buffer per tap (mic channels
//  first, then the stereo tap's channels -- fixed by the sub-device/tap
//  ordering this code controls), not two separate callbacks the way SCK gave
//  us, so each buffer is sliced by channel range into two AVAudioPCMBuffers
//  before writing to me.caf/them.caf.
//
//  Two independent .caf files, not one interleaved file -- them.caf (system
//  audio) and me.caf (mic) -- matching the original design, which keeps later
//  per-track transcription simple.
//
//  Concurrency note (the exact lesson the SCK crash taught, still applicable
//  here): the project defaults new declarations to @MainActor
//  (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor), but AVAudioEngine's tap
//  callback genuinely runs on its own real-time render thread, matching
//  AudioCapture's own documented rationale. nonisolated + one
//  OSAllocatedUnfairLock-protected State bundle, not per-property locking.
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
        var micChannelCount: Int = 1
        /// Loudest mic sample seen this recording, in linear amplitude (0...1) --
        /// logged as a warning on stop() if it never exceeds roughly -100dBFS,
        /// the "calling app blocked mic capture" self-check ported from smriti.
        var micPeak: Float = 0
    }

    nonisolated private let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) private let engine = AVAudioEngine()
    nonisolated(unsafe) private var tapID: AudioObjectID = kAudioObjectUnknown
    nonisolated(unsafe) private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown

    nonisolated var meetingDirectory: URL? {
        state.withLock { $0.meetingDirectory }
    }

    nonisolated func start(appName: String) throws {
        let dir = try Self.makeMeetingDirectory(appName: appName)

        let micDeviceID = try Self.defaultInputDeviceID()
        let micUID = try Self.deviceUID(of: micDeviceID)
        let micChannelCount = try Self.inputChannelCount(of: micDeviceID)

        let ownProcessID = try Self.ownProcessObjectID()
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessID])
        tapDescription.isPrivate = true
        var newTapID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr else {
            throw Self.error("AudioHardwareCreateProcessTap", tapStatus)
        }
        tapID = newTapID
        let tapUID = tapDescription.uuid.uuidString

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
            try Self.setInputDevice(aggregateDeviceID, on: engine.inputNode)
        } catch {
            teardownHardware()
            throw error
        }

        state.withLock { s in
            s.meetingDirectory = dir
            s.micChannelCount = micChannelCount
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            teardownHardware()
            throw error
        }
    }

    nonisolated func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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

    /// Runs on AVAudioEngine's real-time render thread -- must never touch
    /// MainActor state directly, matching AudioCapture's tap callback rationale.
    nonisolated private func handle(_ buffer: AVAudioPCMBuffer) {
        let micChannelCount = state.withLock { $0.micChannelCount }
        guard let micBuffer = Self.slice(buffer, channelRange: 0..<micChannelCount) else { return }
        let systemChannelCount = Int(buffer.format.channelCount) - micChannelCount
        let systemBuffer = systemChannelCount > 0
            ? Self.slice(buffer, channelRange: micChannelCount..<Int(buffer.format.channelCount))
            : nil

        let peak = Self.peak(of: micBuffer)
        state.withLock { s in
            s.micPeak = max(s.micPeak, peak)
            if let url = s.meetingDirectory?.appendingPathComponent("me.caf") {
                if s.micFile == nil {
                    s.micFile = try? AVAudioFile(forWriting: url, settings: micBuffer.format.settings)
                }
                try? s.micFile?.write(from: micBuffer)
            }
            if let systemBuffer, let url = s.meetingDirectory?.appendingPathComponent("them.caf") {
                if s.systemFile == nil {
                    s.systemFile = try? AVAudioFile(forWriting: url, settings: systemBuffer.format.settings)
                }
                try? s.systemFile?.write(from: systemBuffer)
            }
        }
    }

    /// Copies a contiguous channel range out of a multi-channel buffer into a
    /// fresh buffer of its own -- AVAudioFile.write(from:) writes every
    /// channel in the buffer it's given, so each track needs its own
    /// standalone buffer rather than a view into the combined one.
    nonisolated private static func slice(_ buffer: AVAudioPCMBuffer, channelRange: Range<Int>) -> AVAudioPCMBuffer? {
        guard !channelRange.isEmpty,
              channelRange.upperBound <= Int(buffer.format.channelCount),
              let sourceData = buffer.floatChannelData,
              let slicedFormat = AVAudioFormat(
                commonFormat: buffer.format.commonFormat,
                sampleRate: buffer.format.sampleRate,
                channels: AVAudioChannelCount(channelRange.count),
                interleaved: false
              ),
              let sliced = AVAudioPCMBuffer(pcmFormat: slicedFormat, frameCapacity: buffer.frameCapacity),
              let destData = sliced.floatChannelData else { return nil }
        sliced.frameLength = buffer.frameLength
        for (destChannel, sourceChannel) in channelRange.enumerated() {
            destData[destChannel].update(from: sourceData[sourceChannel], count: Int(buffer.frameLength))
        }
        return sliced
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

    nonisolated private static func inputChannelCount(of deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { throw error("kAudioDevicePropertyStreamConfiguration size", status) }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }
        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else { throw error("kAudioDevicePropertyStreamConfiguration", status) }

        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channelCount = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return max(1, channelCount)
    }

    /// Mirrors AudioCapture.setInputDevice(_:on:) exactly -- same mechanism,
    /// now pointed at our aggregate device instead of a physical one.
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
        guard status == noErr else { throw error("kAudioOutputUnitProperty_CurrentDevice", status) }
    }

    nonisolated private static func makeMeetingDirectory(appName: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let stamp = formatter.string(from: Date())
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("com.omwhisper.mac", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
            .appendingPathComponent("\(stamp)_\(appName)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated private static func error(_ context: String, _ status: OSStatus) -> NSError {
        NSError(domain: "MeetingRecorder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(context) failed: \(status)"])
    }
}
