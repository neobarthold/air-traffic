import AirTrafficCore
import SwiftUI

/// Tab „Regeln“ (SPEC §13, §15.3): Seitenleiste mit Suche und Liste, rechts der Editor.
struct RulesSettingsView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var visibleIDs: [UUID] { RuleSearch.filter(model.config.rules, query: query).map(\.id) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 272)
            Divider()
            Group {
                if let index = model.config.rules.firstIndex(where: { $0.id == model.selectedRuleID }) {
                    RuleEditorView(
                        rule: .element(of: $model.config.rules, at: index, fallback: model.config.rules[index]),
                        model: model,
                        position: index + 1,
                        onShowRule: showRule
                    )
                    .id(model.config.rules[index].id)
                } else {
                    Text("Regel auswählen oder anlegen.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.textBackground)
        }
    }

    // MARK: Seitenleiste

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, isFiltering ? 4 : 6)
            if isFiltering {
                Text("\(visibleIDs.count) von \(model.config.rules.count) Regeln")
                    .font(DS.small)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }
            List(selection: $model.selectedRuleID) {
                ForEach(visibleIDs, id: \.self) { id in
                    if let index = model.config.rules.firstIndex(where: { $0.id == id }) {
                        RuleRow(rule: $model.config.rules[index], position: index + 1)
                            .tag(id)
                            .listRowSeparator(.hidden)
                    }
                }
                // Umsortieren nur ohne Filter – in einer gefilterten Liste wäre das Ziel mehrdeutig.
                .onMove(perform: isFiltering ? nil : { from, to in
                    model.config.rules.move(fromOffsets: from, toOffset: to)
                })
            }
            // Seitenleisten-Optik; `.inset` statt `.sidebar`, damit die Auswahl als deckende
            // Akzentfläche erscheint (wie im Mockup) und nicht als Vibrancy-Hervorhebung.
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.config.rules.isEmpty {
                    Text("Keine Regeln.\nJeder Link nutzt die Standardaktion.")
                        .font(DS.help)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                } else if visibleIDs.isEmpty {
                    Text("Keine Regel passt zu „\(query)“.")
                        .font(DS.help)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }

            Divider()
            HStack(spacing: 2) {
                IconButton("plus", help: "Neue Regel", tint: .primary) { add(Rule(name: "Neue Regel")) }
                IconButton("minus", help: "Regel löschen", tint: .primary, action: removeSelected)
                    .disabled(model.selectedRuleID == nil)
                IconButton("plus.square.on.square", help: "Regel duplizieren", tint: .primary, action: duplicateSelected)
                    .disabled(model.selectedRuleID == nil)
                Spacer(minLength: 4)
                Text(footerText)
                    .font(DS.small)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footerText: String {
        if isFiltering { return "Sortieren nur ohne Filter" }
        let count = model.config.rules.count
        return "\(count == 1 ? "1 Regel" : "\(count) Regeln") · oben gewinnt"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Regeln durchsuchen", text: $query, prompt: Text("Regeln durchsuchen"))
                .textFieldStyle(.plain)
                .font(DS.body)
                .focused($searchFocused)
                .onExitCommand { query = ""; searchFocused = false }
                .accessibilityLabel("Regeln durchsuchen")
            if isFiltering {
                Button { query = "" } label: { Keycap("esc", size: 16) }
                    .buttonStyle(.plain)
                    .help("Suche leeren (esc)")
                    .accessibilityLabel("Suche leeren")
            } else {
                Keycap("⌘F", size: 16)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(DS.neutralFill))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor, lineWidth: searchFocused ? 1 : 0)
        )
        .background {
            // ⌘F fokussiert die Suche.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    // MARK: Aktionen

    private func add(_ rule: Rule) {
        query = ""  // neue Regel muss sichtbar sein
        let insertAt = model.config.rules.firstIndex { $0.id == model.selectedRuleID }.map { $0 + 1 }
            ?? model.config.rules.count
        model.config.rules.insert(rule, at: insertAt)
        model.selectedRuleID = rule.id
    }

    /// „Regel n zeigen“ im Vorrang-Hinweis (§14.2): Regel auswählen; ist sie herausgefiltert, Suche leeren.
    private func showRule(_ id: UUID) {
        if !visibleIDs.contains(id) { query = "" }
        model.selectedRuleID = id
    }

    private func removeSelected() {
        guard let index = model.config.rules.firstIndex(where: { $0.id == model.selectedRuleID }) else { return }
        model.selectedRuleID = nil
        model.config.rules.remove(at: index)
        if !model.config.rules.isEmpty {
            model.selectedRuleID = model.config.rules[min(index, model.config.rules.count - 1)].id
        }
    }

    private func duplicateSelected() {
        guard let original = model.config.rules.first(where: { $0.id == model.selectedRuleID }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " Kopie"
        add(copy)
    }
}

/// Symbol des Ziels einer Regel (App-Icon, Ersatz-App, `safari` bzw. `square.grid.2x2`).
struct RuleTargetIcon: View {
    let action: Action
    let size: CGFloat

    var body: some View {
        Group {
            switch action {
            case .open(let app):
                Image(nsImage: Apps.icon(for: app)).resizable()
            case .openFirstRunning(let fallback?):
                Image(nsImage: Apps.icon(for: fallback)).resizable()
            case .openFirstRunning(nil):
                symbol("safari")
            case .prompt:
                symbol("square.grid.2x2")
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22).fill(DS.neutralFill))
    }
}

private struct RuleRow: View {
    @Binding var rule: Rule
    let position: Int
    @Environment(\.backgroundProminence) private var prominence

    private var onAccent: Bool { prominence == .increased }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Toggle("Aktiv", isOn: $rule.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(rule.enabled ? "Regel ist aktiv" : "Regel ist aus")
                .accessibilityLabel("Regel „\(displayName)“ aktiv")
            RuleTargetIcon(action: rule.action, size: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayName)
                        .font(rule.enabled ? DS.cardTitle : .system(size: 13, weight: .medium))
                        .foregroundStyle(rule.enabled ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(position)")
                        .font(DS.small.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Position \(position)")
                }
                chips
            }
        }
        .padding(.vertical, 3)
    }

    private var displayName: String { rule.name.isEmpty ? "Ohne Namen" : rule.name }

    /// Alle Chips in Anzeigereihenfolge (Text, umrandet).
    private var chipItems: [(String, Bool)] {
        var items: [(String, Bool)] = []
        if !rule.enabled { items.append(("Aus", true)) }
        items += rule.conditions.prefix(2).map { (RuleText.chip($0), false) }
        if rule.conditions.isEmpty { items.append(("immer", false)) }
        if !rule.rewrites.isEmpty { items.append(("↻ umschreiben", false)) }
        return items
    }

    /// So viele Chips wie in die Zeile passen; der Rest wird als „+n“ zusammengefasst, nie hart abgeschnitten.
    private var chips: some View {
        let items = chipItems
        let extra = max(rule.conditions.count - 2, 0)
        return ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: items.count, through: 1, by: -1)), id: \.self) { shown in
                chipRow(Array(items.prefix(shown)), more: items.count - shown + extra)
            }
            // Notfalls nur der erste Chip, stärker gekürzt, plus „+n“.
            chipRow(Array(items.prefix(1)), more: items.count - 1 + extra, compress: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func chipRow(_ items: [(String, Bool)], more: Int, compress: Bool = false) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Chip(item.0, outlined: item.1, onAccent: onAccent, maxWidth: compress ? 130 : 160)
            }
            if more > 0 { Chip("+\(more)", onAccent: onAccent) }
        }
    }
}
