// Renders Resources/AppIcon.icns: a gradient squircle with two overlapping windows (Coherence).
// Usage: swift scripts/dev/make-icon.swift <output-dir>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.42, blue: 0.98, alpha: 1),
                        NSColor(red: 0.58, green: 0.27, blue: 0.86, alpha: 1)])!.draw(in: squircle, angle: -60)

    func window(_ r: NSRect, alpha: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = s * 0.03
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        let path = NSBezierPath(roundedRect: r, xRadius: s * 0.035, yRadius: s * 0.035)
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Title bar with traffic lights.
        let bar = NSRect(x: r.minX, y: r.maxY - r.height * 0.2, width: r.width, height: r.height * 0.2)
        NSBezierPath(roundedRect: bar, xRadius: s * 0.035, yRadius: s * 0.035).addClip()
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
        for (i, c) in colors.enumerated() {
            let d = r.height * 0.075
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + r.width * 0.06 + CGFloat(i) * d * 1.5, y: bar.midY - d / 2,
                                        width: d, height: d)).fill()
        }
    }
    window(NSRect(x: s * 0.22, y: s * 0.38, width: s * 0.44, height: s * 0.34), alpha: 0.75)
    NSGraphicsContext.current?.cgContext.resetClip()
    window(NSRect(x: s * 0.34, y: s * 0.24, width: s * 0.44, height: s * 0.34), alpha: 0.97)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(outDir.appendingPathComponent("AppIcon.icns").path)
