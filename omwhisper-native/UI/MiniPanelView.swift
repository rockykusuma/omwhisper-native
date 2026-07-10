//
//  MiniPanelView.swift
//  OmWhisper
//
//  The menu-bar mini-panel (D3b): shown in an NSPopover on left-click of the
//  status item, right-click still shows the traditional NSMenu unchanged.
//  See docs/DESIGN_DIRECTION.md §3 and docs/hub-concept.html's minipanel
//  mockup. Rebuilt fresh on every open (AppDelegate.togglePopover) so it
//  always reflects current state -- same principle menuNeedsUpdate already
//  uses for the traditional menu.
//

import SwiftUI

/// Pure state->label mapping, extracted for direct testing.
nonisolated func miniPanelStateLine(for dictation: DictationState) -> String {
    switch dictation {
    case .idle: "Ready"
    case .starting: "Starting…"
    case .recording: "Listening…"
    case .finalizing: "Finishing…"
    }
}
