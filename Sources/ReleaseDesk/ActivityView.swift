import AppKit
import ReleaseKit
import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Activity").font(.system(size: 30, weight: .bold, design: .rounded))
                if !model.runs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "This session", symbol: "bolt.fill")
                        ForEach(model.runs.reversed()) { run in
                            Button { model.route = .ship(run.plan.app.id) } label: { MiniRun(run: run).card(radius: 14, padding: 12) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "History", symbol: "clock.arrow.circlepath")
                    if model.workspace.runs.isEmpty {
                        Text("Releases you run from here are listed with their logs.").foregroundStyle(.secondary).card()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.workspace.runs.enumerated()), id: \.element.id) { i, r in
                                HistoryRow(record: r)
                                if i < model.workspace.runs.count - 1 { Divider() }
                            }
                        }
                        .card(padding: 8)
                    }
                }
            }
            .padding(32)
        }
        .background(alignment: .top) { AmbientGlow(url: nil).frame(height: 360) }
    }
}

struct HistoryRow: View {
    let record: RunRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: model.iconURL(record.appID, size: 64), name: record.appName, size: 30).sensitive(8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { Text(record.appName).sensitive(); Text("\(record.version) (\(record.build))") }.fontWeight(.medium)
                Text(record.started.short + (record.finished.map { " · \(clock($0.timeIntervalSince(record.started)))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            outcome
            if let p = record.logPath {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderless).help("Open the log")
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var outcome: some View {
        switch record.outcome {
        case "succeeded": Label("Shipped", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.mint)
        case "rehearsed": Label("Rehearsed", systemImage: "theatermasks.fill").foregroundStyle(Palette.violet)
        case "failed": Label("Stopped at \(record.failedStep ?? "?")", systemImage: "xmark.octagon.fill").foregroundStyle(Palette.ember)
        default: Label("Cancelled", systemImage: "stop.circle").foregroundStyle(.secondary)
        }
    }
}
