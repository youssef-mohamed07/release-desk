// The Release Desk promo: kinetic Arabic type, motion graphics and app
// screens in 3D, cut to the 120 BPM soundtrack from make-music.swift (one bar
// is exactly two seconds). Renders 1920×1080 at 30 fps, no audio; mux after.
//
// Usage: swiftc -O scripts/make-promo.swift -o /tmp/make-promo && /tmp/make-promo SHOTS_DIR ICON.png out.mp4
import AppKit
import AVFoundation
import CoreImage

let W = 1920.0, H = 1080.0, FPS = 30
let duration = 64.0
let args = CommandLine.arguments
let shotsDir = URL(fileURLWithPath: args[1])
let iconURL = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])
let onlyFrame = args.count > 4 ? Double(args[4]) : nil   // render one frame (seconds) to PNG, for checks

// MARK: - Math

func clamp(_ x: Double, _ a: Double = 0, _ b: Double = 1) -> Double { min(b, max(a, x)) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func prog(_ t: Double, _ start: Double, _ dur: Double) -> Double { clamp((t - start) / dur) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
func easeIn(_ x: Double) -> Double { pow(clamp(x), 3) }
func easeInOut(_ x: Double) -> Double { let x = clamp(x); return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
func spring(_ x: Double) -> Double { x <= 0 ? 0 : (x >= 1 ? 1 : 1 - exp(-6.5 * x) * cos(10 * x)) }
func pulse(_ t: Double, every p: Double = 0.5, decay: Double = 9) -> Double {
    exp(-(t.truncatingRemainder(dividingBy: p)) * decay)
}

// MARK: - Assets

func cg(_ url: URL) -> CGImage {
    guard let img = NSImage(contentsOf: url), let c = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("cannot read \(url.path)")
    }
    return c
}
let space = CGColorSpaceCreateDeviceRGB()
/// A screenshot with rounded corners, ready for CoreImage.
func rounded(_ img: CGImage, radius: Double) -> CIImage {
    let w = img.width, h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return CIImage(cgImage: ctx.makeImage()!)
}
var shots: [String: CIImage] = [:]
func shot(_ name: String) -> CIImage {
    if let s = shots[name] { return s }
    let s = rounded(cg(shotsDir.appendingPathComponent("\(name).png")), radius: 30)
    shots[name] = s
    return s
}
let icon = cg(iconURL)
let ci = CIContext(options: [.cacheIntermediates: false])

// MARK: - Palette

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
let indigo = (0.36, 0.33, 0.98), violet = (0.62, 0.36, 1.0), cyan = (0.22, 0.80, 1.0), mint = (0.20, 0.86, 0.62)
func ns(_ c: (Double, Double, Double), _ a: Double = 1) -> NSColor { NSColor(red: c.0, green: c.1, blue: c.2, alpha: a) }

// MARK: - Drawing (top-left coordinates; the context is flipped once per frame)

var ctx: CGContext!

func drawCG(_ img: CGImage, _ r: CGRect, alpha: Double = 1) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.translateBy(x: r.minX, y: r.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
    ctx.restoreGState()
}

func isArabic(_ s: String) -> Bool { s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }

func attributed(_ s: String, size: Double, weight: NSFont.Weight, color: NSColor, align: NSTextAlignment, kern: Double = 0) -> NSAttributedString {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    p.baseWritingDirection = isArabic(s) ? .rightToLeft : .leftToRight
    p.lineSpacing = size * 0.12
    return NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p, .kern: kern,
    ])
}

