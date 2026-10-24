// Draws the app icon and writes Resources/AppIcon.icns (and docs/icon.png).
// The "T3" is T3 Code's own icon mark (assets/t3-mark.svg, from github.com/pingdotgg/t3code,
// MIT), and "Pro Max" is set in SF Pro, Apple's system face, as an Apple product name would be.
// Both are filled with a brushed-titanium gradient on black.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

let mark = NSImage(contentsOf: URL(fileURLWithPath: "assets/t3-mark.svg"))!
/// Fills `rect` with brushed titanium wherever `draw` paints.
func titanium(in rect: NSRect, gradientRect: NSRect, _ draw: @escaping () -> Void) {
    let mask = NSImage(size: rect.size, flipped: false) { _ in draw(); return true }
    let cg = mask.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    NSGraphicsContext.current!.saveGraphicsState()
    NSGraphicsContext.current!.cgContext.clip(to: rect, mask: cg)
    NSGradient(colors: [NSColor(white: 0.96, alpha: 1), NSColor(white: 0.64, alpha: 1),
                        NSColor(white: 0.92, alpha: 1), NSColor(white: 0.56, alpha: 1)])!
        .draw(in: gradientRect, angle: -70)
    NSGraphicsContext.current!.restoreGraphicsState()
}

func render(_ size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
        let shape = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.225, yRadius: inset.width * 0.225)
        NSGradient(starting: NSColor(white: 0.13, alpha: 1), ending: NSColor(white: 0.02, alpha: 1))!.draw(in: shape, angle: -90)
        NSColor(white: 0.55, alpha: 0.6).setStroke(); shape.lineWidth = size * 0.008; shape.stroke()

        // The mark's glyphs span x 15.5...110 and y 37...94 (SVG, y down) of its 128-unit box.
        let markSize = size * 0.64
        let markRect = NSRect(x: rect.midX - markSize * 0.5, y: rect.midY - markSize * 0.36, width: markSize, height: markSize)
        let unit = markSize / 128
        let glyphs = NSRect(x: markRect.minX + 15.5 * unit, y: markRect.minY + (128 - 94) * unit,
                            width: 94.5 * unit, height: 57 * unit)
        titanium(in: rect, gradientRect: glyphs.insetBy(dx: -2, dy: -2)) { mark.draw(in: markRect) }
        let label = NSAttributedString(string: "Pro Max", attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.11, weight: .semibold), .foregroundColor: NSColor.white, .kern: size * 0.002])
        let labelSize = label.size()
        let labelOrigin = NSPoint(x: rect.midX - labelSize.width / 2, y: rect.midY - size * 0.26)
        titanium(in: rect, gradientRect: NSRect(origin: labelOrigin, size: labelSize)) { label.draw(at: labelOrigin) }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! task.run(); task.waitUntilExit()
try! render(1024).write(to: URL(fileURLWithPath: "docs/icon.png"))
print("wrote Resources/AppIcon.icns")
