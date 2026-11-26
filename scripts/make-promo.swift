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

// MARK: - Logos and icons

/// A tiny SVG path reader (M L H V C S A Z, absolute and relative), enough for the GitHub mark.
func svgPath(_ d: String) -> CGPath {
    let re = try! NSRegularExpression(pattern: "[MmLlHhVvCcSsAaZz]|-?(?:\\d+\\.?\\d*|\\.\\d+)")
    let tokens = re.matches(in: d, range: NSRange(d.startIndex..., in: d)).map { String(d[Range($0.range, in: d)!]) }
    let path = CGMutablePath()
    var i = 0, cmd = "M"
    var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint? = nil
    func num() -> Double { defer { i += 1 }; return Double(tokens[i])! }
    while i < tokens.count {
        if let c = tokens[i].first, c.isLetter { cmd = tokens[i]; i += 1; if cmd == "Z" || cmd == "z" { path.closeSubpath(); cur = start; lastCtrl = nil; continue } }
        let rel = cmd == cmd.lowercased()
        func pt(_ x: Double, _ y: Double) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
        switch cmd.uppercased() {
        case "M":
            cur = pt(num(), num()); start = cur; path.move(to: cur); cmd = rel ? "l" : "L"; lastCtrl = nil
        case "L": cur = pt(num(), num()); path.addLine(to: cur); lastCtrl = nil
        case "H": let x = num(); cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur); lastCtrl = nil
        case "V": let y = num(); cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur); lastCtrl = nil
        case "C":
            let c1 = pt(num(), num()), c2 = pt(num(), num()), e = pt(num(), num())
            path.addCurve(to: e, control1: c1, control2: c2); lastCtrl = c2; cur = e
        case "S":
            let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
            let c2 = pt(num(), num()), e = pt(num(), num())
            path.addCurve(to: e, control1: c1, control2: c2); lastCtrl = c2; cur = e
        case "A":
            var r = num(); _ = num(); _ = num(); let large = num() != 0, sweep = num() != 0
            let e = pt(num(), num())
            let x1 = (cur.x - e.x) / 2, y1 = (cur.y - e.y) / 2
            let lam = (x1 * x1 + y1 * y1) / (r * r); if lam > 1 { r *= sqrt(lam) }
            let sq = max(0, (r * r * r * r - r * r * y1 * y1 - r * r * x1 * x1) / (r * r * y1 * y1 + r * r * x1 * x1))
            let coef = (large != sweep ? 1.0 : -1.0) * sqrt(sq)
            let c = CGPoint(x: coef * y1 + (cur.x + e.x) / 2, y: -coef * x1 + (cur.y + e.y) / 2)
            path.addArc(center: c, radius: r, startAngle: atan2(cur.y - c.y, cur.x - c.x), endAngle: atan2(e.y - c.y, e.x - c.x), clockwise: !sweep)
            cur = e; lastCtrl = nil
        default: i += 1
        }
    }
    return path
}

let githubMark = svgPath("M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z")

let materialIcons: CTFont? = {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
    let root = ProcessInfo.processInfo.environment["FLUTTER_ROOT"] ?? "\(home)/flutter"
    guard let data = FileManager.default.contents(atPath: "\(root)/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf"),
          let provider = CGDataProvider(data: data as CFData), let font = CGFont(provider) else { return nil }
    return CTFontCreateWithGraphicsFont(font, 100, nil, nil)
}()

enum Logo { case apple, play, github, android, windows, linux, testflight, app(String), sym(String, (Double, Double, Double)) }

var appIcons: [String: NSImage] = [:]
func appIcon(_ path: String) -> NSImage {
    if let i = appIcons[path] { return i }
    let i = NSWorkspace.shared.icon(forFile: path)
    i.size = NSSize(width: 512, height: 512)
    appIcons[path] = i
    return i
}

