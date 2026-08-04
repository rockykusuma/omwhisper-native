//
//  DebugInfo.swift
//  OmWhisper
//
//  One block of text a user can paste into a bug report. Configuration and
//  permission state only -- never transcription text, window titles, memory
//  snapshots, or API keys (keys report as "saved"/"not saved", nothing more).
//  A debug dump gets pasted into GitHub issues and emails; it has to be safe to
//  hand over without reading it first.
//
//  There is no log file to rotate: the app already logs through os.Logger, and
//  the unified log is the rotating log -- macOS owns its retention. We just read
//  our own process's entries back out via OSLogStore.
//

import AppKit
import AVFoundation
import OSLog
import Speech

nonisolated enum DebugInfo {
    /// Newest `limit` lines, oldest-first. Its own function because taking the
    /// wrong end of the buffer produces a dump that looks fine and is useless --
    /// the interesting lines are always the last ones before the problem.
    static func newestLines(_ lines: [String], limit: Int) -> [String] {
        Array(lines.suffix(limit))
    }

    /// Recent entries this process wrote to the unified log. `.currentProcessIdentifier`
    /// scope needs no entitlement and can only ever see our own logging.
    /// Note `.debug` entries are memory-only and usually absent by design.
    static func recentLogLines(minutes: Double = 30, limit: Int = 80) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-minutes * 60))
            let stamp = DateFormatter()
            stamp.dateFormat = "HH:mm:ss"
            let lines = try store.getEntries(at: start)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem.hasPrefix("com.omwhisper") }
                .map { "\(stamp.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
            return newestLines(lines, limit: limit)
        } catch {
            return ["(couldn't read the log: \(error.localizedDescription))"]
        }
    }

    @MainActor static func text(for state: AppState) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        // Local time, not UTC — it has to line up with the log timestamps below,
        // which the system reports in local time.
        let clock = ISO8601DateFormatter()
        clock.timeZone = .current

        var out = """
        OmWhisper \(version) (\(build))
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(machineArchitecture()) · \(clock.string(from: Date()))

        TRANSCRIPTION
          Active: \(state.engineStatusLine)
          Engine setting: \(state.engineKind.rawValue)
          Whisper: \(state.whisperModel.displayName) — \(yesNo(WhisperEngine.isDownloaded(state.whisperModel), "downloaded"))
          Parakeet: \(state.parakeetModel.displayName) — \(yesNo(ParakeetEngine.isDownloaded(state.parakeetModel), "downloaded"))
          Cloud: \(state.cloudProvider.displayName) — \(keyState(Keychain.loadSTTKey(state.cloudProvider)))
          Whisper language: \(state.whisperLanguage)
          Cross-lingual: \(onOff(state.crossLingualEnabled)) (via Sarvam: \(onOff(state.crossLingualUseSarvam)), \(keyState(Keychain.loadSarvamKey())))

        POLISH
          Backend: \(state.polishBackend.rawValue)
          Apple Intelligence: \(SystemLLM.isAvailable() ? "available" : "unavailable")
          Ollama: \(state.ollamaBaseURL) — model \(orDash(state.ollamaModel))
          Cloud: \(state.cloudAPIURL) — model \(orDash(state.cloudModel)), \(keyState(Keychain.loadCloudLLMKey()))

        PERMISSIONS
          Microphone: \(micStatus())
          Speech: \(speechStatus())
          Accessibility: \(yesNo(state.hasAccessibilityPermission, "granted"))

        INPUT
          Shortcut: \(state.dictationShortcut.display) · Push-to-talk: \(state.pttKey.display)
          Paste after stop: \(onOff(state.pasteAfterStop)) · Overlay: \(state.overlayStyle.rawValue)

        FEATURES
          Meetings \(onOff(state.meetingsEnabled)) · Memory \(onOff(state.memoryEnabled)) (paused: \(onOff(state.memoryPaused))) · Reply assist \(onOff(state.replyAssistEnabled)) · MCP \(onOff(state.mcpAccessEnabled)) · Context-aware \(onOff(state.contextAwareDictationEnabled))

        MEETING DETECTION
        \(meetingDetectionLines(state).map { "  \($0)" }.joined(separator: "\n"))

        STORAGE
          History: \(storageLine(try? state.historyStore?.storageInfo()))
          Memory: \(storageLine(try? state.memoryStore?.storageInfo()))

        RECENT LOG (unified log, last 30 min — .debug entries are not retained by the system)
        """

        let lines = recentLogLines()
        out += lines.isEmpty ? "\n  (nothing logged in this window)" : "\n  " + lines.joined(separator: "\n  ")

        // Degraded features, if any. Omitted entirely when healthy — a wall of
        // zeroes would be noise in something people paste into issues.
        let degraded = Degradation.debugSummary()
        if !degraded.isEmpty {
            out += "\n\nDEGRADED\n" + degraded.map { "  \($0)" }.joined(separator: "\n")
        }
        return out
    }

    /// What meeting detection can see right now.
    ///
    /// This exists because the CLI diagnostic can't answer the question when it
    /// matters. A binary spawned from a shell makes the TERMINAL the responsible
    /// process for TCC, so its accessibility reads all come back empty; and a
    /// call that went undetected is over by the time anyone opens a terminal.
    /// Copy Debug Info runs inside the app, which holds the grant, and is one
    /// click during the call itself.
    ///
    /// Bundle IDs, pids and verdicts only — never window titles or URLs, per
    /// this file's standing rule. "meeting page: no" could in principle mean
    /// the accessibility read returned nothing rather than "not a meeting", but
    /// the PERMISSIONS section directly above already says whether Accessibility
    /// is granted, so no URL needs printing to tell those apart.
    @MainActor private static func meetingDetectionLines(_ state: AppState) -> [String] {
        var lines = ["Watcher: \(state.meetingWatcherState)"]

        let processes = AudioProcesses.capturingInput()
        if processes.isEmpty {
            lines.append("Mic held by: nothing right now")
        }
        for process in processes {
            let base = CallDetection.callAppBundleID(forAudioBundleID: process.bundleID)
            let verdict: String
            if CallDetection.isOwnProcess(process.bundleID) {
                verdict = "OmWhisper itself (excluded by design)"
            } else if let base {
                verdict = CallDetection.callerApps[base] ?? base
            } else {
                verdict = "not a known call app — add to callerApps if it is one"
            }
            lines.append("Mic held by: \(process.bundleID) (pid \(process.pid)) → \(verdict)")

            if let base, BrowserURL.isBrowser(base) {
                let pid = CallDetection.owningPID(baseBundleID: base) ?? process.pid
                // Not yesNo(_:"yes") — that negates to "not yes", the same trap
                // keyState exists for.
                let isMeeting = CallDetection.hasMeetingPage(pid: pid, bundleID: base)
                lines.append("  browser — meeting page: \(isMeeting ? "yes" : "no")")
            }
        }

        if let call = CallDetection.activeCall() {
            lines.append("Detected call: \(call.name) (pid \(call.pid))")
        } else {
            lines.append("Detected call: none")
        }
        return lines
    }

    // MARK: Small formatters

    private static func yesNo(_ value: Bool, _ label: String) -> String {
        value ? label : "not \(label)"
    }

    /// Whether a key exists — never the key. Its own formatter because
    /// yesNo(_:"key saved") negates to "not key saved".
    private static func keyState(_ key: String?) -> String {
        key == nil ? "no key" : "key saved"
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static func orDash(_ value: String) -> String {
        value.isEmpty ? "—" : value
    }

    private static func storageLine(_ info: (count: Int, bytes: Int64)??) -> String {
        guard let info = info.flatMap({ $0 }) else { return "unavailable" }
        return "\(info.count) rows, \(ByteCountFormatter.string(fromByteCount: info.bytes, countStyle: .file))"
    }

    private static func machineArchitecture() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafeBytes(of: &sysinfo.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    private static func micStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unknown"
        }
    }

    private static func speechStatus() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: "authorized"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unknown"
        }
    }
}