@discardableResult
func text(_ s: String, x: Double, y: Double, width: Double, size: Double, weight: NSFont.Weight = .bold,
          color: NSColor = .white, alpha: Double = 1, align: NSTextAlignment = .center, kern: Double = 0) -> Double {
    let a = attributed(s, size: size, weight: weight, color: color.withAlphaComponent(color.alphaComponent * alpha), align: align, kern: kern)
    let h = ceil(a.boundingRect(with: CGSize(width: width, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    a.draw(with: CGRect(x: x, y: y, width: width, height: h + 4), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return h
}

func textWidth(_ s: String, size: Double, weight: NSFont.Weight = .bold) -> Double {
    attributed(s, size: size, weight: weight, color: .white, align: .left).size().width
}

/// Text that rises out of a mask as it appears.
func reveal(_ s: String, x: Double, y: Double, width: Double, size: Double, weight: NSFont.Weight = .heavy, color: NSColor = .white,
            t: Double, at start: Double, dur: Double = 0.6, align: NSTextAlignment = .center, out: Double? = nil) {
    var p = easeOut(prog(t, start, dur))
    if let out { p *= 1 - easeIn(prog(t, out, 0.35)) }
    guard p > 0 else { return }
    let lineH = size * 1.35
    ctx.saveGState()
    ctx.clip(to: CGRect(x: x - 40, y: y - 10, width: width + 80, height: lineH * 3 + 20))
    text(s, x: x, y: y + (1 - p) * lineH * 0.9, width: width, size: size, weight: weight, color: color, alpha: p, align: align)
    ctx.restoreGState()
}

func pill(_ r: CGRect, fill: CGColor, stroke: CGColor? = nil) {
    let path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
    ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath()
    if let stroke { ctx.addPath(path); ctx.setStrokeColor(stroke); ctx.setLineWidth(1.5); ctx.strokePath() }
}

func symbol(_ name: String, _ r: CGRect, color: NSColor, alpha: Double = 1, weight: NSFont.Weight = .bold, secondary: NSColor? = nil) {
    let colors = secondary.map { [color, $0] } ?? [color]
    let cfg = NSImage.SymbolConfiguration(pointSize: r.height, weight: weight).applying(.init(paletteColors: colors))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    let s = img.size
    let k = min(r.width / s.width, r.height / s.height)
    let rr = CGRect(x: r.midX - s.width * k / 2, y: r.midY - s.height * k / 2, width: s.width * k, height: s.height * k)
    img.draw(in: rr, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
}

/// A rounded chip with an icon and a label, popping in with a spring.
func chip(_ label: String, icon: String?, cx: Double, cy: Double, t: Double, at start: Double, tint: (Double, Double, Double) = indigo, size: Double = 26) {
    let p = spring(prog(t, start, 0.55))
    guard p > 0 else { return }
    let w = textWidth(label, size: size, weight: .semibold) + (icon == nil ? 44 : 84)
    let h = size * 2.0
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.scaleBy(x: p, y: p)
    ctx.setAlpha(clamp(prog(t, start, 0.2)))
    let r = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    pill(r, fill: rgb(0.06 + (tint.0 - 0.06) * 0.32, 0.06 + (tint.1 - 0.06) * 0.32, 0.12 + (tint.2 - 0.12) * 0.32, 0.96),
         stroke: rgb(tint.0, tint.1, tint.2, 0.8))
    let rtl = isArabic(label)
    var tx = r.minX + 22
    if let icon {
        let light = ns(tint).blended(withFraction: 0.5, of: .white)!
        let ix = rtl ? r.maxX - 20 - size : r.minX + 20
        let twoTone = icon.hasSuffix("circle.fill")
        symbol(icon, CGRect(x: ix, y: -size * 0.5, width: size, height: size), color: twoTone ? NSColor(white: 0.06, alpha: 1) : light,
               secondary: twoTone ? light : nil)
        if !rtl { tx += 40 }
    }
    let tw = w - 40 - (icon == nil ? 0 : 40)
    text(label, x: tx, y: -size * 0.68, width: tw, size: size, weight: .semibold, color: .white, align: rtl ? .right : .left)
    ctx.restoreGState()
}

// MARK: - Screens in 3D

/// Maps a point of the full screenshot (0…1) to where it is drawn on screen.
typealias Projector = (Double, Double) -> CGPoint

func roundedQuad(_ p: [CGPoint], r: Double) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2))
    for i in 1...4 { path.addArc(tangent1End: p[i % 4], tangent2End: p[(i + 1) % 4], radius: r) }
    path.closeSubpath()
    return path
}

/// Draws a screenshot as a floating card: center, width, rotation about Y, X
/// and Z (degrees) with perspective. Zoom is a camera move inside the card: it
/// crops around a focus point of the image (0…1), so the card keeps its frame.
@discardableResult
func screen(_ name: String, cx: Double, cy: Double, width: Double, rotY: Double = 0, rotX: Double = 0, rotZ: Double = 0,
            alpha: Double = 1, zoom: Double = 1, focus: (Double, Double) = (0.5, 0.5), glow: (Double, Double, Double)? = nil) -> Projector {
    var img = shot(name)
    let iw = img.extent.width, ih = img.extent.height
    let w = width, h = w * ih / iw
    var crop = CGRect(x: 0, y: 0, width: iw, height: ih)   // image pixels, top-left origin
    if zoom > 1.001 {
        let cw = iw / zoom, ch = ih / zoom
        crop = CGRect(x: clamp(focus.0 * iw - cw / 2, 0, iw - cw), y: clamp(focus.1 * ih - ch / 2, 0, ih - ch), width: cw, height: ch)
        let r = CGRect(x: crop.minX, y: ih - crop.maxY, width: cw, height: ch)
        img = img.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }
    // Downscale with Lanczos first so text does not shimmer.
    if crop.width > w * 1.25 {
        img = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: w * 1.2 / crop.width, kCIInputAspectRatioKey: 1])
    }
    let ay = rotY * .pi / 180, ax = rotX * .pi / 180, az = rotZ * .pi / 180
    let d = 2200.0
    func project(_ x: Double, _ y: Double) -> CGPoint {
        let xz = x * cos(az) - y * sin(az), yz = x * sin(az) + y * cos(az)
        let x1 = xz * cos(ay), z1 = xz * sin(ay)
        let y2 = yz * cos(ax) - z1 * sin(ax), z2 = yz * sin(ax) + z1 * cos(ax)
        let s = d / (d + z2)
        return CGPoint(x: cx + x1 * s, y: cy + y2 * s)
    }
    let projector: Projector = { u, v in
        project((u * iw - crop.minX) / crop.width * w - w / 2, (v * ih - crop.minY) / crop.height * h - h / 2)
    }
    guard alpha > 0.001 else { return projector }
    let tl = project(-w / 2, -h / 2), tr = project(w / 2, -h / 2), br = project(w / 2, h / 2), bl = project(-w / 2, h / 2)
    let quad = roundedQuad([tl, tr, br, bl], r: w * 0.011)

    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.setShadow(offset: CGSize(width: 0, height: 30), blur: 70, color: rgb(0, 0, 0, 0.6))
    ctx.addPath(quad); ctx.setFillColor(rgb(0.05, 0.05, 0.1)); ctx.fillPath()
    if let g = glow {
        ctx.setShadow(offset: .zero, blur: 90, color: rgb(g.0, g.1, g.2, 0.55))
        ctx.addPath(quad); ctx.setFillColor(rgb(0.05, 0.05, 0.1)); ctx.fillPath()
    }
    ctx.restoreGState()

    func up(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: H - p.y) }
    let f = CIFilter(name: "CIPerspectiveTransform")!
    f.setValue(img, forKey: kCIInputImageKey)
    f.setValue(up(tl), forKey: "inputTopLeft"); f.setValue(up(tr), forKey: "inputTopRight")
    f.setValue(up(br), forKey: "inputBottomRight"); f.setValue(up(bl), forKey: "inputBottomLeft")
    guard let out = f.outputImage else { return projector }
    let visible = out.extent.intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
    guard !visible.isEmpty, let rendered = ci.createCGImage(out, from: visible) else { return projector }
    ctx.saveGState()
    ctx.addPath(quad); ctx.clip()
    drawCG(rendered, CGRect(x: visible.minX, y: H - visible.maxY, width: visible.width, height: visible.height), alpha: alpha)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(quad); ctx.setStrokeColor(rgb(1, 1, 1, 0.16 * alpha)); ctx.setLineWidth(1.5); ctx.strokePath()
    ctx.restoreGState()
    return projector
}

