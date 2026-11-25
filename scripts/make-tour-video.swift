// Renders the Release Desk tour video from screenshots and Arabic or English
// captions: slow zooms into the part that matters, a glowing highlight,
// caption cards, crossfades. H.264, no audio.
//
// Usage: swift scripts/make-tour-video.swift tour.json out.mp4
//
// tour.json: { "icon": "AppIcon.png", "scenes": [
//   { "image": "shot.jpg", "title": "…", "body": "…", "duration": 7,
//     "focus": [x, y, w, h], "zoom": 1.5, "highlight": [x, y, w, h] },
//   { "title": "…", "body": "…", "lines": ["…"], "duration": 5 } ] }
// Rects are in the screenshot's own pixels, top-left origin.
import AppKit
import AVFoundation

struct Scene: Decodable {
    var image: String?
    var title: String
    var body: String?
    var lines: [String]?
    var duration: Double
    var focus: [Double]?
    var zoom: Double?
    var highlight: [Double]?
}

struct Tour: Decodable {
    var icon: String?
    var scenes: [Scene]
    var footer: String?
}

let args = CommandLine.arguments
let tourURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let tour = try JSONDecoder().decode(Tour.self, from: Data(contentsOf: tourURL))
let base = tourURL.deletingLastPathComponent()

let W = 1920, H = 1080, FPS = 30
let fade = 0.6

func load(_ path: String?) -> CGImage? {
    guard let path else { return nil }
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    guard let img = NSImage(contentsOf: url) else { fatalError("cannot read \(url.path)") }
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

let images = tour.scenes.map { load($0.image) }
let icon = load(tour.icon)

func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

// Top-left rect → Core Graphics (bottom-left) rect.
func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: CGFloat(H) - r.maxY, width: r.width, height: r.height) }

let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

func drawBackground(_ ctx: CGContext, time: Double) {
    let g = CGGradient(colorsSpace: space, colors: [rgb(0.04, 0.05, 0.12), rgb(0.10, 0.09, 0.28), rgb(0.05, 0.12, 0.24)] as CFArray,
                       locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
    // Two slow glows.
    for (i, c) in [rgb(0.36, 0.30, 0.95, 0.35), rgb(0.15, 0.70, 0.95, 0.22)].enumerated() {
        let t = time * 0.12 + Double(i) * 2.1
        let center = CGPoint(x: CGFloat(W) * (0.3 + 0.4 * CGFloat((sin(t) + 1) / 2)), y: CGFloat(H) * (0.35 + 0.35 * CGFloat((cos(t * 0.8) + 1) / 2)))
        let glow = CGGradient(colorsSpace: space, colors: [c, rgb(0, 0, 0, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 700, options: [])
    }
}

func paragraph(_ align: NSTextAlignment) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.alignment = align
    p.baseWritingDirection = .natural
    p.lineSpacing = 6
    return p
}

func isArabic(_ s: String) -> Bool { s.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) } }

