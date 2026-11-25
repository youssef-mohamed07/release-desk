// Draws the Release Desk icon (a paper plane leaving a light trail over an
// indigo-to-cyan squircle) at every size an .icns needs.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: the tile is 824/1024 of the canvas with a soft shadow.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let base = CGGradient(colorsSpace: space, colors: [
        NSColor(red: 0.10, green: 0.09, blue: 0.30, alpha: 1).cgColor,
        NSColor(red: 0.29, green: 0.25, blue: 0.86, alpha: 1).cgColor,
        NSColor(red: 0.16, green: 0.62, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    // A glow where the plane is heading.
    let glow = CGGradient(colorsSpace: space, colors: [NSColor(white: 1, alpha: 0.45).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.maxX - tile.width * 0.22, y: tile.maxY - tile.height * 0.25), startRadius: 0,
                           endCenter: CGPoint(x: tile.maxX - tile.width * 0.22, y: tile.maxY - tile.height * 0.25), endRadius: tile.width * 0.55, options: [])
    // The trail: three arcs fading behind the plane.
    for i in 0..<3 {
        let t = CGFloat(i)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.30 - t * 0.08).cgColor)
        ctx.setLineWidth(tile.width * (0.028 - t * 0.006))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: tile.minX + tile.width * (0.10 + t * 0.02), y: tile.minY + tile.height * (0.22 + t * 0.09)))
        ctx.addQuadCurve(to: CGPoint(x: tile.minX + tile.width * 0.48, y: tile.minY + tile.height * 0.46),
                         control: CGPoint(x: tile.minX + tile.width * (0.30 + t * 0.03), y: tile.minY + tile.height * (0.18 + t * 0.06)))
        ctx.strokePath()
    }
    ctx.restoreGState()

    // The plane, an SF Symbol drawn white.
    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.42, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let plane = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let sz = plane.size
        let r = CGRect(x: tile.midX - sz.width / 2 + tile.width * 0.06, y: tile.midY - sz.height / 2 + tile.height * 0.04, width: sz.width, height: sz.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: NSColor(red: 0.05, green: 0.05, blue: 0.25, alpha: 0.5).cgColor)
        plane.draw(in: r)
        ctx.restoreGState()
    }
    // A hairline highlight along the top edge.
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
