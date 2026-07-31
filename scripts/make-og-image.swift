//
//  make-og-image.swift
//  OmWhisper — regenerates the website's Open Graph social card (1200×630).
//
//    swiftc -O scripts/make-og-image.swift omwhisper-native/UI/OmGlyph.swift \
//        -o /tmp/make-og-image && /tmp/make-og-image <out.png> [font-dir]
//
//  OmGlyph.swift is compiled in, same as make-app-icon.swift, so the ॐ on the
//  social card is the identical vector the app draws.
//
//  Typeface is DM Sans (the site's --font-sans) if TTFs are found in font-dir,
//  registered at runtime; otherwise it falls back to the system font. The card
//  is regenerated rarely, so fetching the font at generation time beats
//  committing a binary to the repo.
//

import AppKit
import SwiftUI

let ground = CGColor(srgbRed: 0x0A / 255, green: 0x0F / 255, blue: 0x0D / 255, alpha: 1)
let emerald = NSColor(srgbRed: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255, alpha: 1)
let mint = NSColor(srgbRed: 0x6E / 255, green: 0xE7 / 255, blue: 0xB7 / 255, alpha: 1)
let glyphInk = NSColor(srgbRed: 0xEA / 255, green: 0xFF / 255, blue: 0xF5 / 255, alpha: 1)
let dim = NSColor(srgbRed: 0x8F / 255, green: 0xA3 / 255, blue: 0xA0 / 255, alpha: 1)

let W: CGFloat = 1200, H: CGFloat = 630

func registerFonts(in dir: String) {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
    for f in files where f.hasSuffix(".ttf") {
        CTFontManagerRegisterFontsForURL(
            URL(fileURLWithPath: dir).appendingPathComponent(f) as CFURL, .process, nil)
    }
}

/// DM Sans at `size`, or the system font at the same weight if it isn't registered.
func brandFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let name = weight >= .bold ? "DMSans-Bold" : (weight >= .medium ? "DMSans-Medium" : "DMSans-Regular")
    return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
}

func draw(_ text: String, at p: CGPoint, font: NSFont, color: NSColor, tracking: CGFloat = 0) {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if tracking != 0 { attrs[.kern] = tracking }
    NSAttributedString(string: text, attributes: attrs).draw(at: p)
}

func width(_ text: String, font: NSFont, tracking: CGFloat = 0) -> CGFloat {
    var attrs: [NSAttributedString.Key: Any] = [.font: font]
    if tracking != 0 { attrs[.kern] = tracking }
    return NSAttributedString(string: text, attributes: attrs).size().width
}

/// Rounded-rect pill with a 1pt border, optionally filled.
func pill(_ rect: CGRect, radius: CGFloat, stroke: NSColor, fill: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    if let fill { fill.setFill(); path.fill() }
    stroke.setStroke(); path.lineWidth = 1; path.stroke()
}