/// Draws text into a top-left rect; Arabic right-aligned and right to left.
func drawText(_ s: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, align: NSTextAlignment? = nil) {
    let a = align ?? (isArabic(s) ? .right : .left)
    let p = paragraph(a) as! NSMutableParagraphStyle
    p.baseWritingDirection = isArabic(s) ? .rightToLeft : .leftToRight
    let attr = NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p,
    ])
    attr.draw(with: flip(rect), options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func textHeight(_ s: String, width: CGFloat, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
    let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .paragraphStyle: paragraph(.right)])
    return ceil(attr.boundingRect(with: CGSize(width: width, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
}

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

/// Window screenshot in its frame, zooming toward `focus` as the scene plays.
func drawShot(_ ctx: CGContext, _ img: CGImage, scene: Scene, progress: Double, time: Double) {
    let iw = CGFloat(img.width), ih = CGFloat(img.height)
    let maxH: CGFloat = 790, maxW: CGFloat = 1700
    let s0 = min(maxW / iw, maxH / ih)
    let fw = iw * s0, fh = ih * s0
    let frame = CGRect(x: (CGFloat(W) - fw) / 2, y: 56, width: fw, height: fh)

    // Shadow and frame.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(roundedPath(flip(frame), 16))
    ctx.setFillColor(rgb(0.1, 0.1, 0.15))
    ctx.fillPath()
    ctx.restoreGState()

    // Zoom: from the whole window to the focus rect.
    let z = scene.zoom ?? 1
    let e = ease(clamp((progress - 0.12) / 0.6))
    let scale = 1 + (z - 1) * e
    var cx = Double(iw) / 2, cy = Double(ih) / 2
    if let f = scene.focus, f.count == 4 {
        cx += (f[0] + f[2] / 2 - cx) * e
        cy += (f[1] + f[3] / 2 - cy) * e
    }
    // Keep the zoomed image covering the frame.
    let visW = Double(iw) / scale, visH = Double(ih) / scale
    cx = min(max(cx, visW / 2), Double(iw) - visW / 2)
    cy = min(max(cy, visH / 2), Double(ih) - visH / 2)
    let k = Double(s0) * scale
    let drawRect = CGRect(x: Double(frame.midX) - cx * k, y: Double(frame.midY) - cy * k, width: Double(iw) * k, height: Double(ih) * k)

    ctx.saveGState()
    ctx.addPath(roundedPath(flip(frame), 16))
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(img, in: flip(drawRect))
    // Highlight ring around the part being explained.
    if let h = scene.highlight, h.count == 4 {
        let appear = clamp((progress - 0.25) / 0.15)
        let r = CGRect(x: drawRect.minX + h[0] * k - 8, y: drawRect.minY + h[1] * k - 8, width: h[2] * k + 16, height: h[3] * k + 16)
        let pulse = 0.75 + 0.25 * sin(time * 3)
        ctx.addPath(roundedPath(flip(r), 14))
        ctx.setStrokeColor(rgb(0.45, 0.62, 1.0, CGFloat(appear * pulse)))
        ctx.setLineWidth(4)
        ctx.setShadow(offset: .zero, blur: 18, color: rgb(0.45, 0.62, 1.0, CGFloat(appear)))
        ctx.strokePath()
    }
    ctx.restoreGState()
    ctx.addPath(roundedPath(flip(frame), 16))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.14))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
}

func drawCaption(_ ctx: CGContext, scene: Scene, index: Int, count: Int) {
    let width: CGFloat = 1560
    let bodyH = scene.body.map { textHeight($0, width: width - 200, size: 27, weight: .regular) } ?? 0
    let h = 70 + bodyH + 34
    let rect = CGRect(x: (CGFloat(W) - width) / 2, y: CGFloat(H) - h - 30, width: width, height: h)
    ctx.saveGState()
    ctx.addPath(roundedPath(flip(rect), 26))
    ctx.setFillColor(rgb(0.06, 0.07, 0.14, 0.86))
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: rgb(0, 0, 0, 0.5))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(roundedPath(flip(rect), 26))
    ctx.setStrokeColor(rgb(1, 1, 1, 0.10))
    ctx.setLineWidth(1)
    ctx.strokePath()

    // Step chip on the left.
    let chip = CGRect(x: rect.minX + 28, y: rect.minY + 30, width: 92, height: 44)
    ctx.addPath(roundedPath(flip(chip), 22))
    ctx.setFillColor(rgb(0.36, 0.33, 0.95, 0.9))
    ctx.fillPath()
    drawText("\(index)/\(count)", in: chip.insetBy(dx: 0, dy: 8), size: 22, weight: .bold, color: .white, align: .center)

    drawText(scene.title, in: CGRect(x: rect.minX + 140, y: rect.minY + 22, width: width - 170, height: 56), size: 38, weight: .bold, color: .white)
    if let b = scene.body {
        drawText(b, in: CGRect(x: rect.minX + 140, y: rect.minY + 78, width: width - 170, height: bodyH + 10), size: 27, weight: .regular,
                 color: NSColor(white: 0.85, alpha: 1))
    }
}

