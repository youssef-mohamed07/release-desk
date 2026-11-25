import AppKit
import ReleaseKit
import SwiftUI

/// A release in flight: the track of stations on the left, the live log on
/// the right, over a slow mesh that takes the colour of how it is going.
struct LaunchConsole: View {
    let run: ReleaseRun
    let onNew: () -> Void
    @Environment(AppModel.self) private var model
    @State private var focus: StepID?
    @State private var confirmCancel = false

    var body: some View {
        ZStack {
            AnimatedMesh(palette: palette).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 18) {
                    LaunchTrack(run: run, focus: $focus)
                        .frame(width: 330)
                    ConsoleView(run: run, focus: $focus)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 24)
            }
        }
        .environment(\.colorScheme, .dark)
        .confirmationDialog("Stop this release?", isPresented: $confirmCancel) {
            Button("Stop", role: .destructive) { run.cancel() }
        } message: {
            Text("The current step is interrupted. Anything already sent to Apple stays there.")
        }
    }

    private var palette: AnimatedMesh.Palette {
        switch run.phase {
        case .succeeded: .success
        case .failed: .failure
        case .cancelled: .idle
        default: .running
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIcon(url: model.iconURL(run.plan.app.id, size: 256), name: run.plan.app.name, size: 58)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(run.plan.app.name).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("\(run.plan.version) (\(run.plan.build))").font(.system(size: 24, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                HStack(spacing: 8) {
                    PhaseBadge(run: run)
                    if run.plan.rehearsal { Chip(text: "Rehearsal", symbol: "theatermasks") }
                    ForEach(run.plan.groups) { g in Chip(text: g.name, symbol: g.isInternal ? "building.2" : "globe") }
                    if run.plan.submitForReview && run.plan.groups.contains(where: { !$0.isInternal }) && !run.plan.rehearsal {
                        Chip(text: "Beta review", symbol: "checkmark.shield")
                    }
                }
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .trailing, spacing: 0) {
                    Text(clock(run.elapsed)).font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(run.phase == .running ? "elapsed" : "total").font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
            ProgressRing(progress: run.progress, phase: run.phase).frame(width: 52, height: 52)
            actions
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var actions: some View {
        if run.phase == .running {
            Button(role: .destructive) { confirmCancel = true } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(.glass).controlSize(.large)
        } else {
            HStack(spacing: 8) {
                if run.phase == .succeeded, let link = run.plan.groups.first(where: { $0.publicLinkEnabled })?.publicLink, !run.plan.rehearsal {
                    Button { copyToPasteboard(link) } label: { Label("Copy TestFlight link", systemImage: "link") }
                        .buttonStyle(.glass).controlSize(.large)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([run.ipa ?? run.logFile]) } label: {
                    Label(run.ipa != nil ? "Show IPA" : "Show log", systemImage: "folder")
                }
                .buttonStyle(.glass).controlSize(.large)
                Button(action: onNew) { Label("New release", systemImage: "plus") }
                    .buttonStyle(.glassProminent).controlSize(.large)
            }
        }
    }
}

struct PhaseBadge: View {
    let run: ReleaseRun
    var body: some View {
        let (text, color): (String, Color) = switch run.phase {
        case .ready: ("Ready", .secondary)
        case .running: (run.current.map { "\($0.title)…" } ?? "Starting…", Palette.cyan)
        case .succeeded: (run.plan.rehearsal ? "Rehearsal passed" : "Shipped", Palette.mint)
        case .failed: ("Stopped at \(run.steps.first { if case .failed = $0.state { true } else { false } }?.id.title ?? "a step")", Palette.ember)
        case .cancelled: ("Cancelled", .secondary)
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7).shadow(color: color, radius: 4)
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.18), in: .capsule)
    }
}

struct ProgressRing: View {
    let progress: Double
    let phase: ReleaseRun.Phase
    var body: some View {
        let color: Color = phase == .failed ? Palette.ember : (phase == .succeeded ? Palette.mint : Palette.cyan)
        ZStack {
            Circle().stroke(.white.opacity(0.1), lineWidth: 5)
            Circle().trim(from: 0, to: progress)
                .stroke(AngularGradient(colors: [color.opacity(0.4), color], center: .center), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: progress)
            Text("\(Int(progress * 100))").font(.caption.weight(.bold).monospacedDigit())
        }
    }
}

// MARK: - Track

struct LaunchTrack: View {
    let run: ReleaseRun
    @Binding var focus: StepID?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(run.steps.enumerated()), id: \.element.id) { i, step in
                    Station(step: step, last: i == run.steps.count - 1, next: i + 1 < run.steps.count ? run.steps[i + 1] : nil,
                            focused: focus == step.id)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(.snappy) { focus = focus == step.id ? nil : step.id } }
                }
            }
            .padding(16)
        }
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .rect(cornerRadius: 22))
    }
}

