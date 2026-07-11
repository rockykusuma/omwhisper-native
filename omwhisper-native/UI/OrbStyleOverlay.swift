//
//  OrbStyleOverlay.swift
//  OmWhisper
//
//  The compact overlay style (OVERLAY_SPEC §3): just the orb, no label or text.
//

import SwiftUI

struct OrbStyleOverlay: View {
    let appState: AppState
    let isVisible: Bool

    var body: some View {
        ZStack {
            // Gate the ticking Canvas on visibility so it stops when the panel is
            // ordered out (spec §10), matching FullStyleOverlay's orbZone.
            if isVisible {
                OmOrbView(appState: appState)
                    .frame(width: 84, height: 84)
            }
        }
        .frame(width: 96, height: 96)
        .background(Color.omBackground.opacity(0.92), in: Circle())
        .overlay(Circle().strokeBorder(Color.omBorder.opacity(0.35), lineWidth: 1))
    }
}