/// Draws a logo inside a square, in the top-left (flipped) context.
func drawLogo(_ l: Logo, in r: CGRect, alpha: Double = 1) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    switch l {
    case .apple:
        symbol("apple.logo", r.insetBy(dx: r.width * 0.06, dy: r.width * 0.06), color: .white)
    case .github:
        let k = r.width / 16
        ctx.translateBy(x: r.minX, y: r.minY); ctx.scaleBy(x: k, y: k)
        ctx.addPath(githubMark); ctx.setFillColor(rgb(1, 1, 1)); ctx.fillPath()
    case .play:
        // The four-colour play triangle, corners softened.
        let a = CGPoint(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.04), b = CGPoint(x: a.x, y: r.maxY - r.height * 0.04)
        let c = CGPoint(x: r.maxX - r.width * 0.04, y: r.midY)
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: a.x, y: r.midY))
        tri.addArc(tangent1End: a, tangent2End: c, radius: r.width * 0.08)
        tri.addArc(tangent1End: c, tangent2End: b, radius: r.width * 0.08)
        tri.addArc(tangent1End: b, tangent2End: a, radius: r.width * 0.08)
        tri.closeSubpath()
        ctx.addPath(tri); ctx.clip()
        let o = CGPoint(x: a.x + (c.x - a.x) * 0.52, y: r.midY)
        let q = CGPoint(x: a.x + (c.x - a.x) * 0.70, y: a.y + (c.y - a.y) * 0.70)
        let s = CGPoint(x: q.x, y: r.maxY - (q.y - r.minY))
        func poly(_ pts: [CGPoint], _ col: CGColor) {
            ctx.move(to: pts[0]); pts.dropFirst().forEach { ctx.addLine(to: $0) }; ctx.closePath(); ctx.setFillColor(col); ctx.fillPath()
        }
        let far = r.width * 2
        poly([CGPoint(x: a.x - far, y: a.y - far), CGPoint(x: q.x + far * 0.2, y: q.y - far), q, o, CGPoint(x: a.x - far, y: r.midY)], rgb(0.20, 0.66, 0.33)) // green, top
        poly([CGPoint(x: a.x - far, y: b.y + far), CGPoint(x: s.x + far * 0.2, y: s.y + far), s, o, CGPoint(x: a.x - far, y: r.midY)], rgb(0.92, 0.26, 0.21)) // red, bottom
        poly([o, q, CGPoint(x: c.x + far, y: q.y), CGPoint(x: c.x + far, y: s.y), s], rgb(0.98, 0.74, 0.02)) // yellow, tip
        poly([CGPoint(x: a.x - far, y: a.y - far), o, CGPoint(x: a.x - far, y: b.y + far)], rgb(0.26, 0.52, 0.96)) // blue, left
        _ = s
    case .android:
        if let f = materialIcons {
            var ch: UniChar = 0xE085, g: CGGlyph = 0
            CTFontGetGlyphsForCharacters(f, &ch, &g, 1)
            let size = r.width
            let sized = CTFontCreateCopyWithAttributes(f, size, nil, nil)
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.maxY - size * 0.0)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setFillColor(rgb(0.24, 0.86, 0.52))
            ctx.textMatrix = .identity   // text drawn earlier leaves its own matrix behind
            var pos = CGPoint.zero
            CTFontDrawGlyphs(sized, &g, &pos, 1, ctx)
            ctx.restoreGState()
        } else {
            symbol("cpu", r, color: ns((0.24, 0.86, 0.52)))
        }
    case .windows:
        let gap = r.width * 0.06, s = (r.width * 0.84 - gap) / 2, x0 = r.minX + r.width * 0.08, y0 = r.minY + r.width * 0.08
        let blue = rgb(0.0, 0.55, 0.95)
        for (i, j) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            ctx.setFillColor(blue); ctx.fill(CGRect(x: x0 + Double(i) * (s + gap), y: y0 + Double(j) * (s + gap), width: s, height: s))
        }
    case .linux:
        let a = NSAttributedString(string: "🐧", attributes: [.font: NSFont(name: "Apple Color Emoji", size: r.width * 1.0)!])
        let sz = a.size()
        a.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2))
    case .testflight:
        symbol("airplane", r.insetBy(dx: r.width * 0.08, dy: r.width * 0.08), color: ns((0.35, 0.75, 1.0)))
    case .app(let path):
        appIcon(path).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    case .sym(let name, let c):
        symbol(name, r.insetBy(dx: r.width * 0.06, dy: r.width * 0.06), color: ns(c).blended(withFraction: 0.3, of: .white)!)
    }
    ctx.restoreGState()
}

