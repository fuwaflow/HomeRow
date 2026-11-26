import AppKit
import Foundation

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconsetDir = root.appendingPathComponent("AppIcon.iconset")
let resourcesDir = root.appendingPathComponent("Resources")

try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    cg.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let inset = s * 0.0975
    let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = cardRect.width * 0.225
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)

    cg.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.02)
    shadow.shadowBlurRadius = s * 0.035
    shadow.set()
    NSColor.white.setFill()
    cardPath.fill()
    cg.restoreGState()

    cg.saveGState()
    cardPath.addClip()
    let topColor = NSColor(calibratedRed: 1.0, green: 0.420, blue: 0.545, alpha: 1.0)
    let bottomColor = NSColor(calibratedRed: 0.878, green: 0.271, blue: 0.482, alpha: 1.0)
    let gradient = NSGradient(starting: bottomColor, ending: topColor)!
    gradient.draw(in: cardRect, angle: 90)

    NSColor.white.withAlphaComponent(0.22).setStroke()
    cardPath.lineWidth = max(1.0, s * 0.015)
    cardPath.stroke()
    cg.restoreGState()

    let keyW = cardRect.width * 0.22
    let keyH = cardRect.width * 0.28
    let gap = cardRect.width * 0.045
    let totalW = keyW * 3 + gap * 2
    let startX = cardRect.midX - totalW / 2
    let keyY = cardRect.midY - keyH / 2
    let keyRadius = keyW * 0.22

    for i in 0..<3 {
        let kx = startX + CGFloat(i) * (keyW + gap)
        let kRect = CGRect(x: kx, y: keyY, width: keyW, height: keyH)

        let depthOffset = max(1.0, s * 0.018)
        let depthRect = CGRect(x: kx, y: keyY - depthOffset, width: keyW, height: keyH)
        let depthPath = NSBezierPath(roundedRect: depthRect, xRadius: keyRadius, yRadius: keyRadius)
        NSColor(calibratedWhite: 0.88, alpha: 0.48).setFill()
        depthPath.fill()

        let kPath = NSBezierPath(roundedRect: kRect, xRadius: keyRadius, yRadius: keyRadius)
        NSColor.white.withAlphaComponent(i == 1 ? 0.98 : 0.90).setFill()
        kPath.fill()

        if i == 1 {
            let barW = keyW * 0.46
            let barH = max(1.0, keyH * 0.11)
            let barRect = CGRect(
                x: kRect.midX - barW / 2,
                y: kRect.minY + keyH * 0.22,
                width: barW,
                height: barH
            )
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: barH / 2, yRadius: barH / 2)
            bottomColor.withAlphaComponent(0.75).setFill()
            barPath.fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for spec in specs {
    let data = renderIcon(px: spec.px)
    try data.write(to: iconsetDir.appendingPathComponent(spec.name))
}

print("Generated AppIcon.iconset")