/// A glowing ring around a region of a card (image coordinates 0…1).
func callout(_ proj: Projector, region: (Double, Double, Double, Double), t: Double, at start: Double,
             color: (Double, Double, Double) = cyan, label: String? = nil) {
    let p = easeOut(prog(t, start, 0.4))
    guard p > 0 else { return }
    let pts = [proj(region.0, region.1), proj(region.0 + region.2, region.1), proj(region.0 + region.2, region.1 + region.3), proj(region.0, region.1 + region.3)]
    let xs = pts.map(\.x), ys = pts.map(\.y)
    let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -8, dy: -8)
    let grow = (1 - p) * 30
    let rr = r.insetBy(dx: -grow, dy: -grow)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: rgb(color.0, color.1, color.2, 0.9 * p))
    ctx.addPath(CGPath(roundedRect: rr, cornerWidth: 16, cornerHeight: 16, transform: nil))
    ctx.setStrokeColor(rgb(color.0, color.1, color.2, p * (0.75 + 0.25 * pulse(t, every: 0.5, decay: 4))))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()
    if let label {
        chip(label, icon: nil, cx: rr.midX, cy: rr.minY - 30, t: t, at: start + 0.15, tint: color, size: 22)
    }
}

// MARK: - Background

struct Dot { var x: Double; var y: Double; var r: Double; var speed: Double; var phase: Double }
var seed: UInt64 = 0x5EED
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
let dots = (0..<90).map { _ in Dot(x: rnd() * W, y: rnd() * H, r: 0.8 + rnd() * 2.2, speed: 8 + rnd() * 26, phase: rnd() * 6.28) }

