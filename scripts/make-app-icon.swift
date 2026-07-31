//
//  make-app-icon.swift
//  OmWhisper — regenerates Assets.xcassets/AppIcon.appiconset from the real
//  committed OmGlyph vector path. Run it, don't hand-edit the PNGs:
//
//    swiftc -O scripts/make-app-icon.swift omwhisper-native/UI/OmGlyph.swift \
//        -o /tmp/make-app-icon && /tmp/make-app-icon <output-dir>
//
//  OmGlyph.swift is compiled in rather than the geometry being copied here, so
//  the icon can never drift from the mark the HUD and menu bar draw.
//

import AppKit
import SwiftUI

// Brand tokens (.claude/skills/omwhisper-design §1 — do not invent new ones).
let ground = CGColor(srgbRed: 0x0A / 255, green: 0x0F / 255, blue: 0x0D / 255, alpha: 1)
let emerald = CGColor(srgbRed: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255, alpha: 1)
let teal = CGColor(srgbRed: 0x2D / 255, green: 0xD4 / 255, blue: 0xBF / 255, alpha: 1)
let hairline = CGColor(srgbRed: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255, alpha: 0.35)

/// Apple's macOS icon grid: an 824×824 body centred in a 1024×1024 canvas
/// (100pt margins), corner radius 185.4. Everything below is expressed as a
/// fraction of that so any pixel size lands on the same proportions.
let bodyFraction: CGFloat = 824.0 / 1024.0
let radiusFraction: CGFloat = 185.4 / 1024.0
let glyphFraction: CGFloat = 0.50

func renderIcon(size: CGFloat) -> CGImage? {
    let pixels = Int(size)
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Flip to y-down so OmGlyph.path(in:) — written for SwiftUI — is correct.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // ponytail: a plain rounded rect at Apple's radius, not a true continuous
    // "squircle" (Apple's corners have continuous curvature). Indistinguishable
    // at icon sizes; reach for Icon Composer if pixel-exact geometry matters.
    let inset = size * (1 - bodyFraction) / 2
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * radiusFraction
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.addPath(squircle)
    ctx.setFillColor(ground)
    ctx.fillPath()

    // The faint emerald ring the original disc had, kept for continuity.
    ctx.addPath(squircle)
    ctx.setStrokeColor(hairline)
    ctx.setLineWidth(max(1, size * 0.005))
    ctx.strokePath()

    // Glyph: centred, nudged very slightly up — optically centred beats
    // mathematically centred for a mark with weight low in its box.
    let side = size * glyphFraction
    let glyphRect = CGRect(
        x: (size - side) / 2,
        y: (size - side) / 2 - size * 0.012,
        width: side, height: side)
    let glyph = OmGlyph().path(in: glyphRect).cgPath

    // Emerald glow, then the emerald->teal gradient fill at 135 degrees.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.035, color: emerald.copy(alpha: 0.55))
    ctx.addPath(glyph)
    ctx.setFillColor(emerald)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(glyph)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [emerald, teal] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: glyphRect.minX, y: glyphRect.minY),
        end: CGPoint(x: glyphRect.maxX, y: glyphRect.maxY),
        options: [])
    ctx.restoreGState()

    return ctx.makeImage()
}

@main
struct IconGenerator {
    static func main() throws {
        let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        for px in [16, 32, 64, 128, 256, 512, 1024] {
            guard let image = renderIcon(size: CGFloat(px)),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write("failed at \(px)px\n".data(using: .utf8)!)
                exit(1)
            }
            let url = URL(fileURLWithPath: outputDir).appendingPathComponent("icon_\(px).png")
            try data.write(to: url)
            print("wrote \(url.lastPathComponent)")
        }
    }
}
