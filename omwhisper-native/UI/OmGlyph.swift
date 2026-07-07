//
//  OmGlyph.swift
//  OmWhisper
//
//  The ॐ mark as a vector Path — NOT a font glyph. Font rendering of U+0950
//  varies by machine (fallback substitution, hinting differences); the brand
//  mark must be pixel-identical everywhere. This is a one-time CoreText
//  extraction of the real U+0950 outline from the system "Devanagari Sangam
//  MN" font (CTFontCreatePathForGlyph, resolved glyph id 191, 1000pt em),
//  baked as static geometry below — no runtime font lookup, ever.
//
//  A Path (not an Image) is required, not just preferred: the overlay's
//  warming stroke-draw needs trim(from:to:), and its luminance interpolation
//  is a fill/tint — both need vector geometry. See docs/OVERLAY_SPEC.md §5.3/§5.4.
//

import SwiftUI

struct OmGlyph: Shape {
    /// Font-space bounding box at the 1000pt extraction size (y-up, CoreText convention).
    private static let bbox = CGRect(x: 33.203125, y: 66.89453125, width: 819.3359375, height: 809.5703125)

    func path(in rect: CGRect) -> Path {
        var raw = Path()
        // --- BEGIN PATH COMMANDS (font-space, y-up, 1000pt em) ---
        raw.move(to: CGPoint(x: 216.309, y: 410.645))
        raw.addQuadCurve(to: CGPoint(x: 258.545, y: 418.457), control: CGPoint(x: 235.840, y: 412.598))
        raw.addQuadCurve(to: CGPoint(x: 300.781, y: 435.303), control: CGPoint(x: 281.250, y: 424.316))
        raw.addQuadCurve(to: CGPoint(x: 333.252, y: 462.158), control: CGPoint(x: 320.312, y: 446.289))
        raw.addQuadCurve(to: CGPoint(x: 346.191, y: 500.000), control: CGPoint(x: 346.191, y: 478.027))
        raw.addQuadCurve(to: CGPoint(x: 338.867, y: 530.762), control: CGPoint(x: 346.191, y: 518.066))
        raw.addQuadCurve(to: CGPoint(x: 321.045, y: 551.025), control: CGPoint(x: 331.543, y: 543.457))
        raw.addQuadCurve(to: CGPoint(x: 299.072, y: 562.012), control: CGPoint(x: 310.547, y: 558.594))
        raw.addQuadCurve(to: CGPoint(x: 279.297, y: 565.430), control: CGPoint(x: 287.598, y: 565.430))
        raw.addQuadCurve(to: CGPoint(x: 255.371, y: 563.477), control: CGPoint(x: 268.066, y: 565.430))
        raw.addQuadCurve(to: CGPoint(x: 229.492, y: 554.199), control: CGPoint(x: 242.676, y: 561.523))
        raw.addQuadCurve(to: CGPoint(x: 202.637, y: 532.715), control: CGPoint(x: 216.309, y: 546.875))
        raw.addQuadCurve(to: CGPoint(x: 176.270, y: 494.629), control: CGPoint(x: 188.965, y: 518.555))
        raw.addLine(to: CGPoint(x: 117.188, y: 521.484))
        raw.addQuadCurve(to: CGPoint(x: 138.428, y: 557.373), control: CGPoint(x: 125.000, y: 538.086))
        raw.addQuadCurve(to: CGPoint(x: 171.387, y: 593.262), control: CGPoint(x: 151.855, y: 576.660))
        raw.addQuadCurve(to: CGPoint(x: 217.285, y: 621.094), control: CGPoint(x: 190.918, y: 609.863))
        raw.addQuadCurve(to: CGPoint(x: 276.855, y: 632.324), control: CGPoint(x: 243.652, y: 632.324))
        raw.addQuadCurve(to: CGPoint(x: 327.637, y: 624.023), control: CGPoint(x: 303.223, y: 632.324))
        raw.addQuadCurve(to: CGPoint(x: 370.850, y: 599.121), control: CGPoint(x: 352.051, y: 615.723))
        raw.addQuadCurve(to: CGPoint(x: 401.123, y: 557.861), control: CGPoint(x: 389.648, y: 582.520))
        raw.addQuadCurve(to: CGPoint(x: 412.598, y: 500.488), control: CGPoint(x: 412.598, y: 533.203))
        raw.addQuadCurve(to: CGPoint(x: 399.414, y: 442.871), control: CGPoint(x: 412.598, y: 467.285))
        raw.addQuadCurve(to: CGPoint(x: 361.816, y: 400.879), control: CGPoint(x: 386.230, y: 418.457))
        raw.addLine(to: CGPoint(x: 374.512, y: 397.949))
        raw.addQuadCurve(to: CGPoint(x: 421.143, y: 383.789), control: CGPoint(x: 402.344, y: 393.555))
        raw.addQuadCurve(to: CGPoint(x: 454.834, y: 364.258), control: CGPoint(x: 439.941, y: 374.023))
        raw.addQuadCurve(to: CGPoint(x: 483.154, y: 347.168), control: CGPoint(x: 469.727, y: 354.492))
        raw.addQuadCurve(to: CGPoint(x: 513.184, y: 339.844), control: CGPoint(x: 496.582, y: 339.844))
        raw.addQuadCurve(to: CGPoint(x: 535.400, y: 348.389), control: CGPoint(x: 526.855, y: 339.844))
        raw.addQuadCurve(to: CGPoint(x: 549.805, y: 370.850), control: CGPoint(x: 543.945, y: 356.934))
        raw.addQuadCurve(to: CGPoint(x: 560.059, y: 402.344), control: CGPoint(x: 555.664, y: 384.766))
        raw.addQuadCurve(to: CGPoint(x: 569.824, y: 438.477), control: CGPoint(x: 564.453, y: 419.922))
        raw.addQuadCurve(to: CGPoint(x: 583.252, y: 474.609), control: CGPoint(x: 575.195, y: 457.031))
        raw.addQuadCurve(to: CGPoint(x: 604.736, y: 506.104), control: CGPoint(x: 591.309, y: 492.188))
        raw.addQuadCurve(to: CGPoint(x: 637.939, y: 528.564), control: CGPoint(x: 618.164, y: 520.020))
        raw.addQuadCurve(to: CGPoint(x: 686.523, y: 537.109), control: CGPoint(x: 657.715, y: 537.109))
        raw.addQuadCurve(to: CGPoint(x: 739.014, y: 528.809), control: CGPoint(x: 715.332, y: 537.109))
        raw.addQuadCurve(to: CGPoint(x: 781.250, y: 506.104), control: CGPoint(x: 762.695, y: 520.508))
        raw.addQuadCurve(to: CGPoint(x: 813.232, y: 472.656), control: CGPoint(x: 799.805, y: 491.699))
        raw.addQuadCurve(to: CGPoint(x: 835.449, y: 432.373), control: CGPoint(x: 826.660, y: 453.613))
        raw.addQuadCurve(to: CGPoint(x: 848.389, y: 388.916), control: CGPoint(x: 844.238, y: 411.133))
        raw.addQuadCurve(to: CGPoint(x: 852.539, y: 346.191), control: CGPoint(x: 852.539, y: 366.699))
        raw.addQuadCurve(to: CGPoint(x: 842.285, y: 268.066), control: CGPoint(x: 852.539, y: 302.246))
        raw.addQuadCurve(to: CGPoint(x: 814.697, y: 210.205), control: CGPoint(x: 832.031, y: 233.887))
        raw.addQuadCurve(to: CGPoint(x: 774.658, y: 174.316), control: CGPoint(x: 797.363, y: 186.523))
        raw.addQuadCurve(to: CGPoint(x: 727.051, y: 162.109), control: CGPoint(x: 751.953, y: 162.109))
        raw.addQuadCurve(to: CGPoint(x: 688.721, y: 167.725), control: CGPoint(x: 706.543, y: 162.109))
        raw.addQuadCurve(to: CGPoint(x: 656.006, y: 182.861), control: CGPoint(x: 670.898, y: 173.340))
        raw.addQuadCurve(to: CGPoint(x: 629.150, y: 205.322), control: CGPoint(x: 641.113, y: 192.383))
        raw.addQuadCurve(to: CGPoint(x: 608.398, y: 232.422), control: CGPoint(x: 617.188, y: 218.262))
        raw.addLine(to: CGPoint(x: 641.602, y: 273.438))
        raw.addQuadCurve(to: CGPoint(x: 653.320, y: 258.301), control: CGPoint(x: 646.484, y: 266.113))
        raw.addQuadCurve(to: CGPoint(x: 669.189, y: 243.896), control: CGPoint(x: 660.156, y: 250.488))
        raw.addQuadCurve(to: CGPoint(x: 689.209, y: 233.154), control: CGPoint(x: 678.223, y: 237.305))
        raw.addQuadCurve(to: CGPoint(x: 713.379, y: 229.004), control: CGPoint(x: 700.195, y: 229.004))
        raw.addQuadCurve(to: CGPoint(x: 742.432, y: 238.281), control: CGPoint(x: 729.004, y: 229.004))
        raw.addQuadCurve(to: CGPoint(x: 765.381, y: 263.672), control: CGPoint(x: 755.859, y: 247.559))
        raw.addQuadCurve(to: CGPoint(x: 780.273, y: 301.758), control: CGPoint(x: 774.902, y: 279.785))
        raw.addQuadCurve(to: CGPoint(x: 785.645, y: 349.609), control: CGPoint(x: 785.645, y: 323.730))
        raw.addQuadCurve(to: CGPoint(x: 778.564, y: 398.193), control: CGPoint(x: 785.645, y: 375.977))
        raw.addQuadCurve(to: CGPoint(x: 758.545, y: 436.523), control: CGPoint(x: 771.484, y: 420.410))
        raw.addQuadCurve(to: CGPoint(x: 727.295, y: 461.670), control: CGPoint(x: 745.605, y: 452.637))
        raw.addQuadCurve(to: CGPoint(x: 687.012, y: 470.703), control: CGPoint(x: 708.984, y: 470.703))
        raw.addQuadCurve(to: CGPoint(x: 651.611, y: 462.158), control: CGPoint(x: 665.039, y: 470.703))
        raw.addQuadCurve(to: CGPoint(x: 630.127, y: 439.697), control: CGPoint(x: 638.184, y: 453.613))
        raw.addQuadCurve(to: CGPoint(x: 617.676, y: 408.203), control: CGPoint(x: 622.070, y: 425.781))
        raw.addQuadCurve(to: CGPoint(x: 609.619, y: 372.070), control: CGPoint(x: 613.281, y: 390.625))
        raw.addQuadCurve(to: CGPoint(x: 601.318, y: 335.938), control: CGPoint(x: 605.957, y: 353.516))
        raw.addQuadCurve(to: CGPoint(x: 588.135, y: 304.443), control: CGPoint(x: 596.680, y: 318.359))
        raw.addQuadCurve(to: CGPoint(x: 565.430, y: 281.982), control: CGPoint(x: 579.590, y: 290.527))
        raw.addQuadCurve(to: CGPoint(x: 528.320, y: 273.438), control: CGPoint(x: 551.270, y: 273.438))
        raw.addQuadCurve(to: CGPoint(x: 510.254, y: 276.367), control: CGPoint(x: 518.066, y: 273.438))
        raw.addQuadCurve(to: CGPoint(x: 495.605, y: 284.180), control: CGPoint(x: 502.441, y: 279.297))
        raw.addQuadCurve(to: CGPoint(x: 482.178, y: 295.410), control: CGPoint(x: 488.770, y: 289.062))
        raw.addQuadCurve(to: CGPoint(x: 467.773, y: 308.105), control: CGPoint(x: 475.586, y: 301.758))
        raw.addQuadCurve(to: CGPoint(x: 476.318, y: 273.926), control: CGPoint(x: 473.145, y: 292.480))
        raw.addQuadCurve(to: CGPoint(x: 479.492, y: 233.398), control: CGPoint(x: 479.492, y: 255.371))
        raw.addQuadCurve(to: CGPoint(x: 468.750, y: 173.340), control: CGPoint(x: 479.492, y: 203.125))
        raw.addQuadCurve(to: CGPoint(x: 436.523, y: 119.873), control: CGPoint(x: 458.008, y: 143.555))
        raw.addQuadCurve(to: CGPoint(x: 382.568, y: 81.543), control: CGPoint(x: 415.039, y: 96.191))
        raw.addQuadCurve(to: CGPoint(x: 307.129, y: 66.895), control: CGPoint(x: 350.098, y: 66.895))
        raw.addQuadCurve(to: CGPoint(x: 235.352, y: 78.857), control: CGPoint(x: 268.555, y: 66.895))
        raw.addQuadCurve(to: CGPoint(x: 174.072, y: 111.084), control: CGPoint(x: 202.148, y: 90.820))
        raw.addQuadCurve(to: CGPoint(x: 123.291, y: 157.471), control: CGPoint(x: 145.996, y: 131.348))
        raw.addQuadCurve(to: CGPoint(x: 82.764, y: 211.914), control: CGPoint(x: 100.586, y: 183.594))
        raw.addQuadCurve(to: CGPoint(x: 52.490, y: 268.799), control: CGPoint(x: 64.941, y: 240.234))
        raw.addQuadCurve(to: CGPoint(x: 33.203, y: 322.266), control: CGPoint(x: 40.039, y: 297.363))
        raw.addLine(to: CGPoint(x: 87.402, y: 354.980))
        raw.addQuadCurve(to: CGPoint(x: 128.418, y: 265.381), control: CGPoint(x: 105.957, y: 306.152))
        raw.addQuadCurve(to: CGPoint(x: 178.223, y: 195.312), control: CGPoint(x: 150.879, y: 224.609))
        raw.addQuadCurve(to: CGPoint(x: 237.793, y: 149.658), control: CGPoint(x: 205.566, y: 166.016))
        raw.addQuadCurve(to: CGPoint(x: 307.617, y: 133.301), control: CGPoint(x: 270.020, y: 133.301))
        raw.addQuadCurve(to: CGPoint(x: 354.248, y: 142.822), control: CGPoint(x: 334.473, y: 133.301))
        raw.addQuadCurve(to: CGPoint(x: 386.963, y: 167.725), control: CGPoint(x: 374.023, y: 152.344))
        raw.addQuadCurve(to: CGPoint(x: 406.250, y: 202.637), control: CGPoint(x: 399.902, y: 183.105))
        raw.addQuadCurve(to: CGPoint(x: 412.598, y: 241.699), control: CGPoint(x: 412.598, y: 222.168))
        raw.addQuadCurve(to: CGPoint(x: 400.146, y: 297.363), control: CGPoint(x: 412.598, y: 274.902))
        raw.addQuadCurve(to: CGPoint(x: 367.676, y: 333.252), control: CGPoint(x: 387.695, y: 319.824))
        raw.addQuadCurve(to: CGPoint(x: 322.266, y: 352.539), control: CGPoint(x: 347.656, y: 346.680))
        raw.addQuadCurve(to: CGPoint(x: 270.996, y: 358.398), control: CGPoint(x: 296.875, y: 358.398))
        raw.addQuadCurve(to: CGPoint(x: 250.488, y: 357.666), control: CGPoint(x: 260.742, y: 358.398))
        raw.addQuadCurve(to: CGPoint(x: 230.469, y: 354.980), control: CGPoint(x: 240.234, y: 356.934))
        raw.closeSubpath()
        raw.move(to: CGPoint(x: 533.203, y: 621.094))
        raw.addQuadCurve(to: CGPoint(x: 471.680, y: 628.906), control: CGPoint(x: 500.000, y: 621.094))
        raw.addQuadCurve(to: CGPoint(x: 419.189, y: 651.123), control: CGPoint(x: 443.359, y: 636.719))
        raw.addQuadCurve(to: CGPoint(x: 373.779, y: 686.035), control: CGPoint(x: 395.020, y: 665.527))
        raw.addQuadCurve(to: CGPoint(x: 333.008, y: 732.422), control: CGPoint(x: 352.539, y: 706.543))
        raw.addLine(to: CGPoint(x: 375.488, y: 779.785))
        raw.addQuadCurve(to: CGPoint(x: 384.766, y: 766.846), control: CGPoint(x: 378.418, y: 775.391))
        raw.addQuadCurve(to: CGPoint(x: 400.879, y: 748.047), control: CGPoint(x: 391.113, y: 758.301))
        raw.addQuadCurve(to: CGPoint(x: 423.828, y: 727.295), control: CGPoint(x: 410.645, y: 737.793))
        raw.addQuadCurve(to: CGPoint(x: 453.613, y: 708.008), control: CGPoint(x: 437.012, y: 716.797))
        raw.addQuadCurve(to: CGPoint(x: 489.990, y: 693.604), control: CGPoint(x: 470.215, y: 699.219))
        raw.addQuadCurve(to: CGPoint(x: 533.203, y: 687.988), control: CGPoint(x: 509.766, y: 687.988))
        raw.addQuadCurve(to: CGPoint(x: 576.416, y: 693.604), control: CGPoint(x: 556.641, y: 687.988))
        raw.addQuadCurve(to: CGPoint(x: 612.793, y: 708.008), control: CGPoint(x: 596.191, y: 699.219))
        raw.addQuadCurve(to: CGPoint(x: 642.578, y: 727.295), control: CGPoint(x: 629.395, y: 716.797))
        raw.addQuadCurve(to: CGPoint(x: 665.527, y: 748.047), control: CGPoint(x: 655.762, y: 737.793))
        raw.addQuadCurve(to: CGPoint(x: 681.641, y: 766.846), control: CGPoint(x: 675.293, y: 758.301))
        raw.addQuadCurve(to: CGPoint(x: 690.918, y: 779.785), control: CGPoint(x: 687.988, y: 775.391))
        raw.addLine(to: CGPoint(x: 733.887, y: 732.422))
        raw.addQuadCurve(to: CGPoint(x: 693.115, y: 686.035), control: CGPoint(x: 714.355, y: 706.543))
        raw.addQuadCurve(to: CGPoint(x: 647.461, y: 651.123), control: CGPoint(x: 671.875, y: 665.527))
        raw.addQuadCurve(to: CGPoint(x: 594.727, y: 628.906), control: CGPoint(x: 623.047, y: 636.719))
        raw.addQuadCurve(to: CGPoint(x: 533.203, y: 621.094), control: CGPoint(x: 566.406, y: 621.094))
        raw.closeSubpath()
        raw.move(to: CGPoint(x: 475.586, y: 819.824))
        raw.addQuadCurve(to: CGPoint(x: 479.980, y: 841.797), control: CGPoint(x: 475.586, y: 831.543))
        raw.addQuadCurve(to: CGPoint(x: 492.188, y: 859.863), control: CGPoint(x: 484.375, y: 852.051))
        raw.addQuadCurve(to: CGPoint(x: 510.254, y: 872.070), control: CGPoint(x: 500.000, y: 867.676))
        raw.addQuadCurve(to: CGPoint(x: 532.227, y: 876.465), control: CGPoint(x: 520.508, y: 876.465))
        raw.addQuadCurve(to: CGPoint(x: 554.199, y: 872.070), control: CGPoint(x: 543.945, y: 876.465))
        raw.addQuadCurve(to: CGPoint(x: 572.266, y: 859.863), control: CGPoint(x: 564.453, y: 867.676))
        raw.addQuadCurve(to: CGPoint(x: 584.473, y: 841.797), control: CGPoint(x: 580.078, y: 852.051))
        raw.addQuadCurve(to: CGPoint(x: 588.867, y: 819.824), control: CGPoint(x: 588.867, y: 831.543))
        raw.addQuadCurve(to: CGPoint(x: 584.473, y: 798.096), control: CGPoint(x: 588.867, y: 808.105))
        raw.addQuadCurve(to: CGPoint(x: 572.266, y: 780.273), control: CGPoint(x: 580.078, y: 788.086))
        raw.addQuadCurve(to: CGPoint(x: 554.199, y: 768.066), control: CGPoint(x: 564.453, y: 772.461))
        raw.addQuadCurve(to: CGPoint(x: 532.227, y: 763.672), control: CGPoint(x: 543.945, y: 763.672))
        raw.addQuadCurve(to: CGPoint(x: 510.254, y: 768.066), control: CGPoint(x: 520.508, y: 763.672))
        raw.addQuadCurve(to: CGPoint(x: 492.188, y: 780.273), control: CGPoint(x: 500.000, y: 772.461))
        raw.addQuadCurve(to: CGPoint(x: 479.980, y: 798.096), control: CGPoint(x: 484.375, y: 788.086))
        raw.addQuadCurve(to: CGPoint(x: 475.586, y: 819.824), control: CGPoint(x: 475.586, y: 808.105))
        raw.closeSubpath()
        // --- END PATH COMMANDS ---

        // Fit to `rect`: uniform scale (preserve aspect ratio) + y-flip (font
        // space is y-up; SwiftUI Path space is y-down) + center. Verified by
        // direct substitution at all four bbox extremes.
        let scale = min(rect.width / Self.bbox.width, rect.height / Self.bbox.height)
        let scaledWidth = Self.bbox.width * scale
        let scaledHeight = Self.bbox.height * scale
        let xOffset = rect.minX + (rect.width - scaledWidth) / 2
        let yOffset = rect.minY + (rect.height - scaledHeight) / 2
        let transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: -scale,
            tx: xOffset - scale * Self.bbox.minX,
            ty: yOffset + scaledHeight + scale * Self.bbox.minY
        )
        return raw.applying(transform)
    }
}

#Preview {
    ZStack {
        Color.black
        OmGlyph()
            .fill(.white)
            .frame(width: 44, height: 44)
    }
    .frame(width: 200, height: 200)
}
