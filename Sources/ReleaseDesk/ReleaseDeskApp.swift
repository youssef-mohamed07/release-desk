import AppKit
import ReleaseKit
import SwiftUI

@main
struct ReleaseDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Release Desk", id: "main") {
            RootView()
                .environment(model)
                .environment(\.privacyMode, model.privacy)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New App…") { model.newApp = true }.keyboardShortcut("n")
                Button("Go to…") { model.palette.toggle() }.keyboardShortcut("k")
                Divider()
                Button("Connect App Store Connect…") { model.connecting = .apple }
                Button("Connect Google Play…") { model.connecting = .google }
                Button("Connect AppGallery…") { model.connecting = .huawei }
                Button("Connect Microsoft Store…") { model.connecting = .microsoft }
            }
            CommandGroup(after: .sidebar) {
                Toggle("Privacy Mode", isOn: Binding(get: { model.privacy }, set: { model.privacy = $0 }))
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandMenu("Release") {
                Button("Refresh") { Task { await model.refreshAll() } }.keyboardShortcut("r")
                Button("Overview") { model.route = .overview }.keyboardShortcut("1")
                Button("Activity") { model.route = .activity }.keyboardShortcut("2")
            }
        }

        MenuBarExtra {
            MenuBarRuns().environment(model).environment(\.privacyMode, model.privacy)
        } label: {
            Image(systemName: model.runningCount > 0 ? "paperplane.circle.fill" : "paperplane")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A key file opened with Release Desk (double-click, Dock drop, `open -a`).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { ["p8", "json"].contains($0.pathExtension.lowercased()) }) else { return }
        MainActor.assumeIsolated {
            let model = AppModel.shared
            model.connecting = nil
            model.droppedKey = url
            DispatchQueue.main.async { model.connecting = url.pathExtension.lowercased() == "p8" ? .apple : .google }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            ZStack {
                switch model.route ?? .overview {
                case .overview: OverviewView()
                case .activity: ActivityView()
                case .team(let id): TeamView(teamID: id)
                case .app(let id): AppDetailView(appID: id)
                case .ship(let id): ShipView(appID: id).id(id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $model.newApp) { NewAppWizard().environment(\.privacyMode, model.privacy) }
        .sheet(item: $model.connecting) { provider in
            ConnectSheet(provider: provider).environment(\.privacyMode, model.privacy)
        }
        .overlay {
            if model.palette {
                CommandPalette().transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.snappy(duration: 0.18), value: model.palette)
        // Drop a .p8 or a service account .json anywhere to connect it.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.connecting == nil, let url = urls.first(where: { ["p8", "json"].contains($0.pathExtension.lowercased()) }) else { return false }
            model.droppedKey = url
            model.connecting = url.pathExtension.lowercased() == "p8" ? .apple : .google
            return true
        }
        .alert("Release Desk", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
        .task { await model.refreshAll() }
    }
}

extension StoreProvider: Identifiable {
    public var id: String { rawValue }
}

/// What the menu bar shows: runs in flight, with their current step.
struct MenuBarRuns: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Release Desk").font(.headline)
                Spacer()
                Button("Open") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
            if model.runs.isEmpty {
                Text("No releases yet in this session.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(model.runs.suffix(5).reversed()) { run in
                MiniRun(run: run)
                    .contentShape(.rect)
                    .onTapGesture {
                        model.route = .ship(run.plan.app.id)
                        openWindow(id: "main")
                        NSApp.activate()
                    }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

struct MiniRun: View {
    let run: ReleaseRun
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(url: model.iconURL(run.plan.app.id, size: 64), name: run.plan.app.name, size: 32).sensitive(8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(run.plan.app.name).sensitive()
                    Text("\(run.plan.version) (\(run.plan.build))")
                }
                .font(.callout.weight(.medium))
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
                ProgressView(value: run.progress).progressViewStyle(.linear).tint(tint)
            }
        }
    }

    private var tint: Color {
        switch run.phase {
        case .succeeded: Palette.mint
        case .failed: Palette.ember
        default: Palette.cyan
        }
    }

    private var statusLine: String {
        switch run.phase {
        case .running: "\(run.current?.title ?? "Starting") · \(clock(run.elapsed))"
        case .succeeded: run.plan.rehearsal ? "Rehearsal passed" : "Shipped in \(clock(run.elapsed))"
        case .failed: run.failure ?? "Failed"
        case .cancelled: "Cancelled"
        case .ready: "Ready"
        }
    }
}