/// A logo on a glass tile, popping in on a spring. App icons come without a tile.
func logoTile(_ l: Logo, cx: Double, cy: Double, size: Double, t: Double, at start: Double, out: Double? = nil, glow: (Double, Double, Double)? = nil) {
    var p = spring(prog(t, start, 0.55))
    if let out { p *= 1 - easeIn(prog(t, out, 0.3)) }
    guard p > 0.001 else { return }
    ctx.saveGState()
    ctx.translateBy(x: cx, y: cy)
    ctx.scaleBy(x: p, y: p)
    ctx.setAlpha(clamp(prog(t, start, 0.15)))
    if case .app = l {
        ctx.setShadow(offset: CGSize(width: 0, height: size * 0.08), blur: size * 0.25, color: rgb(0, 0, 0, 0.5))
        drawLogo(l, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
    } else {
        let r = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
        let path = CGPath(roundedRect: r, cornerWidth: size * 0.24, cornerHeight: size * 0.24, transform: nil)
        let g = glow ?? (0.5, 0.5, 0.9)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: size * 0.08), blur: size * 0.35, color: rgb(g.0, g.1, g.2, 0.45))
        ctx.addPath(path); ctx.setFillColor(rgb(0.09, 0.09, 0.16, 0.95)); ctx.fillPath()
        ctx.restoreGState()
        let hl = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.14), rgb(1, 1, 1, 0.02)] as CFArray, locations: [0, 1])!
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(rgb(1, 1, 1, 0.22)); ctx.setLineWidth(max(1.5, size * 0.012)); ctx.strokePath()
        drawLogo(l, in: r.insetBy(dx: size * 0.22, dy: size * 0.22))
    }
    ctx.restoreGState()
}

/// A row of logo tiles centred on cx (or ending at `right` for right-aligned rows).
func logoRow(_ ls: [Logo], cx: Double? = nil, right: Double? = nil, cy: Double, size: Double, gap: Double = 28, t: Double, at start: Double, step: Double = 0.18) {
    let total = Double(ls.count) * size + Double(ls.count - 1) * gap
    let x0 = right.map { $0 - total } ?? ((cx ?? W / 2) - total / 2)
    for (i, l) in ls.enumerated() {
        // Right-to-left reading: the first logo sits on the right.
        let x = x0 + Double(ls.count - 1 - i) * (size + gap) + size / 2
        logoTile(l, cx: x, cy: cy, size: size, t: t, at: start + Double(i) * step)
    }
}

let xcodeApp = "/Applications/Xcode.app", studioApp = "/Applications/Android Studio.app"
let terminalApp = "/System/Applications/Utilities/Terminal.app", keychainApp = "/System/Library/CoreServices/Applications/Keychain Access.app"

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
             callout region: (Double, Double, Double, Double)? = nil, calloutLabel: String? = nil, logos: [Logo] = [], kickLogo: Logo? = nil,
             extra: ((Double, Projector) -> Void)? = nil) {
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
    if let kickLogo { logoTile(kickLogo, cx: tx + tw - 34, cy: 238, size: 68, t: t, at: 0.2, glow: color) }
    else { kicker(kick, x: tx, y: 250, width: tw, t: t, at: 0.25, color: color) }
    logoRow(logos, right: tx + tw, cy: 660, size: 96, gap: 24, t: t, at: 1.2)
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
    let cy = lerp(430, 290, lift)
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
    let word = "Release Desk"
    let sizeW = 104.0
    let total = textWidth(word, size: sizeW, weight: .heavy)
    var x = W / 2 - total / 2
    for (i, ch) in word.enumerated() {
        let s = String(ch)
        let cw = textWidth(s, size: sizeW, weight: .heavy)
        let lp = easeOut(prog(t, 2.4 + Double(i) * 0.06, 0.5))
        if lp > 0 {
            text(s, x: x, y: lerp(640, 540, lift) + (1 - lp) * 60, width: cw + 10, size: sizeW, weight: .heavy, alpha: lp, align: .left)
        }
        x += cw
    }
    reveal("ارفع على الستورين بدوسة واحدة", x: 200, y: lerp(800, 690, lift), width: W - 400, size: 54, weight: .heavy,
           color: NSColor(white: 0.92, alpha: 1), t: t, at: 4.2)
    logoRow([.apple, .play], cx: W / 2, cy: 880, size: 110, gap: 40, t: t, at: 5.2, step: 0.4)
})