func background(_ t: Double, tint: (Double, Double, Double), energy: Double) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(0.03, 0.035, 0.08), rgb(0.07, 0.06, 0.17), rgb(0.03, 0.05, 0.12)] as CFArray,
                       locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: [])
    let blobs: [((Double, Double, Double), Double, Double, Double)] = [(tint, 0.13, 0.0, 760), (violet, 0.09, 2.1, 640), (cyan, 0.11, 4.2, 560)]
    for (c, sp, ph, rad) in blobs {
        let cx = W * (0.5 + 0.38 * sin(t * sp + ph)), cy = H * (0.5 + 0.34 * cos(t * sp * 0.8 + ph * 1.3))
        let a = (0.32 + 0.18 * energy)
        let rg = CGGradient(colorsSpace: space, colors: [rgb(c.0, c.1, c.2, a), rgb(c.0, c.1, c.2, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(rg, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: rad, options: [])
    }
    // A faint drifting dot grid.
    ctx.setFillColor(rgb(1, 1, 1, 0.035))
    let step = 48.0, off = (t * 6).truncatingRemainder(dividingBy: step)
    var y = -step + off
    while y < H + step {
        var x = -step + off * 0.5
        while x < W + step { ctx.fillEllipse(in: CGRect(x: x, y: y, width: 2, height: 2)); x += step }
        y += step
    }
    // Floating particles.
    for d in dots {
        let yy = (d.y - t * d.speed).truncatingRemainder(dividingBy: H + 20)
        let py = yy < 0 ? yy + H + 20 : yy
        let tw = 0.35 + 0.35 * sin(t * 1.7 + d.phase)
        ctx.setFillColor(rgb(0.8, 0.85, 1, tw * (0.5 + 0.5 * energy)))
        ctx.fillEllipse(in: CGRect(x: d.x, y: py, width: d.r, height: d.r))
    }
}

// MARK: - Scenes

struct Scene { let start: Double; let end: Double; let draw: (Double, Double) -> Void }   // (local t, global t)

func kicker(_ s: String, x: Double, y: Double, width: Double, t: Double, at start: Double, color: (Double, Double, Double), align: NSTextAlignment = .right) {
    let p = easeOut(prog(t, start, 0.4))
    guard p > 0 else { return }
    text(s, x: x, y: y, width: width, size: 24, weight: .heavy, color: ns(color).blended(withFraction: 0.45, of: .white)!, alpha: p, align: align, kern: 1)
}

/// Text on the right, card on the left, tilted toward the text.
func feature(_ t: Double, _ g: Double, kick: String, title: String, body: String, screenName: String, color: (Double, Double, Double),
             focus: (Double, Double) = (0.5, 0.5), zoomTo: Double = 1.0, zoomAt: Double = 1.6, chips: [(String, String?)] = [],
             callout region: (Double, Double, Double, Double)? = nil, calloutLabel: String? = nil, extra: ((Double, Projector) -> Void)? = nil) {
    let enter = easeOut(prog(t, 0, 0.9))
    let settle = easeInOut(prog(t, 0.3, 1.6))
    let zoom = lerp(1, zoomTo, easeInOut(prog(t, zoomAt, 1.4)))
    let cx = lerp(560, 720, enter), cy = 570.0
    let rotY = lerp(-38, -10, enter) + lerp(0, 8, settle)
    let proj = screen(screenName, cx: cx, cy: cy, width: 1180, rotY: rotY, rotX: 3 * (1 - settle), alpha: clamp(t / 0.3), zoom: zoom, focus: focus, glow: color)
    if let region {
        callout(proj, region: region, t: t, at: 2.0, color: color, label: calloutLabel)
    }
    let tx = 1330.0, tw = 520.0
    kicker(kick, x: tx, y: 250, width: tw, t: t, at: 0.25, color: color)
    reveal(title, x: tx, y: 300, width: tw, size: 54, t: t, at: 0.4, align: .right)
    reveal(body, x: tx, y: 470, width: tw, size: 27, weight: .medium, color: NSColor(white: 0.82, alpha: 1), t: t, at: 0.8, align: .right)
    for (i, c) in chips.enumerated() {
        chip(c.0, icon: c.1, cx: tx + tw - 110 - Double(i % 2) * 250, cy: 640 + Double(i / 2) * 76, t: t, at: 1.2 + Double(i) * 0.25, tint: color)
    }
    extra?(t, proj)
}

var scenes: [Scene] = []

// 0–8: logo, name, promise
scenes.append(Scene(start: 0, end: 8) { t, _ in
    let p = spring(prog(t, 0.8, 1.0))
    let lift = easeInOut(prog(t, 4.0, 1.2))
    let size = 260.0 * p * (1 - 0.35 * lift)
    let cy = lerp(430, 300, lift)
    // Burst ring on the downbeat.
    let rp = prog(t, 2.0, 1.2)
    if rp > 0 && rp < 1 {
        ctx.setStrokeColor(rgb(0.6, 0.5, 1, (1 - rp) * 0.8)); ctx.setLineWidth(6 * (1 - rp))
        let rr = 150 + rp * 520
        ctx.strokeEllipse(in: CGRect(x: W / 2 - rr, y: cy - rr, width: rr * 2, height: rr * 2))
    }
    if size > 1 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 80, color: rgb(0.45, 0.35, 1, 0.8))
        drawCG(icon, CGRect(x: W / 2 - size / 2, y: cy - size / 2, width: size, height: size))
        ctx.restoreGState()
    }
    // Wordmark, letter by letter.
    let word = "Release Desk"
    let sizeW = 104.0
    let total = textWidth(word, size: sizeW, weight: .heavy)
    var x = W / 2 - total / 2
    for (i, ch) in word.enumerated() {
        let s = String(ch)
        let cw = textWidth(s, size: sizeW, weight: .heavy)
        let lp = easeOut(prog(t, 2.4 + Double(i) * 0.06, 0.5))
        if lp > 0 {
            text(s, x: x, y: lerp(640, 560, lift) + (1 - lp) * 60, width: cw + 10, size: sizeW, weight: .heavy, alpha: lp, align: .left)
        }
        x += cw
    }
    reveal("انشر تطبيقاتك من مكان واحد", x: 260, y: lerp(800, 720, lift), width: W - 520, size: 48, weight: .bold,
           color: NSColor(white: 0.9, alpha: 1), t: t, at: 4.2)
    chip("App Store", icon: "apple.logo", cx: W / 2 - 160, cy: 860, t: t, at: 5.2, tint: indigo)
    chip("Google Play", icon: "play.fill", cx: W / 2 + 160, cy: 860, t: t, at: 5.6, tint: mint)
})