@main
struct OGImageGenerator {
    static func main() {
        let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "og-image.png"
        if CommandLine.arguments.count > 2 { registerFonts(in: CommandLine.arguments[2]) }

        // Explicit bitmap rep, NOT NSImage.lockFocus: lockFocus honours the
        // display's backing scale, so the same script emitted 1200x630 on a
        // non-Retina machine and 2400x1260 here. Build output must not depend on
        // the monitor it was generated on.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let ctx = gctx.cgContext

        // Ground + a soft emerald bloom behind the mark, echoing the original card.
        ctx.setFillColor(ground)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let bloom = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [emerald.withAlphaComponent(0.16).cgColor, emerald.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1])!
        ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 1010, y: 315), startRadius: 0,
                               endCenter: CGPoint(x: 1010, y: 315), endRadius: 300, options: [])

        // ── Eyebrow pill ─────────────────────────────────────────────────────────────
        let eyebrow = "OPEN SOURCE · FREE · MACOS"
        let eyebrowFont = brandFont(15, weight: .bold)
        let eyebrowW = width(eyebrow, font: eyebrowFont, tracking: 1.2)
        pill(CGRect(x: 80, y: H - 178, width: eyebrowW + 54, height: 36), radius: 18,
             stroke: emerald.withAlphaComponent(0.45))
        ctx.setFillColor(emerald.cgColor)
        ctx.fillEllipse(in: CGRect(x: 100, y: H - 164, width: 8, height: 8))
        draw(eyebrow, at: CGPoint(x: 118, y: H - 170), font: eyebrowFont, color: emerald, tracking: 1.2)

        // ── Headline ─────────────────────────────────────────────────────────────────
        // "offline & private" was the old promise and is no longer true unconditionally
        // — 2.0's actual differentiator is that the choice is yours.
        let h1 = brandFont(66, weight: .bold)
        draw("Voice to text,", at: CGPoint(x: 78, y: H - 268), font: h1, color: .white)
        draw("your way.", at: CGPoint(x: 78, y: H - 348), font: h1, color: emerald)

        // ── Subhead ──────────────────────────────────────────────────────────────────
        let sub = brandFont(21, weight: .regular)
        draw("On-device by default — Apple Speech, Parakeet or Whisper.",
             at: CGPoint(x: 80, y: H - 400), font: sub, color: dim)
        draw("Bring a cloud key only if you want to.",
             at: CGPoint(x: 80, y: H - 432), font: sub, color: dim)

        // ── Feature pills ────────────────────────────────────────────────────────────
        let badgeFont = brandFont(15, weight: .medium)
        var bx: CGFloat = 80
        for label in ["On-Device by Default", "Apple Silicon", "Free Forever"] {
            let w = width(label, font: badgeFont) + 34
            pill(CGRect(x: bx, y: H - 500, width: w, height: 36), radius: 18,
                 stroke: emerald.withAlphaComponent(0.35))
            draw(label, at: CGPoint(x: bx + 17, y: H - 494), font: badgeFont, color: mint)
            bx += w + 12
        }

        // ── CTA ──────────────────────────────────────────────────────────────────────
        let ctaFont = brandFont(19, weight: .bold)
        let cta = "Download Free for Mac  ↓"
        let ctaW = width(cta, font: ctaFont) + 56
        let ctaRect = CGRect(x: 80, y: H - 578, width: ctaW, height: 58)
        let ctaPath = NSBezierPath(roundedRect: ctaRect, xRadius: 29, yRadius: 29)
        ctx.saveGState()
        ctaPath.addClip()
        let ctaGrad = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [emerald.cgColor, mint.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(ctaGrad, start: CGPoint(x: ctaRect.minX, y: ctaRect.maxY),
                               end: CGPoint(x: ctaRect.maxX, y: ctaRect.minY), options: [])
        ctx.restoreGState()
        draw(cta, at: CGPoint(x: ctaRect.minX + 28, y: ctaRect.minY + 17), font: ctaFont,
             color: NSColor(srgbRed: 0x04 / 255, green: 0x12 / 255, blue: 0x0C / 255, alpha: 1))

        // ── The mark ─────────────────────────────────────────────────────────────────
        let ringRect = CGRect(x: 900, y: 205, width: 220, height: 220)
        ctx.setStrokeColor(emerald.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: ringRect)

        ctx.saveGState()
        ctx.translateBy(x: 0, y: H)          // OmGlyph.path(in:) is written y-down
        ctx.scaleBy(x: 1, y: -1)
        let glyphSide: CGFloat = 132
        let glyphRect = CGRect(x: ringRect.midX - glyphSide / 2,
                               y: (H - ringRect.midY) - glyphSide / 2,
                               width: glyphSide, height: glyphSide)
        ctx.setShadow(offset: .zero, blur: 26, color: emerald.withAlphaComponent(0.55).cgColor)
        ctx.addPath(OmGlyph().path(in: glyphRect).cgPath)
        ctx.setFillColor(glyphInk.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // ── Domain ───────────────────────────────────────────────────────────────────
        let domainFont = brandFont(15, weight: .regular)
        draw("omwhisper.in", at: CGPoint(x: W - width("omwhisper.in", font: domainFont) - 60, y: 36),
             font: domainFont, color: dim.withAlphaComponent(0.7))

        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:])
        else { FileHandle.standardError.write("render failed\n".data(using: .utf8)!); exit(1) }
        try! png.write(to: URL(fileURLWithPath: outPath))
        print("wrote \(outPath) — \(Int(W))×\(Int(H)), DM Sans: \(NSFont(name: "DMSans-Bold", size: 12) != nil)")
    }
}