// 8–16: the mess, then the turn
enum Bit { case word(String, Double), logo(Logo, Double) }
let mess: [(Bit, Double, Double, Double)] = [   // what, x, y, rotation
    (.logo(.app(xcodeApp), 150), 300, 230, -8), (.word("سكريبتات", 66), 1180, 240, 4), (.word("Keystore", 50), 760, 150, -6),
    (.logo(.app(terminalApp), 130), 1630, 210, 7), (.logo(.apple, 120), 720, 440, -5), (.word("مفاتيح", 64), 300, 470, 4),
    (.logo(.testflight, 110), 1180, 450, 6), (.word("توقيع", 62), 1620, 470, -5), (.logo(.play, 120), 330, 710, 5),
    (.word("رفع يدوي", 56), 760, 720, -4), (.logo(.app(studioApp), 140), 1200, 690, -6), (.word("ExportOptions.plist", 40), 1620, 720, 3),
    (.logo(.app(keychainApp), 120), 520, 930, -4), (.word("استنى…", 60), 1000, 940, -2), (.word("Provisioning Profile", 40), 1500, 930, 4),
]
scenes.append(Scene(start: 8, end: 16) { t, g in
    let collapse = easeIn(prog(t, 5.4, 0.7))
    for (i, m) in mess.enumerated() {
        let at = Double(i) * 0.34
        let p = spring(prog(t, at, 0.45))
        guard p > 0 else { continue }
        let shake = sin(g * 23 + Double(i)) * 2 * (1 - collapse)
        let x = lerp(m.1, W / 2, collapse), y = lerp(m.2, H / 2, collapse)
        ctx.saveGState()
        ctx.translateBy(x: x + shake, y: y)
        ctx.rotate(by: (m.3 + collapse * 40) * .pi / 180)
        let k = p * (1 - collapse * 0.9)
        ctx.scaleBy(x: k, y: k)
        ctx.setAlpha(1 - collapse)
        switch m.0 {
        case .word(let w, let size):
            let width = textWidth(w, size: size, weight: .heavy) + 40
            text(w, x: -width / 2, y: -size * 0.7, width: width, size: size, weight: .heavy,
                 color: NSColor(white: 0.7 + 0.3 * Double(i % 3) / 2, alpha: 1), alpha: 0.9 - 0.25 * Double(i % 2), align: .center)
        case .logo(let l, let size):
            logoTile(l, cx: 0, cy: 0, size: size, t: 5, at: 0)
        }
        ctx.restoreGState()
    }
    reveal("كل الدوشة دي…", x: 200, y: 380, width: W - 400, size: 96, weight: .heavy, t: t, at: 6.0, dur: 0.5)
    reveal("خلّصها من شاشة واحدة.", x: 200, y: 520, width: W - 400, size: 96, weight: .heavy, color: ns(cyan), t: t, at: 6.6, dur: 0.5)
})