struct Station: View {
    let step: RunStep
    let last: Bool
    let next: RunStep?
    let focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Node(step: step)
                if !last {
                    ZStack(alignment: .top) {
                        Capsule().fill(.white.opacity(0.10)).frame(width: 2.5)
                        if step.state.isFinished {
                            Capsule().fill(LinearGradient(colors: [tone(step.state), tone(next?.state ?? .pending).opacity(next?.state == .pending ? 0.25 : 1)],
                                                          startPoint: .top, endPoint: .bottom))
                                .frame(width: 2.5)
                                .transition(.scale(scale: 0, anchor: .top))
                        }
                    }
                    .frame(height: 22)
                    .padding(.vertical, 3)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(step.id.title).font(.callout.weight(.semibold))
                        .foregroundStyle(step.state == .pending ? .white.opacity(0.45) : .white)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                    }
                }
                if let sub = subtitle {
                    Text(sub).font(.caption).foregroundStyle(subtitleColor).lineLimit(2)
                }
            }
            .padding(.top, 7)
        }
        .padding(.horizontal, 8)
        .background(focused ? Color.white.opacity(0.07) : .clear, in: .rect(cornerRadius: 12))
        .animation(.spring(duration: 0.45), value: step.state)
    }

    private var duration: String {
        guard let s = step.started else { return "" }
        return clock((step.finished ?? Date()).timeIntervalSince(s))
    }

    private var subtitle: String? {
        switch step.state {
        case .running: step.detail
        case .failed(let m), .warning(let m), .skipped(let m): m
        case .done: step.detail
        case .pending: nil
        }
    }

    private var subtitleColor: Color {
        switch step.state {
        case .failed: Palette.ember
        case .warning: StateTone.waiting.color
        default: .white.opacity(0.55)
        }
    }
}

func tone(_ s: StepState) -> Color {
    switch s {
    case .pending: .white.opacity(0.2)
    case .running: Palette.cyan
    case .done: Palette.mint
    case .warning: StateTone.waiting.color
    case .skipped: .white.opacity(0.3)
    case .failed: Palette.ember
    }
}

struct Node: View {
    let step: RunStep
    @State private var spin = false

    var body: some View {
        ZStack {
            switch step.state {
            case .pending:
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1.5)
                Image(systemName: step.id.symbol).font(.system(size: 13)).foregroundStyle(.white.opacity(0.35))
            case .running:
                Circle().fill(Palette.cyan.opacity(0.16))
                Circle().strokeBorder(AngularGradient(colors: [Palette.cyan.opacity(0), Palette.cyan, Palette.violet], center: .center), lineWidth: 2.5)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true } }
                Image(systemName: step.id.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.cyan)
                    .symbolEffect(.pulse, options: .repeating)
            case .done:
                Circle().fill(Palette.mint)
                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Palette.ink)
                    .transition(.scale.combined(with: .opacity))
            case .warning:
                Circle().fill(StateTone.waiting.color)
                Image(systemName: "exclamationmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(Palette.ink)
            case .skipped:
                Circle().strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                Image(systemName: "arrow.turn.down.right").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            case .failed:
                Circle().fill(Palette.ember)
                Image(systemName: "xmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
        .shadow(color: tone(step.state).opacity(step.state == .pending ? 0 : 0.6), radius: step.state == .running ? 10 : 5)
    }
}

// MARK: - Console

struct ConsoleView: View {
    let run: ReleaseRun
    @Binding var focus: StepID?
    @State private var follow = true
    @State private var showOutput = true

