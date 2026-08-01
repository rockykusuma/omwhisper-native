//
//  VisibleWindowsTests.swift
//  omwhisper-nativeTests
//
//  Pure selection logic for multi-display capture. The display layout used
//  here is the real one this feature was built for: a 1920x1080 main display
//  at the origin and a 2056x1290 display to its LEFT, at negative x.
//

import CoreGraphics
import Testing
@testable import OmWhisper

struct VisibleWindowsTests {
    private let mainDisplay = VisibleWindows.Display(
        id: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let secondDisplay = VisibleWindows.Display(
        id: 2, bounds: CGRect(x: -2056, y: 0, width: 2056, height: 1290))

    private func window(
        _ id: CGWindowID, pid: pid_t = 100,
        x: CGFloat, y: CGFloat = 0, w: CGFloat = 1200, h: CGFloat = 800,
        layer: Int = 0
    ) -> VisibleWindows.Descriptor {
        VisibleWindows.Descriptor(
            windowID: id, pid: pid,
            bounds: CGRect(x: x, y: y, width: w, height: h), layer: layer)
    }

    @Test func assignsWindowOnNegativeOriginDisplay() {
        let onSecond = window(1, x: -2000)
        #expect(VisibleWindows.display(containing: onSecond.bounds,
                                       in: [mainDisplay, secondDisplay]) == 2)
        let onMain = window(2, x: 100)
        #expect(VisibleWindows.display(containing: onMain.bounds,
                                       in: [mainDisplay, secondDisplay]) == 1)
    }

    @Test func picksFrontmostOnEachOtherDisplay() {
        let focused = window(1, x: 0)
        let onSecond = window(2, pid: 200, x: -2000)
        let selected = VisibleWindows.select(
            windows: [focused, onSecond],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected == [onSecond])
    }

    @Test func singleDisplaySelectsNothingExtra() {
        let focused = window(1, x: 0)
        let selected = VisibleWindows.select(
            windows: [focused], displays: [mainDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }

    @Test func skipsOccludedWindowOnSameDisplay() {
        // Front-to-back order, both on the second display: only the front one.
        let front = window(2, pid: 200, x: -2000)
        let behind = window(3, pid: 300, x: -1900)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), front, behind],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected == [front])
    }

    @Test func filtersNonZeroLayer() {
        let panel = window(2, pid: 200, x: -2000, layer: 25)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), panel],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }

    @Test func filtersUndersizedWindows() {
        let palette = window(2, pid: 200, x: -2000, w: 120, h: 90)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), palette],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }

    @Test func neverSelectsOurOwnWindows() {
        let ours = window(2, pid: 999, x: -2000)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), ours],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }

    @Test func withNoFocusedDisplayPicksFrontmostOnEvery() {
        let onMain = window(1, x: 0)
        let onSecond = window(2, pid: 200, x: -2000)
        let selected = VisibleWindows.select(
            windows: [onMain, onSecond],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: nil, ownPID: 999)
        #expect(selected == [onMain, onSecond])
    }

    @Test func ignoresWindowsOnNoKnownDisplay() {
        // A window entirely off every display (e.g. a just-disconnected monitor).
        let orphan = window(2, pid: 200, x: 9000, y: 9000)
        let selected = VisibleWindows.select(
            windows: [window(1, x: 0), orphan],
            displays: [mainDisplay, secondDisplay],
            focusedDisplayID: 1, ownPID: 999)
        #expect(selected.isEmpty)
    }
}