// 16–32: four features, one per two bars
scenes.append(Scene(start: 16, end: 20) { t, _ in
    feature(t, 0, kick: "الأكونتات", title: "كل أكونتاتك وتيماتك\nقدام عينك", body: "وكل تيم لوحده، من غير لخبطة.",
            screenName: "dark-01-overview", color: indigo, callout: (0.005, 0.17, 0.165, 0.36), calloutLabel: "تيماتك هنا",
            logos: [.apple, .play])
})
scenes.append(Scene(start: 20, end: 24) { t, _ in
    feature(t, 0, kick: "الرفع", title: "دوسة واحدة\nيبني ويمضي ويرفع", body: "ويضيف التسترز، ويكتب What to Test، ويبعته للريفيو كمان.",
            screenName: "dark-05-ship-ios", color: violet, focus: (0.92, 0.938), zoomTo: 1.6, zoomAt: 1.1, logos: [.testflight, .apple]) { t, proj in
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
    feature(t, 0, kick: "المتابعة", title: "تابع كل خطوة\nأول بأول", body: "ولو حاجة وقفت، تكمّل من مكانها.",
            screenName: done ? "dark-09-console-succeeded" : "dark-09-console-running", color: done ? mint : cyan) { t, _ in
        // Build → upload → TestFlight, lighting up one after another.
        let steps: [Logo] = [.sym("hammer.fill", violet), .sym("icloud.and.arrow.up.fill", cyan), .testflight]
        let right = 1850.0, size = 96.0, gap = 70.0
        for (i, l) in steps.enumerated() {
            let cx = right - size / 2 - Double(i) * (size + gap)
            logoTile(l, cx: cx, cy: 660, size: size, t: t, at: 1.0 + Double(i) * 0.3, glow: mint)
            let lit = prog(t, 1.3 + Double(i) * 0.3, 0.3)
            if lit > 0 {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 16, color: rgb(mint.0, mint.1, mint.2, 0.9))
                ctx.setFillColor(rgb(mint.0, mint.1, mint.2, lit))
                ctx.fillEllipse(in: CGRect(x: cx + size / 2 - 22, y: 660 - size / 2 - 8, width: 30, height: 30))
                ctx.restoreGState()
                symbol("checkmark", CGRect(x: cx + size / 2 - 15, y: 660 - size / 2 - 1, width: 16, height: 16), color: NSColor(white: 0.05, alpha: 1), alpha: lit, weight: .black)
            }
            if i < steps.count - 1 {
                symbol("chevron.left", CGRect(x: cx - size / 2 - gap / 2 - 13, y: 646, width: 26, height: 28), color: NSColor(white: 1, alpha: 0.6),
                       alpha: clamp(prog(t, 1.2 + Double(i) * 0.3, 0.3)))
            }
        }
    }
    let sp = spring(prog(t, 2.05, 0.5))
    if sp > 0 {
        ctx.saveGState()
        ctx.translateBy(x: 1010, y: 300)
        ctx.rotate(by: -8 * .pi / 180)
        ctx.scaleBy(x: sp, y: sp)
        pill(CGRect(x: -140, y: -44, width: 280, height: 88), fill: rgb(mint.0, mint.1, mint.2, 0.95))
        text("اترفع!", x: -110, y: -36, width: 160, size: 46, weight: .black, color: NSColor(white: 0.05, alpha: 1), align: .right)
        symbol("checkmark", CGRect(x: 66, y: -20, width: 40, height: 40), color: NSColor(white: 0.05, alpha: 1), weight: .black)
        ctx.restoreGState()
    }
})
scenes.append(Scene(start: 28, end: 32) { t, _ in
    feature(t, 0, kick: "", title: "كل الـ tracks\nفي حتة واحدة", body: "نزّلها للكل، أو بالتدريج، أو خليها درافت.",
            screenName: "light-03-play", color: mint, callout: (0.44, 0.29, 0.207, 0.175), calloutLabel: "بالتدريج", kickLogo: .play) { t, _ in
        // A staged rollout climbing to everyone.
        let a = easeOut(prog(t, 1.2, 0.4))
        guard a > 0 else { return }
        let stops = [5.0, 20, 50, 100]
        let k = min(3, Int(max(0, (t - 1.6) / 0.5)))
        let from = k == 0 ? 0 : stops[k - 1], to = stops[k]
        let v = lerp(from, to, easeOut(prog(t, 1.6 + Double(k) * 0.5, 0.35)))
        let bar = CGRect(x: 1850 - 460, y: 640, width: 460, height: 40)
        ctx.saveGState(); ctx.setAlpha(a)
        pill(bar, fill: rgb(1, 1, 1, 0.10), stroke: rgb(1, 1, 1, 0.2))
        // Fills from the right, as Arabic reads.
        let fw = max(bar.height, bar.width * v / 100)
        pill(CGRect(x: bar.maxX - fw, y: bar.minY, width: fw, height: bar.height), fill: rgb(mint.0, mint.1, mint.2, 0.95))
        text("\u{200E}\(Int(v.rounded()))%", x: bar.minX - 150, y: bar.minY - 6, width: 135, size: 36, weight: .heavy, color: ns(mint).blended(withFraction: 0.3, of: .white)!, align: .right)
        ctx.restoreGState()
    }
})

