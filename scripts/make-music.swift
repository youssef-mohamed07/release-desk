// An original, royalty-free soundtrack for the Release Desk promo, made
// entirely from oscillators and noise: pads, bass, a plucked arpeggio, a lead,
// and synthesized drums, at 120 BPM so every bar is exactly two seconds.
//
// Usage: swiftc -O scripts/make-music.swift -o /tmp/make-music && /tmp/make-music out.wav [bars]
import Foundation

let sr = 44_100.0
let bpm = 120.0
let beat = 60.0 / bpm
let bar = beat * 4
let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "music.wav"
let bars = args.count > 2 ? Int(args[2]) ?? 31 : 31
let total = Int(Double(bars) * bar * sr) + Int(2.5 * sr)
var L = [Float](repeating: 0, count: total)
var R = [Float](repeating: 0, count: total)
var sendL = [Float](repeating: 0, count: total)   // reverb send
var sendR = [Float](repeating: 0, count: total)
var duck = [Float](repeating: 1, count: total)    // sidechain from the kick

// Sections, in bars.
enum Part { case intro, build, drop, breakdown, drop2, outro }
func part(_ b: Int) -> Part {
    switch b {
    case 0..<4: .intro
    case 4..<8: .build
    case 8..<16: .drop
    case 16..<20: .breakdown
    case 20..<28: .drop2
    default: .outro
    }
}

func midi(_ n: Double) -> Double { 440 * pow(2, (n - 69) / 12) }
// Am – F – C – G, voiced around middle C.
let chords: [[Double]] = [[57, 60, 64, 69], [53, 57, 60, 65], [48, 55, 60, 64], [55, 59, 62, 67]]
let roots: [Double] = [45, 41, 48, 43]

var rng = SystemRandomNumberGenerator()
func noise() -> Double { Double.random(in: -1...1, using: &rng) }

// PolyBLEP saw, band-limited enough for music.
struct Saw {
    var phase = Double.random(in: 0..<1)
    mutating func next(_ f: Double) -> Double {
        let dt = f / sr
        phase += dt
        if phase >= 1 { phase -= 1 }
        var v = 2 * phase - 1
        if phase < dt { let t = phase / dt; v -= t + t - t * t - 1 }
        else if phase > 1 - dt { let t = (phase - 1) / dt; v -= t * t + t + t + 1 }
        return v
    }
}

// State variable filter (Chamberlin), lowpass / bandpass / highpass.
struct SVF {
    var low = 0.0, band = 0.0
    mutating func run(_ x: Double, cutoff: Double, q: Double) -> (lp: Double, bp: Double, hp: Double) {
        let f = 2 * sin(Double.pi * min(cutoff, sr / 6) / sr)
        low += f * band
        let high = x - low - q * band
        band += f * high
        return (low, band, high)
    }
}

func add(_ i: Int, _ l: Double, _ r: Double, send: Double = 0, ducked: Bool = false) {
    guard i >= 0, i < total else { return }
    let d = ducked ? Double(duck[i]) : 1
    L[i] += Float(l * d)
    R[i] += Float(r * d)
    if send > 0 { sendL[i] += Float(l * d * send); sendR[i] += Float(r * d * send) }
}

func at(_ seconds: Double) -> Int { Int(seconds * sr) }

// MARK: Drums (first, so the kick can drive the sidechain)

func kick(_ t0: Double, gain: Double = 1) {
    let n = at(0.45)
    var ph = 0.0
    for k in 0..<n {
        let t = Double(k) / sr
        let f = 45 + 95 * exp(-t * 28)
        ph += 2 * .pi * f / sr
        let amp = exp(-t * 7.5) * gain
        let click = k < 220 ? noise() * 0.25 * (1 - Double(k) / 220) : 0
        let v = (sin(ph) * amp + click) * 0.9
        add(at(t0) + k, v, v)
    }
    // Duck the music under the kick.
    for k in 0..<at(0.3) where at(t0) + k < total {
        let g = Float(0.35 + 0.65 * pow(Double(k) / Double(at(0.3)), 0.7))
        duck[at(t0) + k] = min(duck[at(t0) + k], g)
    }
}