// 8–16: the mess, then the turn
let mess: [(String, Double, Double, Double, Double)] = [   // word, x, y, size, rotation
    ("Xcode", 360, 260, 70, -6), ("Terminal", 1500, 220, 58, 5), ("App Store Connect", 980, 380, 64, -3),
    ("سكربتات", 420, 560, 66, 4), ("Play Console", 1480, 560, 62, -5), ("TestFlight", 900, 700, 58, 3),
    ("مفاتيح", 300, 840, 60, -4), ("توقيع", 1600, 850, 62, 6), ("انتظار…", 1000, 940, 54, -2),
    ("رفع يدوي", 330, 410, 52, 7), ("Keystore", 1250, 140, 50, -7), ("ExportOptions.plist", 1180, 1010, 40, 2),
]
scenes.append(Scene(start: 8, end: 16) { t, g in
    let collapse = easeIn(prog(t, 5.4, 0.7))
    for (i, m) in mess.enumerated() {
        let at = 0.0 + Double(i) * 0.42
        let p = spring(prog(t, at, 0.45))
        guard p > 0 else { continue }
        let shake = sin(g * 23 + Double(i)) * 2 * (1 - collapse)
        let x = lerp(m.1, W / 2, collapse), y = lerp(m.2, H / 2, collapse)
        ctx.saveGState()
        ctx.translateBy(x: x + shake, y: y)
        ctx.rotate(by: (m.4 + collapse * 40) * .pi / 180)
        ctx.scaleBy(x: p * (1 - collapse * 0.9), y: p * (1 - collapse * 0.9))
        let w = textWidth(m.0, size: m.3, weight: .heavy) + 40
        text(m.0, x: -w / 2, y: -m.3 * 0.7, width: w, size: m.3, weight: .heavy,
             color: NSColor(white: 0.65 + 0.35 * Double(i % 3) / 2, alpha: 1), alpha: (0.85 - 0.3 * Double(i % 2)) * (1 - collapse), align: .center)
        ctx.restoreGState()
    }
    reveal("كل هذا…", x: 200, y: 380, width: W - 400, size: 92, weight: .heavy, t: t, at: 6.0, dur: 0.5)
    reveal("في شاشة واحدة.", x: 200, y: 520, width: W - 400, size: 92, weight: .heavy, color: ns(cyan), t: t, at: 6.6, dur: 0.5)
})

// 16–32: four features, one per two bars
scenes.append(Scene(start: 16, end: 20) { t, _ in
    feature(t, 0, kick: "الحسابات", title: "كل حساباتك وفرقك\nفي شاشة واحدة", body: "Apple و Google، وكل فريق منفصل كما هو.",
            screenName: "dark-01-overview", color: indigo, chips: [("Apple", "apple.logo"), ("Google Play", "play.fill")],
            callout: (0.005, 0.17, 0.165, 0.36), calloutLabel: "حساب لكل فريق")
})
scenes.append(Scene(start: 20, end: 24) { t, _ in
    feature(t, 0, kick: "الرفع", title: "زر واحد\nيبني ويوقّع ويرفع", body: "ثم مجموعات TestFlight، ونص What to Test، والمراجعة.",
            screenName: "dark-05-ship-ios", color: violet, focus: (0.92, 0.938), zoomTo: 1.6, zoomAt: 1.1) { t, proj in
        // The pointer glides to Launch and clicks it.
        let target = proj(0.905, 0.94)
        let mp = easeInOut(prog(t, 2.3, 0.8))
        guard mp > 0 else { return }
        let press = prog(t, 3.15, 0.15) * (1 - prog(t, 3.3, 0.15))
        let cp = prog(t, 3.2, 0.7)
        if cp > 0 && cp < 1 {
            ctx.setStrokeColor(rgb(1, 1, 1, (1 - cp) * 0.9)); ctx.setLineWidth(5 * (1 - cp))
            let r = 24 + cp * 140
            ctx.strokeEllipse(in: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2))
        }
        let px = lerp(target.x - 380, target.x, mp), py = lerp(target.y - 260, target.y, mp)
        let k = 1 - 0.18 * press
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: rgb(0, 0, 0, 0.6))
        symbol("cursorarrow", CGRect(x: px - 6, y: py - 4, width: 46 * k, height: 58 * k), color: .white, alpha: clamp(mp * 3))
        ctx.restoreGState()
    }
})
scenes.append(Scene(start: 24, end: 28) { t, _ in
    let done = t >= 2.0
    feature(t, 0, kick: "المتابعة", title: "تابع كل خطوة\nلحظة بلحظة", body: "وإن توقفت خطوة، تكمل من نفس المكان.",
            screenName: done ? "dark-09-console-succeeded" : "dark-09-console-running", color: done ? mint : cyan,
            chips: [("Archive", "shippingbox.fill"), ("Upload", "icloud.and.arrow.up.fill"), ("TestFlight", "airplane")])
    // "Shipped" stamp.
    let sp = spring(prog(t, 2.05, 0.5))
    if sp > 0 {
        ctx.saveGState()
        ctx.translateBy(x: 1010, y: 300)
        ctx.rotate(by: -8 * .pi / 180)
        ctx.scaleBy(x: sp, y: sp)
        pill(CGRect(x: -150, y: -42, width: 300, height: 84), fill: rgb(mint.0, mint.1, mint.2, 0.95))
        symbol("checkmark", CGRect(x: -124, y: -20, width: 40, height: 40), color: NSColor(white: 0.05, alpha: 1), weight: .black)
        text("Shipped", x: -76, y: -30, width: 210, size: 40, weight: .heavy, color: NSColor(white: 0.05, alpha: 1), align: .left)
        ctx.restoreGState()
    }
})
scenes.append(Scene(start: 28, end: 32) { t, _ in
    feature(t, 0, kick: "Google Play", title: "كل الـ tracks\nفي مكان واحد", body: "نشر كامل، أو تدريجي بنسبة، أو كمسودة.",
            screenName: "light-03-play", color: mint, chips: [("Internal", nil), ("Closed", nil), ("Open", nil), ("Production", nil)],
            callout: (0.44, 0.29, 0.207, 0.175), calloutLabel: "نشر تدريجي")
})

