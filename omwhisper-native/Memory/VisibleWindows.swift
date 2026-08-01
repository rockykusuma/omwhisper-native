//
//  VisibleWindows.swift
//  OmWhisper
//
//  Which windows Memory should capture on a multi-display desk: the frontmost
//  normal window on each display OTHER than the focused one (the focused
//  window itself is captured by WindowSnapshotReader.captureFrontmost).
//
//  Occluded windows on the same display are deliberately skipped -- they are
//  listed as on-screen but you cannot see them, so they are not "what is in
//  front of me".
//
//  COORDINATE SPACE: every CGRect here is top-left-origin with y growing
//  downward -- the space CGWindowListCopyWindowInfo and CGDisplayBounds both
//  use. NSScreen.frame is bottom-left-origin and must never be mixed in.
//
//  nonisolated: CGWindowList is cross-process IPC with no MainActor affinity,
//  same rationale as ScreenContextReader.
//

import CoreGraphics
import Foundation

nonisolated enum VisibleWindows {
    struct Descriptor: Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let layer: Int
    }

    struct Display: Equatable {
        let id: CGDirectDisplayID
        let bounds: CGRect
    }

    /// Below this, a window is a palette, inspector or HUD rather than content
    /// worth indexing. ponytail: a constant, not a setting -- nobody tunes this.
    static let minimumWindowSize = CGSize(width: 300, height: 200)

    /// The display whose bounds contain the rect's centre. nil when none do,
    /// which happens for windows on a display that was just disconnected.
    static func display(containing bounds: CGRect, in displays: [Display]) -> CGDirectDisplayID? {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        return displays.first { $0.bounds.contains(centre) }?.id
    }

    /// Frontmost normal window on each display other than `focusedDisplayID`.
    ///
    /// `windows` MUST be in front-to-back order -- CGWindowListCopyWindowInfo's
    /// own ordering, which is what makes "first per display" mean "frontmost".
    static func select(
        windows: [Descriptor],
        displays: [Display],
        focusedDisplayID: CGDirectDisplayID?,
        ownPID: pid_t
    ) -> [Descriptor] {
        var covered: Set<CGDirectDisplayID> = []
        if let focusedDisplayID { covered.insert(focusedDisplayID) }

        var picked: [Descriptor] = []
        for window in windows {
            guard window.layer == 0,
                  window.pid != ownPID,
                  window.bounds.width >= minimumWindowSize.width,
                  window.bounds.height >= minimumWindowSize.height,
                  let displayID = display(containing: window.bounds, in: displays),
                  !covered.contains(displayID)
            else { continue }
            covered.insert(displayID)
            picked.append(window)
        }
        return picked
    }

    // MARK: - Enumeration (effectful)

    /// On-screen windows, front-to-back. Deliberately reads only the four keys
    /// that need NO permission -- kCGWindowName is gated behind Screen Recording
    /// and comes back empty without it, so titles come from AX instead.
    static func onScreen() -> [Descriptor] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return info.compactMap { entry in
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return Descriptor(windowID: windowID, pid: pid, bounds: bounds, layer: layer)
        }
    }

    /// Active displays in CGDisplayBounds' space -- the SAME top-left-origin
    /// space as the window bounds above. NSScreen.frame is not interchangeable.
    static func activeDisplays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { Display(id: $0, bounds: CGDisplayBounds($0)) }
    }
}