func clap(_ t0: Double, gain: Double = 0.5) {
    var f = SVF()
    for k in 0..<at(0.3) {
        let t = Double(k) / sr
        // Three quick bursts, then a tail.
        let burst = t < 0.03 ? (sin(t * 2 * .pi * 100) > 0 ? 1.0 : 0.4) : exp(-(t - 0.03) * 16)
        let v = f.run(noise(), cutoff: 1600, q: 0.7).bp * burst * gain
        add(at(t0) + k, v * 0.9, v, send: 0.35)
    }
}

func hat(_ t0: Double, open: Bool = false, gain: Double = 0.16, pan: Double = 0.1) {
    var f = SVF()
    let len = open ? 0.28 : 0.045
    for k in 0..<at(len) {
        let t = Double(k) / sr
        let v = f.run(noise(), cutoff: 9000, q: 0.5).hp * exp(-t * (open ? 11 : 75)) * gain
        add(at(t0) + k, v * (1 - pan), v * (1 + pan))
    }
}

func riser(_ t0: Double, bars n: Double, gain: Double = 0.22) {
    var f = SVF()
    let len = n * bar
    for k in 0..<at(len) {
        let p = Double(k) / Double(at(len))
        let v = f.run(noise(), cutoff: 400 + 7000 * p * p, q: 0.25).bp * p * p * gain
        add(at(t0) + k, v, v, send: 0.4)
    }
}

func downlifter(_ t0: Double, gain: Double = 0.2) {
    var f = SVF()
    for k in 0..<at(2.5) {
        let p = Double(k) / Double(at(2.5))
        let v = f.run(noise(), cutoff: 6000 * (1 - p) + 200, q: 0.3).bp * (1 - p) * gain
        add(at(t0) + k, v, v, send: 0.5)
    }
}

for b in 0..<bars {
    let p = part(b)
    let t = Double(b) * bar
    switch p {
    case .drop, .drop2:
        for q in 0..<4 { kick(t + Double(q) * beat) }
        clap(t + beat); clap(t + 3 * beat)
        for s in 0..<8 { hat(t + Double(s) * beat / 2 + beat / 2 * 0.5, gain: 0.065, pan: s % 2 == 0 ? 0.3 : -0.3) }
        for q in 0..<4 { hat(t + Double(q) * beat + beat / 2, open: q == 3, gain: 0.055) }
    case .build:
        if b >= 6 { for q in 0..<4 { kick(t + Double(q) * beat, gain: 0.8) } }
        for s in 0..<8 { hat(t + Double(s) * beat / 2, gain: 0.045 + 0.012 * Double(b - 4)) }
        if b == 7 {
            // Snare roll into the drop.
            for s in 0..<16 { clap(t + Double(s) * beat / 4, gain: 0.12 + 0.025 * Double(s)) }
            riser(t - bar, bars: 2)
        }
    case .breakdown:
        if b == 19 {
            for s in 0..<16 { clap(t + Double(s) * beat / 4, gain: 0.1 + 0.02 * Double(s)) }
            riser(t - bar, bars: 2)
        }
    case .intro:
        if b == 3 { riser(t - bar * 0.5, bars: 1.5, gain: 0.12) }
    case .outro:
        if b == 28 { kick(t, gain: 0.9) }
    }
    if b == 16 { downlifter(t) }
}

// MARK: Pad

var padSaws = [[Saw]](repeating: [Saw(), Saw(), Saw()], count: 8)
var padFilterL = SVF(), padFilterR = SVF()
for i in 0..<total {
    let time = Double(i) / sr
    let b = Int(time / bar)
    guard b < bars + 1 else { break }
    let c = chords[min(b, bars - 1) % 4]
    let inBar = time - Double(b) * bar
    let env = min(1, inBar / 0.35) * (b >= bars ? max(0, 1 - (time - Double(bars) * bar) / 2.0) : 1)
    var l = 0.0, r = 0.0
    for (v, n) in c.enumerated() {
        let f = midi(n)
        l += padSaws[v][0].next(f * 0.996) + padSaws[v][1].next(f * 1.002)
        r += padSaws[v + 4][0].next(f * 1.004) + padSaws[v + 4][1].next(f * 0.998)
    }
    let p = part(min(b, bars - 1))
    let open: Double
    switch p {
    case .intro: open = 350 + 1800 * (time / (4 * bar))
    case .build: open = 1800 + 1200 * ((time - 4 * bar) / (4 * bar))
    case .drop, .drop2: open = 3200
    case .breakdown: open = 1200 + 600 * sin(time * 1.3)
    case .outro: open = 2200
    }
    let gain = (p == .drop || p == .drop2 ? 0.05 : 0.065) * env
    let fl = padFilterL.run(l, cutoff: open, q: 0.9).lp * gain
    let fr = padFilterR.run(r, cutoff: open * 1.03, q: 0.9).lp * gain
    add(i, fl, fr, send: 0.55, ducked: true)
}

