//
//  MeetingDetectionDiagnostics.swift
//  OmWhisper
//
//  DEBUG-only: prints what meeting detection actually sees. Exists because a
//  unit test asserting "something is capturing input" passes on a silent CI
//  runner and proves nothing -- the only real check is running this during a
//  real call. Same stdout-as-evidence-channel convention as MeetingDiagnostics
//  and MeetingAIDiagnostics.
//
//  Run: OmWhisper-Dev.app/Contents/MacOS/OmWhisper-Dev --diagnose-meeting-detection
//

#if DEBUG
import AppKit
import Foundation

nonisolated enum MeetingDetectionDiagnostics {
    static func run() {
        print("=== meeting detection ===")
        let processes = AudioProcesses.capturingInput()
        print("processes capturing microphone input: \(processes.count)")
        for process in processes {
            let base = CallDetection.callAppBundleID(forAudioBundleID: process.bundleID)
            let own = CallDetection.isOwnProcess(process.bundleID)
            print("  \(process.bundleID) pid=\(process.pid) own=\(own) callApp=\(base ?? "-")")
            if let base, BrowserURL.isBrowser(base) {
                let pid = CallDetection.owningPID(baseBundleID: base) ?? process.pid
                print("    browser: meetingPage=\(CallDetection.hasMeetingPage(pid: pid, bundleID: base))")
            }
        }
        if processes.isEmpty {
            print("  <none> — nothing has the mic open right now")
        }
        if let call = CallDetection.activeCall() {
            print("activeCall -> \(call.name) pid=\(call.pid)")
            print("  callWindowTitle -> \(CallDetection.callWindowTitle(pid: call.pid, appName: call.name) ?? "<none>")")
        } else {
            print("activeCall -> nil")
        }

        // Every running browser, whether or not it holds the mic. The gate
        // itself is only reachable while a browser is capturing input, and no
        // ordinary page does that -- a YouTube video plays audio, it does not
        // record any -- so without this the browser rule could only be checked
        // by joining a real call, and its negative case not at all.
        // Without this line a "<no URL read>" below is ambiguous between "this
        // process has no Accessibility grant" and "the browser did not expose
        // a URL", which need entirely different fixes.
        print("--- browser page check (independent of the mic) ---")
        print("  AXIsProcessTrusted = \(AXIsProcessTrusted())")
        if !AXIsProcessTrusted() {
            print("  ⚠︎ no Accessibility grant — every URL below reads as <no URL read>")
            print("    regardless of the page. Spawning this binary from a shell makes the")
            print("    TERMINAL the responsible process for TCC, so the app's own grant does")
            print("    not apply. Grant the terminal Accessibility, or read these lines only")
            print("    as 'unknown'. The CoreAudio section above needs no permission and is")
            print("    unaffected.")
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, BrowserURL.isBrowser(bundleID) else { continue }
            let pid = app.processIdentifier
            // The resolved domain, not just the verdict: a bare
            // "meetingPage=false" reads the same whether the page genuinely is
            // not a meeting or the AX read returned nothing at all, and those
            // need different fixes. Domain only -- the full URL is not ours to
            // print even in a debug tool.
            let domain = resolvedDomain(pid: pid, bundleID: bundleID) ?? "<no URL read>"
            print("  \(bundleID) pid=\(pid) domain=\(domain) "
                  + "meetingPage=\(CallDetection.hasMeetingPage(pid: pid, bundleID: bundleID))")
        }
    }

    private static func resolvedDomain(pid: pid_t, bundleID: String) -> String? {
        let appElement = AX.appElement(pid: pid)
        guard let window = ScreenContextReader.copyAttribute(appElement, kAXFocusedWindowAttribute)
        else { return nil }
        let windowElement = window as! AXUIElement
        guard let url = BrowserURL.url(bundleId: bundleID, window: windowElement) else { return nil }
        return BrowserURL.domain(of: url) ?? url
    }
}
#endif