// 32–40: no Mac? GitHub builds it.
scenes.append(Scene(start: 32, end: 36) { t, g in
    reveal("لا تملك ماك؟", x: 200, y: 300, width: W - 400, size: 110, weight: .heavy, t: t, at: 0.1, dur: 0.7, out: 1.6)
    let p = easeOut(prog(t, 1.9, 0.7))
    if p > 0 {
        // GitHub cloud → phone, with packets moving along the line.
        let y = 520.0
        symbol("cloud.fill", CGRect(x: 520, y: y - 90, width: 230, height: 180), color: ns(cyan), alpha: p)
        let phone = CGRect(x: 1235, y: y - 130, width: 140, height: 260)
        ctx.saveGState(); ctx.setAlpha(p)
        ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.setFillColor(rgb(0.08, 0.08, 0.14)); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.setStrokeColor(rgb(1, 1, 1, 0.85)); ctx.setLineWidth(5); ctx.strokePath()
        pill(CGRect(x: phone.midX - 24, y: phone.minY + 14, width: 48, height: 12), fill: rgb(1, 1, 1, 0.85))
        ctx.restoreGState()
        let ip = spring(prog(t, 2.9, 0.6))
        if ip > 0 { drawCG(icon, CGRect(x: phone.midX - 40 * ip, y: y - 40 * ip, width: 80 * ip, height: 80 * ip)) }
        text("GitHub", x: 535, y: y + 95, width: 200, size: 26, weight: .semibold, color: NSColor(white: 0.85, alpha: 1), alpha: p)
        text("TestFlight · Play", x: 1180, y: y + 145, width: 250, size: 26, weight: .semibold, color: NSColor(white: 0.85, alpha: 1), alpha: p)
        ctx.setStrokeColor(rgb(1, 1, 1, 0.25 * p)); ctx.setLineWidth(3); ctx.setLineDash(phase: -g * 60, lengths: [14, 12])
        ctx.move(to: CGPoint(x: 790, y: y)); ctx.addLine(to: CGPoint(x: 1200, y: y)); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
        for k in 0..<3 {
            let q = ((g * 0.9 + Double(k) / 3).truncatingRemainder(dividingBy: 1))
            ctx.setFillColor(rgb(cyan.0, cyan.1, cyan.2, p * (1 - abs(q - 0.5) * 1.6)))
            ctx.fillEllipse(in: CGRect(x: 790 + q * 410 - 9, y: y - 9, width: 18, height: 18))
        }
    }
    reveal("GitHub Actions يبني ويرفع بدلًا منك", x: 200, y: 720, width: W - 400, size: 60, t: t, at: 2.3)
    reveal("لـ iOS و Android", x: 200, y: 820, width: W - 400, size: 34, weight: .medium, color: NSColor(white: 0.8, alpha: 1), t: t, at: 2.7)
})
scenes.append(Scene(start: 36, end: 40) { t, _ in
    let enter = easeOut(prog(t, 0, 0.9))
    screen("dark-05-ship-ios", cx: lerp(620, 700, enter), cy: 560, width: 1150, rotY: lerp(-30, -6, enter), rotX: lerp(4, 0, enter),
           alpha: clamp(t / 0.3), zoom: lerp(1, 2.2, easeInOut(prog(t, 0.5, 1.4))), focus: (0.376, 0.563), glow: cyan)
    kicker("GitHub Actions", x: 1330, y: 250, width: 520, t: t, at: 0.3, color: cyan)
    reveal("يضبطه لك\nمن نفس الشاشة", x: 1330, y: 300, width: 520, size: 54, t: t, at: 0.5, align: .right)
    let labels = ["تسجيل الدخول", "ملف الـ workflow", "المفاتيح في الـ secrets"]
    for (i, l) in labels.enumerated() {
        chip(l, icon: "checkmark.circle.fill", cx: 1650, cy: 540 + Double(i) * 84, t: t, at: 1.6 + Double(i) * 0.35, tint: mint)
    }
})