// MARK: Bass

var bassSaw = Saw(), bassFilter = SVF()
var subPhase = 0.0
for b in 0..<bars {
    let p = part(b)
    guard p == .build || p == .drop || p == .drop2 || (p == .outro && b == 28) else { continue }
    let root = midi(roots[b % 4] - 12)
    let notes = p == .build ? [0.0] : (0..<8).map { Double($0) * beat / 2 }
    for (k, start) in notes.enumerated() {
        let len = p == .build ? bar * 0.95 : beat / 2 * 0.9
        let t0 = Double(b) * bar + start
        let f = root * (p != .build && k % 4 == 3 ? 2 : 1)
        for s in 0..<at(len) {
            let t = Double(s) / sr
            let env = min(1, t / 0.005) * (p == .build ? 1 : exp(-t * 3)) * min(1, (len - t) / 0.02)
            subPhase += 2 * .pi * f / sr
            let raw = bassSaw.next(f) * 0.5 + sin(subPhase) * 0.8
            let v = bassFilter.run(raw, cutoff: 500 + 900 * exp(-t * 9), q: 0.8).lp * env * 0.24
            add(at(t0) + s, v, v, ducked: true)
        }
    }
}

// MARK: Plucked arpeggio with a ping-pong delay

var arpSaw = Saw(), arpFilter = SVF()
var arpL = [Float](repeating: 0, count: total), arpR = [Float](repeating: 0, count: total)
for b in 0..<bars {
    let p = part(b)
    guard b >= 1, p != .outro || b == 28 else { continue }
    let c = chords[b % 4].map { $0 + 12 }
    let pattern = [0, 1, 2, 3, 2, 1, 3, 2, 0, 2, 1, 3, 2, 3, 1, 2]
    let gainBase = p == .intro ? 0.05 : (p == .breakdown ? 0.06 : 0.075)
    for (s, idx) in pattern.enumerated() {
        let t0 = Double(b) * bar + Double(s) * beat / 4
        let f = midi(c[idx])
        let cut = p == .intro ? 900 + 1500 * Double(b) / 4 : 2600
        for k in 0..<at(0.22) {
            let t = Double(k) / sr
            let env = exp(-t * 18) * min(1, t / 0.002)
            let v = arpFilter.run(arpSaw.next(f), cutoff: cut * (0.3 + 0.7 * exp(-t * 22)) + 300, q: 0.6).lp * env * gainBase
            let i = at(t0) + k
            if i < total { arpL[i] += Float(v); arpR[i] += Float(v) }
        }
    }
}
let delay = at(beat * 0.75)
for i in 0..<total {
    var l = Double(arpL[i]), r = Double(arpR[i])
    if i >= delay { l += Double(arpR[i - delay]) * 0.45 }
    if i >= delay * 2 { r += Double(arpL[i - delay * 2]) * 0.3 }
    arpL[i] = Float(l); arpR[i] = Float(r)
    add(i, l * 0.95, r * 1.05, send: 0.35, ducked: true)
}

// MARK: Lead, in the second drop

