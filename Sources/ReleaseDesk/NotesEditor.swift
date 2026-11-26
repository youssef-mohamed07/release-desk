import ReleaseKit
import SwiftUI

/// Release notes in the languages you pick: one box per language, a menu to
/// add any language the store takes, and a button to drop one.
struct NotesEditor<Trailing: View>: View {
    let title: String
    let symbol: String
    let limit: Int
    /// Every language the store takes.
    let available: [String]
    @Binding var locales: [String]
    @Binding var notes: [String: String]
    var footer: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(title, systemImage: symbol).font(.headline)
                Spacer()
                trailing()
                LanguageMenu(available: available.filter { !locales.contains($0) }) { locales.append($0) }
            }
            ForEach(locales, id: \.self) { locale in
                let rtl = StoreLanguages.isRightToLeft(locale)
                let count = (notes[locale] ?? "").count
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(StoreLanguages.name(locale)).font(.caption.weight(.semibold))
                        Text(locale).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(count)/\(limit)").font(.caption2.monospacedDigit()).foregroundStyle(count > limit ? .orange : .secondary)
                        if locales.count > 1 {
                            Button { locales.removeAll { $0 == locale } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.tertiary)
                                .help("Remove \(StoreLanguages.name(locale))")
                        }
                    }
                    TextEditor(text: Binding(get: { notes[locale] ?? "" }, set: { notes[locale] = $0 }))
                        .font(.system(size: 13.5))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 110)
                        .sensitive(5)
                        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
                        .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                        .multilineTextAlignment(rtl ? .trailing : .leading)
                }
            }
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}

extension NotesEditor where Trailing == EmptyView {
    init(title: String, symbol: String, limit: Int, available: [String], locales: Binding<[String]>, notes: Binding<[String: String]>,
         footer: String? = nil) {
        self.init(title: title, symbol: symbol, limit: limit, available: available, locales: locales, notes: notes, footer: footer) { EmptyView() }
    }
}

/// "+ Language": every language not chosen yet, by name.
struct LanguageMenu: View {
    let available: [String]
    let add: (String) -> Void

    var body: some View {
        Menu {
            ForEach(available.sorted { StoreLanguages.name($0) < StoreLanguages.name($1) }, id: \.self) { code in
                Button("\(StoreLanguages.name(code))  ·  \(code)") { add(code) }
            }
        } label: {
            Label("Language", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize()
        .disabled(available.isEmpty)
        .help("Add a language")
    }
}

extension Dictionary where Key == String, Value == String {
    /// The notes worth sending: chosen languages with some text.
    func notes(in locales: [String]) -> [String: String] {
        filter { locales.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
