// IconGen.swift — renders a 1024×1024 KITT-spectrum app icon PNG.
// Build:  swiftc -O Tools/IconGen.swift -o /tmp/icongen && /tmp/icongen out.png
// Draws a dark squircle with a center-out symmetric red KITT scanner spectrum.

import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("ctx") }

func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

// --- Rounded-rect (squircle-ish) background ---------------------------------
// macOS Big Sur icon grid: art inset with a continuous-corner rounded rect.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let corner: CGFloat = rect.width * 0.225
let bgPath = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
// Vertical gradient: near-black bottom → dark charcoal top.
let bgGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [col(0.13, 0.13, 0.15), col(0.04, 0.04, 0.05)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])

// Subtle radial red ambient glow behind the bars.
let ambient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [col(0.55, 0.04, 0.04, 0.55), col(0.0, 0.0, 0.0, 0.0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(ambient,
    startCenter: CGPoint(x: S/2, y: S/2), startRadius: 0,
    endCenter: CGPoint(x: S/2, y: S/2), endRadius: rect.width * 0.55, options: [])
ctx.restoreGState()

// --- KITT scanner bars: symmetric center-out spectrum -----------------------
// Heights peak at center, falling toward the edges, like the app's render.
let nHalf = 7                       // bars on each side of center (+1 center)
let total = nHalf * 2 + 1
let band = rect.width * 0.80
let barGap = band / CGFloat(total)
let barW = barGap * 0.52
let cx = S / 2
let cy = S / 2
let maxH = rect.height * 0.46

// envelope: 1.0 at center, smoothly decaying outward
func envelope(_ i: Int) -> CGFloat {
    let d = CGFloat(abs(i)) / CGFloat(nHalf)        // 0..1
    let e = pow(cos(d * .pi / 2), 1.35)             // smooth shoulder
    // a little jitter so it reads like live audio, deterministic
    let j = 0.86 + 0.14 * sin(CGFloat(i) * 1.7 + 0.5)
    return max(0.12, e * j)
}

ctx.setShadow(offset: .zero, blur: 34, color: col(1.0, 0.12, 0.12, 0.9))
ctx.setBlendMode(.normal)

for i in -nHalf...nHalf {
    let h = maxH * envelope(i)
    let x = cx + CGFloat(i) * barGap - barW / 2
    let r = CGRect(x: x, y: cy - h, width: barW, height: h * 2)
    let cap = barW / 2
    let p = CGPath(roundedRect: r, cornerWidth: cap, cornerHeight: cap, transform: nil)

    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    // Vertical red gradient: hot near center line, deeper red at the tips.
    let g = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [col(0.45, 0.0, 0.0), col(1.0, 0.20, 0.16),
                 col(1.0, 0.55, 0.40), col(1.0, 0.20, 0.16), col(0.45, 0.0, 0.0)] as CFArray,
        locations: [0, 0.42, 0.5, 0.58, 1]
    )!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
    ctx.restoreGState()
}

// Bright center scan line accent.
ctx.setShadow(offset: .zero, blur: 24, color: col(1.0, 0.3, 0.3, 0.9))
ctx.setFillColor(col(1.0, 0.85, 0.8, 0.9))
let glowH = maxH * envelope(0) * 2
let gl = CGRect(x: cx - barW/2, y: cy - glowH/2, width: barW, height: glowH)
ctx.addPath(CGPath(roundedRect: gl, cornerWidth: barW/2, cornerHeight: barW/2, transform: nil))
ctx.fillPath()

// --- Thin inner stroke for crisp edge ---------------------------------------
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.addPath(bgPath)
ctx.setStrokeColor(col(1, 1, 1, 0.06))
ctx.setLineWidth(3)
ctx.strokePath()

// --- Write PNG --------------------------------------------------------------
guard let img = ctx.makeImage() else { fatalError("img") }
let rep = NSBitmapImageRep(cgImage: img)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: out))
print("✓ wrote \(out)")