let melody: [[Double?]] = [
    [69, nil, 72, nil, 76, 74, 72, nil],
    [69, nil, 72, nil, 77, 76, 72, nil],
    [67, nil, 72, nil, 76, 79, 76, nil],
    [74, nil, 71, nil, 67, nil, 74, nil],
]
var leadPhase = 0.0, leadSaw = Saw(), leadFilter = SVF()
for b in 20..<min(28, bars) {
    for (s, n) in melody[b % 4].enumerated() {
        guard let n else { continue }
        let t0 = Double(b) * bar + Double(s) * beat / 2
        let f = midi(n)
        let len = beat * 0.9
        for k in 0..<at(len) {
            let t = Double(k) / sr
            let vib = 1 + 0.004 * sin(2 * .pi * 5.5 * t) * min(1, t / 0.2)
            leadPhase += 2 * .pi * f * vib / sr
            let env = min(1, t / 0.01) * exp(-t * 2.2) * min(1, (len - t) / 0.03)
            let raw = sin(leadPhase) * 0.6 + leadSaw.next(f * vib) * 0.25
            let v = leadFilter.run(raw, cutoff: 3200, q: 0.7).lp * env * 0.11
            add(at(t0) + k, v * 0.9, v * 1.1, send: 0.45, ducked: true)
        }
    }
}

// MARK: Reverb (Freeverb-style combs and allpasses on the send)

struct Comb {
    var buf: [Float]; var idx = 0; var store: Float = 0
    init(_ n: Int) { buf = [Float](repeating: 0, count: n) }
    mutating func run(_ x: Float, fb: Float = 0.84, damp: Float = 0.25) -> Float {
        let y = buf[idx]
        store = y * (1 - damp) + store * damp
        buf[idx] = x + store * fb
        idx = (idx + 1) % buf.count
        return y
    }
}
struct Allpass {
    var buf: [Float]; var idx = 0
    init(_ n: Int) { buf = [Float](repeating: 0, count: n) }
    mutating func run(_ x: Float) -> Float {
        let b = buf[idx]
        buf[idx] = x + b * 0.5
        idx = (idx + 1) % buf.count
        return b - x
    }
}
func reverb(_ input: [Float], offset: Int) -> [Float] {
    var combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617].map { Comb($0 + offset) }
    var aps = [556, 441, 341, 225].map { Allpass($0 + offset) }
    var out = [Float](repeating: 0, count: input.count)
    for i in 0..<input.count {
        var s: Float = 0
        for c in combs.indices { s += combs[c].run(input[i] * 0.015) }
        for a in aps.indices { s = aps[a].run(s) }
        out[i] = s
    }
    return out
}
let wetL = reverb(sendL, offset: 0), wetR = reverb(sendR, offset: 23)

// MARK: Master

var peak: Float = 0
var mixL = [Float](repeating: 0, count: total), mixR = [Float](repeating: 0, count: total)
var toneL = 0.0, toneR = 0.0
let toneA = 1 - exp(-2 * Double.pi * 11_000 / sr)   // a gentle top-end roll-off
for i in 0..<total {
    toneL += toneA * (Double(L[i] + wetL[i] * 2.6) - toneL)
    toneR += toneA * (Double(R[i] + wetR[i] * 2.6) - toneR)
    let l = tanh(toneL * 1.15)
    let r = tanh(toneR * 1.15)
    mixL[i] = Float(l); mixR[i] = Float(r)
    peak = max(peak, abs(mixL[i]), abs(mixR[i]))
}
let norm = 0.89 / max(peak, 0.0001)
let fadeIn = at(0.4), fadeOutStart = total - at(2.5)
var pcm = Data(capacity: total * 4)
for i in 0..<total {
    var g = norm
    if i < fadeIn { g *= Float(i) / Float(fadeIn) }
    if i > fadeOutStart { g *= Float(total - i) / Float(total - fadeOutStart) }
    for v in [mixL[i] * g, mixR[i] * g] {
        var s = Int16(max(-1, min(1, v)) * 32767).littleEndian
        withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
    }
}

func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
var wav = Data("RIFF".utf8)
wav += le(UInt32(36 + pcm.count)); wav += Data("WAVEfmt ".utf8)
wav += le(UInt32(16)); wav += le(UInt16(1)); wav += le(UInt16(2)); wav += le(UInt32(44_100))
wav += le(UInt32(44_100 * 4)); wav += le(UInt16(4)); wav += le(UInt16(16))
wav += Data("data".utf8); wav += le(UInt32(pcm.count)); wav += pcm
try wav.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) · \(String(format: "%.1f", Double(total) / sr)) s · peak before normalize \(peak)")