// 40–56: everything else, fast
let grid: [(String, String, (Double, Double, Double))] = [
    ("مراجعة App Store", "checkmark.shield.fill", indigo), ("تطبيق جديد في دقائق", "sparkles", violet),
    ("Android على GitHub", "cloud.fill", cyan), ("وضع الخصوصية", "eye.slash.fill", mint),
    ("تنقّل سريع \u{200E}⌘K", "command", indigo), ("إشعار عند الانتهاء", "bell.badge.fill", violet),
]
scenes.append(Scene(start: 40, end: 44) { t, g in
    reveal("وأكثر", x: 200, y: 110, width: W - 400, size: 72, t: t, at: 0)
    for (i, f) in grid.enumerated() {
        let col = Double(i % 3), row = Double(i / 3)
        let cx = 420 + col * 540, cy = 430 + row * 300
        let p = spring(prog(t, 0.5 + Double(i) * 0.25, 0.6))
        guard p > 0 else { continue }
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy + sin(g * 2 + Double(i)) * 6)
        ctx.scaleBy(x: p, y: p)
        let r = CGRect(x: -230, y: -115, width: 460, height: 230)
        ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 40, color: rgb(0, 0, 0, 0.5))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.setFillColor(rgb(1, 1, 1, 0.07)); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.setStrokeColor(rgb(f.2.0, f.2.1, f.2.2, 0.55)); ctx.setLineWidth(2); ctx.strokePath()
        symbol(f.1, CGRect(x: -40, y: -80, width: 80, height: 70), color: ns(f.2).blended(withFraction: 0.35, of: .white)!)
        text(f.0, x: -210, y: 10, width: 420, size: 34, weight: .bold, align: .center)
        ctx.restoreGState()
    }
})
scenes.append(Scene(start: 44, end: 48) { t, _ in
    let flip = easeInOut(prog(t, 1.6, 0.6))
    screen("dark-01-overview", cx: 700, cy: 560, width: 1150, rotY: -10, alpha: clamp(t / 0.3) * (1 - flip), glow: indigo)
    screen("dark-08-privacy", cx: 700, cy: 560, width: 1150, rotY: -10, alpha: clamp(t / 0.3) * flip, glow: mint)
    let ep = spring(prog(t, 1.4, 0.5))
    if ep > 0 {
        ctx.saveGState()
        ctx.translateBy(x: 1180, y: 250); ctx.scaleBy(x: ep, y: ep)
        ctx.setFillColor(rgb(mint.0, mint.1, mint.2, 0.95)); ctx.fillEllipse(in: CGRect(x: -60, y: -60, width: 120, height: 120))
        symbol("eye.slash.fill", CGRect(x: -36, y: -30, width: 72, height: 60), color: NSColor(white: 0.05, alpha: 1))
        ctx.restoreGState()
    }
    kicker("⇧⌘P", x: 1330, y: 330, width: 520, t: t, at: 0.3, color: mint)
    reveal("وضع الخصوصية", x: 1330, y: 380, width: 520, size: 60, t: t, at: 0.5, align: .right)
    reveal("يخفي الأسماء والمعرّفات\nلتشارك شاشتك بأمان.", x: 1330, y: 480, width: 520, size: 30, weight: .medium,
           color: NSColor(white: 0.82, alpha: 1), t: t, at: 0.9, align: .right)
})
scenes.append(Scene(start: 48, end: 52) { t, g in
    let names = ["light-01-overview", "dark-02-app", "light-06-ship-play"]
    for (i, n) in names.enumerated() {
        let p = easeOut(prog(t, Double(i) * 0.25, 0.9))
        let cx = 420 + Double(i) * 540, cy = 520 + sin(g * 1.4 + Double(i)) * 10
        screen(n, cx: cx, cy: lerp(cy + 200, cy, p), width: 500, rotY: lerp(30, Double(i - 1) * -14, p), rotZ: Double(i - 1) * 2,
               alpha: p, glow: [indigo, violet, mint][i])
    }
    reveal("يعمل على جهازك", x: 200, y: 110, width: W - 400, size: 70, t: t, at: 0.3)
    chip("macOS", icon: "apple.logo", cx: 520, cy: 880, t: t, at: 1.4, tint: indigo, size: 30)
    chip("Windows", icon: "pc", cx: 960, cy: 880, t: t, at: 1.65, tint: cyan, size: 30)
    chip("Linux", icon: "terminal.fill", cx: 1400, cy: 880, t: t, at: 1.9, tint: mint, size: 30)
})
scenes.append(Scene(start: 52, end: 56) { t, _ in
    let p = easeOut(prog(t, 0, 0.9))
    screen("dark-11-connect-apple", cx: lerp(520, 640, p), cy: 560, width: 980, rotY: lerp(-30, -12, p), alpha: clamp(t / 0.3), glow: indigo)
    let lp = spring(prog(t, 0.9, 0.6))
    if lp > 0 {
        ctx.saveGState()
        ctx.translateBy(x: 1480, y: 330); ctx.scaleBy(x: lp, y: lp)
        ctx.setFillColor(rgb(indigo.0, indigo.1, indigo.2, 0.9)); ctx.fillEllipse(in: CGRect(x: -75, y: -75, width: 150, height: 150))
        symbol("lock.fill", CGRect(x: -38, y: -42, width: 76, height: 80), color: .white)
        ctx.restoreGState()
    }
    reveal("مفاتيحك تبقى على جهازك", x: 1180, y: 460, width: 640, size: 56, t: t, at: 1.1, align: .right)
    reveal("في Keychain أو مخزن النظام الآمن، ولا تُرسل إلا إلى Apple و Google و GitHub.", x: 1180, y: 610, width: 640, size: 28,
           weight: .medium, color: NSColor(white: 0.82, alpha: 1), t: t, at: 1.5, align: .right)
})