// 32–40: no Mac? GitHub builds it.
scenes.append(Scene(start: 32, end: 36) { t, g in
    reveal("معندكش ماك؟", x: 200, y: 280, width: W - 400, size: 120, weight: .heavy, t: t, at: 0.1, dur: 0.6, out: 1.6)
    reveal("ولا يهمك.", x: 200, y: 470, width: W - 400, size: 80, weight: .heavy, color: ns(cyan), t: t, at: 0.8, dur: 0.5, out: 1.6)
    let p = easeOut(prog(t, 1.9, 0.7))
    if p > 0 {
        let y = 480.0
        logoTile(.github, cx: 640, cy: y, size: 200, t: t, at: 1.9, glow: cyan)
        ctx.setStrokeColor(rgb(1, 1, 1, 0.25 * p)); ctx.setLineWidth(3); ctx.setLineDash(phase: -g * 60, lengths: [14, 12])
        ctx.move(to: CGPoint(x: 770, y: y)); ctx.addLine(to: CGPoint(x: 1190, y: y)); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
        for k in 0..<3 {
            let q = ((g * 0.9 + Double(k) / 3).truncatingRemainder(dividingBy: 1))
            ctx.setFillColor(rgb(cyan.0, cyan.1, cyan.2, p * (1 - abs(q - 0.5) * 1.6)))
            ctx.fillEllipse(in: CGRect(x: 770 + q * 420 - 9, y: y - 9, width: 18, height: 18))
        }
        let phone = CGRect(x: 1230, y: y - 130, width: 140, height: 260)
        ctx.saveGState(); ctx.setAlpha(p)
        ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.setFillColor(rgb(0.08, 0.08, 0.14)); ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 30, cornerHeight: 30, transform: nil))
        ctx.setStrokeColor(rgb(1, 1, 1, 0.85)); ctx.setLineWidth(5); ctx.strokePath()
        pill(CGRect(x: phone.midX - 24, y: phone.minY + 14, width: 48, height: 12), fill: rgb(1, 1, 1, 0.85))
        ctx.restoreGState()
        let ip = spring(prog(t, 2.9, 0.6))
        if ip > 0 { drawCG(icon, CGRect(x: phone.midX - 40 * ip, y: y - 40 * ip, width: 80 * ip, height: 80 * ip)) }
        logoRow([.apple, .android], cx: phone.midX, cy: y + 200, size: 70, gap: 18, t: t, at: 2.4)
    }
    reveal("GitHub يبني ويرفع بدالك", x: 200, y: 760, width: W - 400, size: 66, t: t, at: 2.3)
})
scenes.append(Scene(start: 36, end: 40) { t, _ in
    let enter = easeOut(prog(t, 0, 0.9))
    screen("dark-05-ship-ios", cx: lerp(620, 700, enter), cy: 560, width: 1150, rotY: lerp(-30, -6, enter), rotX: lerp(4, 0, enter),
           alpha: clamp(t / 0.3), zoom: lerp(1, 2.2, easeInOut(prog(t, 0.5, 1.4))), focus: (0.376, 0.563), glow: cyan)
    logoTile(.github, cx: 1816, cy: 238, size: 68, t: t, at: 0.2, glow: cyan)
    reveal("بيظبطهولك\nمن نفس الشاشة", x: 1330, y: 300, width: 520, size: 54, t: t, at: 0.5, align: .right)
    let labels = ["سجّلت دخول", "الـ workflow جاهز", "الـ secrets اتحطت"]
    for (i, l) in labels.enumerated() {
        chip(l, icon: "checkmark.circle.fill", cx: 1650, cy: 540 + Double(i) * 84, t: t, at: 1.6 + Double(i) * 0.35, tint: mint)
    }
})

