import AppKit
import ReleaseKit
import SwiftUI

extension StateTone {
    var color: Color {
        switch self {
        case .good: Color(red: 0.20, green: 0.80, blue: 0.55)
        case .active: Color(red: 0.30, green: 0.62, blue: 1.0)
        case .waiting: Color(red: 1.0, green: 0.66, blue: 0.22)
        case .bad: Color(red: 1.0, green: 0.36, blue: 0.40)
        case .muted: Color.secondary
        }
    }
}

enum Palette {
    static let ink = Color(red: 0.05, green: 0.06, blue: 0.11)
    static let indigo = Color(red: 0.29, green: 0.31, blue: 0.95)
    static let violet = Color(red: 0.55, green: 0.33, blue: 0.98)
    static let cyan = Color(red: 0.20, green: 0.78, blue: 0.98)
    static let mint = Color(red: 0.20, green: 0.84, blue: 0.62)
    static let ember = Color(red: 1.0, green: 0.38, blue: 0.36)
    static let play = LinearGradient(colors: [Color(red: 0.0, green: 0.82, blue: 0.53), Color(red: 0.0, green: 0.62, blue: 0.95)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let brand = LinearGradient(colors: [indigo, violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A capsule with a dot that says where a build or version stands.
struct StatePill: View {
    let raw: String?
    var prefix: String? = nil
    var compact = false

    var body: some View {
        let d = describeState(raw)
        HStack(spacing: 5) {
            Circle().fill(d.tone.color).frame(width: 6, height: 6)
                .shadow(color: d.tone.color.opacity(0.8), radius: d.tone == .active ? 3 : 0)
            if let prefix { Text(prefix).foregroundStyle(.secondary) }
            Text(d.label).foregroundStyle(d.tone == .muted ? .secondary : .primary)
        }
        .font(compact ? .caption2.weight(.medium) : .caption.weight(.medium))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3.5)
        .background(d.tone.color.opacity(0.13), in: .capsule)
        .overlay(Capsule().strokeBorder(d.tone.color.opacity(0.25), lineWidth: 0.5))
    }
}

/// Loads and caches remote images (app icons from Apple's CDN).
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var images: [URL: NSImage] = [:]
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    func image(_ url: URL) async -> NSImage? {
        if let i = images[url] { return i }
        if let t = inflight[url] { return await t.value }
        let t = Task<NSImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inflight[url] = t
        let img = await t.value
        images[url] = img
        inflight[url] = nil
        return img
    }

    func cached(_ url: URL?) -> NSImage? { url.flatMap { images[$0] } }
}

struct AppIcon: View {
    let url: URL?
    var name: String = ""
    var size: CGFloat = 40
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        ZStack {
            if let image = image ?? ImageCache.shared.cached(url) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                shape.fill(LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(size > 50 ? 0.25 : 0.12), radius: size > 50 ? 12 : 2, y: size > 50 ? 6 : 1)
        .task(id: url) {
            if let url { image = await ImageCache.shared.image(url) }
        }
    }

    private var placeholderColors: [Color] {
        let hues: [Double] = [0.62, 0.72, 0.52, 0.85, 0.08, 0.45]
        let h = hues[abs(name.hashValue) % hues.count]
        return [Color(hue: h, saturation: 0.55, brightness: 0.75), Color(hue: h + 0.08, saturation: 0.7, brightness: 0.5)]
    }
}

/// The app's own icon, blurred into a soft light source behind a page.
struct AmbientGlow: View {
    let url: URL?
    var intensity: Double = 0.55
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = image ?? ImageCache.shared.cached(url) {
                    Image(nsImage: image).resizable()
                        .frame(width: geo.size.width * 0.9, height: geo.size.width * 0.5)
                        .blur(radius: 90)
                        .saturation(1.6)
                        .opacity(scheme == .dark ? intensity : intensity * 0.7)
                        .offset(x: -geo.size.width * 0.15, y: -geo.size.width * 0.18)
                } else {
                    Ellipse().fill(Palette.brand).frame(width: geo.size.width * 0.8, height: 260)
                        .blur(radius: 110).opacity(0.25).offset(y: -120)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: url) { if let url { image = await ImageCache.shared.image(url) } }
    }
}

/// The surface content cards sit on: a faint fill and a top-lit hairline.
struct CardSurface: ViewModifier {
    var radius: CGFloat = 16
    var padding: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.72))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.16 : 0.9), .white.opacity(scheme == .dark ? 0.03 : 0.3)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.0 : 0.06), radius: 10, y: 4)
    }
}

extension View {
    func card(radius: CGFloat = 16, padding: CGFloat = 16) -> some View { modifier(CardSurface(radius: radius, padding: padding)) }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(title).font(.title3.weight(.semibold))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            Spacer()
        }
    }
}

/// A Google Play mark drawn from shapes (there is no SF Symbol for it).
struct PlayMark: View {
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: size * 0.8, weight: .bold))
            .foregroundStyle(Palette.play)
            .frame(width: size, height: size)
    }
}

struct ProviderMark: View {
    let provider: StoreProvider
    var size: CGFloat = 14
    var body: some View {
        switch provider {
        case .apple: Image(systemName: "apple.logo").font(.system(size: size * 0.9, weight: .medium)).frame(width: size, height: size)
        case .google: PlayMark(size: size)
        }
    }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }

    var short: String { formatted(.dateTime.day().month(.abbreviated).hour().minute()) }
}

func clock(_ t: TimeInterval) -> String {
    let s = Int(max(0, t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