    private var visible: [LogLine] {
        run.lines.filter { (focus == nil || $0.step == focus) && (showOutput || $0.kind != .output) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(.white.opacity(0.6))
                Text(focus.map { "\($0.title) log" } ?? "Live log").font(.callout.weight(.semibold))
                if focus != nil {
                    Button("All steps") { withAnimation(.snappy) { focus = nil } }.buttonStyle(.glass).controlSize(.small)
                }
                Spacer()
                Toggle("Tool output", isOn: $showOutput).toggleStyle(.switch).controlSize(.mini)
                Toggle("Follow", isOn: $follow).toggleStyle(.switch).controlSize(.mini)
                Button { NSWorkspace.shared.open(run.logFile) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless).help("Open the full log")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            Divider().overlay(.white.opacity(0.08))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1.5) {
                        ForEach(visible) { line in
                            LogRow(line: line)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(14)
                    .textSelection(.enabled)
                }
                .onChange(of: run.lines.count) {
                    if follow { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(Palette.ink.opacity(0.72), in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.09)))
    }
}

struct LogRow: View {
    let line: LogLine
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.time.string(from: line.time)).foregroundStyle(.white.opacity(0.28))
            Text(line.step.rawValue).foregroundStyle(stepColor.opacity(0.75)).frame(width: 70, alignment: .leading)
            Text(line.text).foregroundStyle(color).fontWeight(line.kind == .output ? .regular : .medium)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
    }

    private var color: Color {
        switch line.kind {
        case .output: .white.opacity(0.62)
        case .info: .white.opacity(0.92)
        case .success: Palette.mint
        case .warning: StateTone.waiting.color
        case .error: Palette.ember
        }
    }

    private var stepColor: Color {
        let hues: [StepID: Double] = [.prepare: 0.6, .archive: 0.72, .sign: 0.8, .export: 0.86, .upload: 0.55, .processing: 0.5,
                                      .notes: 0.12, .groups: 0.38, .review: 0.3, .live: 0.42]
        return Color(hue: hues[line.step] ?? 0.6, saturation: 0.55, brightness: 1)
    }
}

// MARK: - Background

/// A slowly breathing mesh gradient. Indigo while working, green when it
/// lands, red when it stops.
struct AnimatedMesh: View {
    enum Palette: Equatable { case idle, running, success, failure }
    let palette: Palette

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors)
                .animation(.easeInOut(duration: 1.2), value: palette)
        }
        .overlay(Color.black.opacity(0.15))
    }

    private func points(_ t: Double) -> [SIMD2<Float>] {
        func w(_ speed: Double, _ phase: Double, _ amp: Float = 0.12) -> Float { Float(sin(t * speed + phase)) * amp }
        return [
            [0, 0], [0.5 + w(0.21, 0), 0], [1, 0],
            [0, 0.5 + w(0.17, 1)], [0.5 + w(0.23, 2, 0.18), 0.5 + w(0.19, 3, 0.18)], [1, 0.5 + w(0.15, 4)],
            [0, 1], [0.5 + w(0.2, 5), 1], [1, 1],
        ]
    }

    private var colors: [Color] {
        let ink = Color(red: 0.03, green: 0.04, blue: 0.09)
        switch palette {
        case .idle:
            return [ink, Color(red: 0.13, green: 0.12, blue: 0.32), ink,
                    Color(red: 0.10, green: 0.16, blue: 0.36), Color(red: 0.30, green: 0.22, blue: 0.62), Color(red: 0.07, green: 0.20, blue: 0.33),
                    ink, Color(red: 0.08, green: 0.10, blue: 0.24), ink]
        case .running:
            return [ink, Color(red: 0.10, green: 0.14, blue: 0.40), Color(red: 0.05, green: 0.08, blue: 0.20),
                    Color(red: 0.06, green: 0.22, blue: 0.40), Color(red: 0.22, green: 0.24, blue: 0.70), Color(red: 0.05, green: 0.32, blue: 0.48),
                    ink, Color(red: 0.12, green: 0.10, blue: 0.34), ink]
        case .success:
            return [ink, Color(red: 0.04, green: 0.24, blue: 0.22), ink,
                    Color(red: 0.05, green: 0.30, blue: 0.28), Color(red: 0.10, green: 0.55, blue: 0.42), Color(red: 0.06, green: 0.30, blue: 0.40),
                    ink, Color(red: 0.04, green: 0.20, blue: 0.18), ink]
        case .failure:
            return [ink, Color(red: 0.30, green: 0.07, blue: 0.10), ink,
                    Color(red: 0.24, green: 0.06, blue: 0.16), Color(red: 0.55, green: 0.14, blue: 0.18), Color(red: 0.25, green: 0.08, blue: 0.24),
                    ink, Color(red: 0.18, green: 0.05, blue: 0.10), ink]
        }
    }
}