func drawTitleScene(_ ctx: CGContext, scene: Scene, progress: Double) {
    let appear = ease(clamp(progress / 0.25))
    var y: CGFloat = 230
    if let icon {
        let size: CGFloat = 220 * CGFloat(0.85 + 0.15 * appear)
        let r = CGRect(x: (CGFloat(W) - size) / 2, y: y + (220 - size) / 2, width: size, height: size)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(appear))
        ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: rgb(0.4, 0.3, 1, 0.6))
        ctx.draw(icon, in: flip(r))
        ctx.restoreGState()
        y += 260
    }
    ctx.saveGState()
    ctx.setAlpha(CGFloat(appear))
    drawText(scene.title, in: CGRect(x: 160, y: y, width: CGFloat(W) - 320, height: 100), size: 76, weight: .heavy, color: .white, align: .center)
    y += 110
    if let b = scene.body {
        let h = textHeight(b, width: CGFloat(W) - 400, size: 34, weight: .medium)
        drawText(b, in: CGRect(x: 200, y: y, width: CGFloat(W) - 400, height: h + 10), size: 34, weight: .medium,
                 color: NSColor(white: 0.85, alpha: 1), align: .center)
        y += h + 40
    }
    if let lines = scene.lines {
        let boxW: CGFloat = 1240
        let lineH: CGFloat = 62
        let box = CGRect(x: (CGFloat(W) - boxW) / 2, y: y, width: boxW, height: CGFloat(lines.count) * lineH + 40)
        ctx.addPath(roundedPath(flip(box), 24))
        ctx.setFillColor(rgb(1, 1, 1, 0.07))
        ctx.fillPath()
        for (i, l) in lines.enumerated() {
            let a = ease(clamp((progress - 0.15 - Double(i) * 0.08) / 0.2))
            ctx.saveGState()
            ctx.setAlpha(CGFloat(a))
            drawText(l, in: CGRect(x: box.minX + 40, y: box.minY + 20 + CGFloat(i) * lineH + 8, width: boxW - 80, height: lineH),
                     size: 30, weight: .medium, color: .white)
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()
}

func drawFooter(_ ctx: CGContext) {
    guard let f = tour.footer else { return }
    drawText(f, in: CGRect(x: 40, y: 14, width: 600, height: 30), size: 18, weight: .semibold, color: NSColor(white: 1, alpha: 0.45), align: .left)
}

func render(_ ctx: CGContext, sceneIndex i: Int, local: Double, time: Double) {
    let scene = tour.scenes[i]
    let progress = local / scene.duration
    if let img = images[i] {
        drawShot(ctx, img, scene: scene, progress: progress, time: time)
        let shots = tour.scenes.filter { $0.image != nil }.count
        let n = tour.scenes[0...i].filter { $0.image != nil }.count
        drawCaption(ctx, scene: scene, index: n, count: shots)
    } else {
        drawTitleScene(ctx, scene: scene, progress: progress)
    }
}

// MARK: - Encode

try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let starts = tour.scenes.reduce(into: [Double]()) { acc, s in acc.append((acc.last ?? 0) + (acc.isEmpty ? 0 : tour.scenes[acc.count - 1].duration)) }
let total = (starts.last ?? 0) + (tour.scenes.last?.duration ?? 0)
let frames = Int(total * Double(FPS))

for f in 0..<frames {
    let t = Double(f) / Double(FPS)
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let pb = buffer else { fatalError("no buffer") }
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

    drawBackground(ctx, time: t)
    let i = starts.lastIndex(where: { $0 <= t }) ?? 0
    let local = t - starts[i]
    render(ctx, sceneIndex: i, local: local, time: t)
    // Crossfade into the next scene.
    let left = tour.scenes[i].duration - local
    if left < fade, i + 1 < tour.scenes.count {
        let a = ease(1 - left / fade)
        // The incoming frame, as one layer drawn over at rising alpha.
        ctx.saveGState()
        ctx.setAlpha(CGFloat(a))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawBackground(ctx, time: t)
        render(ctx, sceneIndex: i + 1, local: 0, time: t)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
    drawFooter(ctx)
    NSGraphicsContext.restoreGraphicsState()
    CVPixelBufferUnlockBaseAddress(pb, [])

    while !input.isReadyForMoreMediaData { usleep(2000) }
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(FPS)))
    if f % (FPS * 10) == 0 { print("frame \(f)/\(frames)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(outURL.path) · \(String(format: "%.0f", total)) s" : "failed: \(writer.error?.localizedDescription ?? "?")")