// 56–64: end card
scenes.append(Scene(start: 56, end: 64) { t, _ in
    let p = spring(prog(t, 0.1, 0.9))
    let size = 200 * p
    if size > 1 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 90, color: rgb(0.45, 0.35, 1, 0.85))
        drawCG(icon, CGRect(x: W / 2 - size / 2, y: 270 - size / 2, width: size, height: size))
        ctx.restoreGState()
    }
    reveal("Release Desk", x: 200, y: 400, width: W - 400, size: 110, t: t, at: 0.5)
    reveal("مجاني ومفتوح المصدر", x: 200, y: 560, width: W - 400, size: 50, weight: .bold, color: ns(cyan), t: t, at: 1.0)
    let up = easeOut(prog(t, 1.6, 0.6))
    if up > 0 {
        let label = "github.com/youssef-mohamed07/release-desk"
        let w = textWidth(label, size: 34, weight: .semibold) + 110
        let r = CGRect(x: W / 2 - w / 2, y: 690 + (1 - up) * 30, width: w, height: 76)
        ctx.saveGState(); ctx.setAlpha(up)
        pill(r, fill: rgb(1, 1, 1, 0.08), stroke: rgb(1, 1, 1, 0.25))
        symbol("chevron.left.forwardslash.chevron.right", CGRect(x: r.minX + 28, y: r.midY - 16, width: 40, height: 32), color: ns(cyan))
        text(label, x: r.minX + 82, y: r.minY + 15, width: w - 100, size: 34, weight: .semibold, align: .left)
        ctx.restoreGState()
    }
    chip("macOS · Windows · Linux", icon: nil, cx: W / 2, cy: 860, t: t, at: 2.2, tint: violet, size: 26)
})

func tint(at g: Double) -> ((Double, Double, Double), Double) {
    switch g {
    case 16..<32, 40..<56: (g >= 26 && g < 28 ? mint : indigo, 1.0)
    case 32..<40: (cyan, 0.5)
    default: (indigo, 0.35)
    }
}

// MARK: - Render

func renderFrame(_ g: Double) {
    let (tc, energy) = tint(at: g)
    let beatBoost = (g >= 16 && g < 32) || (g >= 40 && g < 56) ? pulse(g, every: 0.5, decay: 8) : 0
    background(g, tint: tc, energy: energy + beatBoost * 0.4)
    let fade = 0.35
    for s in scenes where g >= s.start - 0.001 && g < s.end + fade {
        let local = g - s.start
        var a = 1.0
        if g > s.end { a = 1 - (g - s.end) / fade }
        if s.start > 0 && local < fade { a = min(a, local / fade) }
        guard a > 0 else { continue }
        ctx.saveGState()
        ctx.setAlpha(a)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        s.draw(local, g)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    // Flashes on the drops.
    for drop in [16.0, 40.0] where g >= drop && g < drop + 0.5 {
        ctx.setFillColor(rgb(1, 1, 1, 0.55 * (1 - (g - drop) / 0.5)))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    }
    // Fade from and to black.
    let edge = min(clamp(g / 0.6), clamp((duration - g) / 1.5))
    if edge < 1 { ctx.setFillColor(rgb(0, 0, 0, 1 - edge)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H)) }
}

func withFrameContext(_ data: UnsafeMutableRawPointer?, bytesPerRow: Int, _ body: () -> Void) {
    ctx = CGContext(data: data, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

if let at = onlyFrame {
    withFrameContext(nil, bytesPerRow: 0) { renderFrame(at) }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: outURL)
    print("wrote frame \(at)")
    exit(0)
}

try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(W),
    kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
let frames = Int(duration * Double(FPS))
for f in 0..<frames {
    autoreleasepool {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        withFrameContext(CVPixelBufferGetBaseAddress(pb), bytesPerRow: CVPixelBufferGetBytesPerRow(pb)) {
            renderFrame(Double(f) / Double(FPS))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        while !input.isReadyForMoreMediaData { usleep(1000) }
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(FPS)))
    }
    if f % (FPS * 8) == 0 { print("frame \(f)/\(frames)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(outURL.path)" : "failed: \(writer.error?.localizedDescription ?? "?")")