// 40–56: everything else, fast
let grid: [(String, Logo, (Double, Double, Double))] = [
    ("ابعت للريفيو", .apple, indigo), ("أبلكيشن جديد في دقايق", .sym("sparkles", violet), violet),
    ("Android من GitHub", .android, mint), ("وضع الخصوصية", .sym("eye.slash.fill", mint), mint),
    ("تتنقّل في ثانية \u{200E}⌘K", .sym("command", indigo), indigo), ("ينبهك لما يخلص", .sym("bell.badge.fill", violet), violet),
]
scenes.append(Scene(start: 40, end: 44) { t, g in
    reveal("ولسه في كمان", x: 200, y: 110, width: W - 400, size: 76, t: t, at: 0)
    for (i, f) in grid.enumerated() {
        let col = Double(i % 3), row = Double(i / 3)
        let cx = 1500 - col * 540, cy = 430 + row * 300   // right to left
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
        drawLogo(f.1, in: CGRect(x: -42, y: -90, width: 84, height: 84))
        text(f.0, x: -215, y: 18, width: 430, size: 34, weight: .bold, align: .center)
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
    reveal("يخبّي الأسامي والـ IDs\nوشيّر شاشتك وانت مطمّن.", x: 1330, y: 480, width: 520, size: 32,
           weight: .medium, color: NSColor(white: 0.85, alpha: 1), t: t, at: 0.9, align: .right)
})
scenes.append(Scene(start: 48, end: 52) { t, g in
    let names = ["light-01-overview", "dark-02-app", "light-06-ship-play"]
    for (i, n) in names.enumerated() {
        let p = easeOut(prog(t, Double(i) * 0.25, 0.9))
        let cx = 420 + Double(i) * 540, cy = 520 + sin(g * 1.4 + Double(i)) * 10
        screen(n, cx: cx, cy: lerp(cy + 200, cy, p), width: 500, rotY: lerp(30, Double(i - 1) * -14, p), rotZ: Double(i - 1) * 2,
               alpha: p, glow: [indigo, violet, mint][i])
    }
    reveal("شغّال على أي جهاز", x: 200, y: 110, width: W - 400, size: 76, t: t, at: 0.3)
    logoRow([.apple, .windows, .linux], cx: W / 2, cy: 870, size: 120, gap: 60, t: t, at: 1.3, step: 0.3)
})
scenes.append(Scene(start: 52, end: 56) { t, _ in
    let p = easeOut(prog(t, 0, 0.9))
    screen("dark-11-connect-apple", cx: lerp(520, 640, p), cy: 560, width: 980, rotY: lerp(-30, -12, p), alpha: clamp(t / 0.3), glow: indigo)
    logoTile(.app(keychainApp), cx: 1560, cy: 290, size: 170, t: t, at: 0.7)
    reveal("مفاتيحك مابتخرجش\nمن جهازك", x: 1180, y: 410, width: 640, size: 58, t: t, at: 1.0, align: .right)
    reveal("متشالة في الـ Keychain، ومابتروحش غير هنا:", x: 1180, y: 590, width: 640, size: 30,
           weight: .medium, color: NSColor(white: 0.85, alpha: 1), t: t, at: 1.4, align: .right)
    logoRow([.apple, .play, .github], right: 1820, cy: 720, size: 92, gap: 24, t: t, at: 1.8)
})

// 56–64: end card
scenes.append(Scene(start: 56, end: 64) { t, _ in
    let p = spring(prog(t, 0.1, 0.9))
    let size = 200 * p
    if size > 1 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 90, color: rgb(0.45, 0.35, 1, 0.85))
        drawCG(icon, CGRect(x: W / 2 - size / 2, y: 250 - size / 2, width: size, height: size))
        ctx.restoreGState()
    }
    reveal("Release Desk", x: 200, y: 380, width: W - 400, size: 110, t: t, at: 0.5)
    reveal("ببلاش، والكود مفتوح للكل", x: 200, y: 540, width: W - 400, size: 54, weight: .heavy, color: ns(cyan), t: t, at: 1.0)
    let up = easeOut(prog(t, 1.6, 0.6))
    if up > 0 {
        let label = "github.com/youssef-mohamed07/release-desk"
        let w = textWidth(label, size: 34, weight: .semibold) + 120
        let r = CGRect(x: W / 2 - w / 2, y: 670 + (1 - up) * 30, width: w, height: 76)
        ctx.saveGState(); ctx.setAlpha(up)
        pill(r, fill: rgb(1, 1, 1, 0.08), stroke: rgb(1, 1, 1, 0.25))
        drawLogo(.github, in: CGRect(x: r.minX + 26, y: r.midY - 20, width: 40, height: 40))
        text(label, x: r.minX + 86, y: r.minY + 15, width: w - 100, size: 34, weight: .semibold, align: .left)
        ctx.restoreGState()
    }
    logoRow([.apple, .windows, .linux], cx: W / 2, cy: 860, size: 84, gap: 30, t: t, at: 2.2, step: 0.2)
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
    withFrameContext(nil, bytesPerRow: 0) {
        if at < 0 {
            background(0, tint: indigo, energy: 0.3)
            let all: [Logo] = [.apple, .play, .github, .android, .windows, .linux, .testflight, .app(xcodeApp), .app(studioApp), .app(terminalApp), .app(keychainApp), .sym("lock.fill", indigo)]
            for (i, l) in all.enumerated() { logoTile(l, cx: 200 + Double(i % 6) * 300, cy: 300 + Double(i / 6) * 400, size: 200, t: 5, at: 0) }
        } else { renderFrame(at) }
    }
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
