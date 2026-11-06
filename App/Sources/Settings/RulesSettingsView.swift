import AirTrafficCore
import SwiftUI

/// Tab „Regeln“ (SPEC §13, §15.3, §22): Seitenleiste mit Suche bzw. URL-Prüfung und Liste, rechts der Editor.
struct RulesSettingsView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    private var query: String { model.ruleQuery }
    private var isFiltering: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Inhalt ist eine URL, „Als Text suchen“ ist aber gewählt (§22.1).
    private var isForcedText: Bool {
        model.ruleQueryForcedText == query && RuleCheck.url(from: query) != nil
    }

    /// Ergebnis der URL-Prüfung (§22); nil = Textsuche bzw. kein Filter.
    private var checkResult: RuleCheckResult? {
        model.ruleCheckURL.map { RuleEngine.check(url: $0, context: model.ruleCheckContext, config: model.config) }
    }

    private func visibleIDs(_ check: RuleCheckResult?) -> [UUID] {
        if let check {
            return check.entries.filter { model.ruleCheckShowsAll || $0.matches }.map(\.ruleID)
        }
        return RuleSearch.filter(model.config.rules, query: query).map(\.id)
    }

    var body: some View {
        let check = checkResult
        HStack(spacing: 0) {
            sidebar(check)
                .frame(width: 320)
            Divider()
            Group {
                if let index = model.config.rules.firstIndex(where: { $0.id == model.selectedRuleID }) {
                    RuleEditorView(
                        rule: .element(of: $model.config.rules, at: index, fallback: model.config.rules[index]),
                        model: model,
                        position: index + 1,
                        onShowRule: showRule,
                        checkURL: model.ruleCheckURL
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

    private func sidebar(_ check: RuleCheckResult?) -> some View {
        let visible = visibleIDs(check)
        return VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, isFiltering ? 4 : 6)
            if let check {
                modeRow
                RuleCheckCard(
                    result: check,
                    winner: check.decision.matchedRuleID.flatMap { model.rule(withID: $0) },
                    winnerPosition: check.entries.first { $0.status == .wins }?.position,
                    defaultAction: model.config.defaultAction,
                    showsExtensionNote: model.extensionSettings != ExtensionSettings(),
                    source: $model.ruleCheckSource,
                    modifiers: $model.ruleCheckModifiers
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                checkCountRow(check)
            } else if isFiltering {
                HStack(spacing: 6) {
                    Text("\(visible.count) von \(model.config.rules.count) Regeln")
                        .font(DS.small)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if isForcedText {
                        TextLinkButton("Als URL prüfen") { model.ruleQueryForcedText = nil }
                            .help("Inhalt des Suchfelds als URL prüfen")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.bottom, 4)
            }
            List(selection: $model.selectedRuleID) {
                ForEach(visible, id: \.self) { id in
                    if let index = model.config.rules.firstIndex(where: { $0.id == id }) {
                        RuleRow(
                            rule: $model.config.rules[index],
                            position: index + 1,
                            checkLine: check.flatMap { checkLine(for: model.config.rules[index], in: $0) }
                        )
                        .tag(id)
                        .listRowSeparator(.hidden)
                    }
                }
                // Umsortieren nur ohne Filter/Prüfung – in einer gefilterten Liste wäre das Ziel mehrdeutig.
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
                    emptyText("Keine Regeln.\nJeder Link nutzt die Standardaktion.")
                } else if visible.isEmpty, check != nil {
                    emptyText("Keine Regel trifft. Mit „Alle Regeln“ siehst du, woran es scheitert.")
                } else if visible.isEmpty {
                    emptyText("Keine Regel passt zu „\(query)“.")
                }
            }

            Divider()
            HStack(spacing: 2) {
                IconButton("plus", help: "Neue Regel", tint: .primary, action: addNew)
                IconButton("minus", help: "Regel löschen", tint: .primary, action: removeSelected)
                    .disabled(model.selectedRuleID == nil)
                IconButton("plus.square.on.square", help: "Regel duplizieren", tint: .primary, action: duplicateSelected)
                    .disabled(model.selectedRuleID == nil)
                Spacer(minLength: 4)
                Text(footerText(checking: check != nil))
                    .font(DS.small)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(DS.help)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding()
    }

    private func footerText(checking: Bool) -> String {
        if checking { return "Sortieren nur ohne Prüfung" }
        if isFiltering { return "Sortieren nur ohne Filter" }
        let count = model.config.rules.count
        return "\(count == 1 ? "1 Regel" : "\(count) Regeln") · oben gewinnt"
    }

    /// Zeile unter dem Suchfeld im Prüfmodus: Modus und Umschalter „Als Text suchen“ (§22.1).
    private var modeRow: some View {
        HStack(spacing: 6) {
            Label("URL wird geprüft", systemImage: "link")
                .font(DS.small)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 4)
            TextLinkButton("Als Text suchen") { model.ruleQueryForcedText = model.ruleQuery }
                .help("Inhalt des Suchfelds als Text in den Regeln suchen")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.bottom, 6)
    }

    /// „x von y Regeln treffen“ + Umschalter „Nur Treffer“ / „Alle Regeln“ (§22.2).
    private func checkCountRow(_ check: RuleCheckResult) -> some View {
        let count = Text("\(check.matchCount) von \(check.entries.count) Regeln treffen")
            .font(DS.small)
            .foregroundStyle(.secondary)
        let picker = Picker("Ansicht", selection: $model.ruleCheckShowsAll) {
            Text("Nur Treffer").tag(false)
            Text("Alle Regeln").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Nur passende Regeln oder alle Regeln zeigen")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                count.fixedSize()
                Spacer(minLength: 4)
                picker
            }
            VStack(alignment: .leading, spacing: 4) {
                count
                picker
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.bottom, 4)
    }

    /// Status-Zeile einer Regel im Prüfmodus (§22.3).
    private func checkLine(for rule: Rule, in check: RuleCheckResult) -> RuleCheckLine? {
        guard let entry = check.entries.first(where: { $0.ruleID == rule.id }) else { return nil }
        switch entry.status {
        case .wins:
            let rewrites = check.decision.finalURL != check.decision.originalURL
            return RuleCheckLine(kind: .wins, text: rewrites ? "greift · schreibt um" : "greift")
        case .shadowed(let winnerID):
            let number = check.entries.first { $0.ruleID == winnerID }?.position
            return RuleCheckLine(kind: .shadowed, text: "trifft, aber Regel \(number.map(String.init) ?? "?") greift zuerst")
        case .disabledMatch:
            return RuleCheckLine(kind: .disabledMatch, text: "Aus – würde treffen")
        case .noMatch:
            guard let index = entry.firstFailedCondition, rule.conditions.indices.contains(index) else {
                return RuleCheckLine(kind: .noMatch, text: "trifft nicht")
            }
            return RuleCheckLine(
                kind: .noMatch,
                text: "trifft nicht · Bedingung \(index + 1) (\(RuleText.fieldName(rule.conditions[index])))"
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: model.ruleCheckURL == nil ? "magnifyingglass" : "link")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            TextField(
                "Regeln durchsuchen oder URL prüfen",
                text: $model.ruleQuery,
                prompt: Text("Regeln durchsuchen oder URL prüfen")
            )
                .textFieldStyle(.plain)
                .font(DS.body)
                .focused($searchFocused)
                .onExitCommand { model.ruleQuery = ""; searchFocused = false }
                .accessibilityLabel("Regeln durchsuchen oder URL prüfen")
            if isFiltering {
                Button { model.ruleQuery = "" } label: { Keycap("esc", size: 16) }
                    .buttonStyle(.plain)
                    .help("Suche leeren (esc)")
                    .accessibilityLabel("Suche leeren")
            } else {
                Keycap("⌘F", size: 16)
            }
        }
        .padding(.horizontal, 6)
        .help("Regeln durchsuchen oder URL prüfen (⌘F)")
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

    /// „+“: im Prüfmodus mit geprüfter URL als Test-URL und „Host ist ‹host›“ (§22.3).
    private func addNew() {
        guard let url = model.ruleCheckURL else {
            add(Rule(name: "Neue Regel"))
            return
        }
        let host = url.host(percentEncoded: false) ?? ""
        let condition: Condition = host.isEmpty
            ? .linkType(url.isFileURL ? .file : .web)
            : .host(TextMatch(op: .equals, value: host))
        add(Rule(name: "Neue Regel", conditions: [condition], testURL: url.absoluteString))
    }

    private func add(_ rule: Rule) {
        let checking = model.ruleCheckURL != nil
        if !checking { model.ruleQuery = "" }  // neue Regel muss sichtbar sein
        let insertAt = model.config.rules.firstIndex { $0.id == model.selectedRuleID }.map { $0 + 1 }
            ?? model.config.rules.count
        model.config.rules.insert(rule, at: insertAt)
        model.selectedRuleID = rule.id
        // Prüfmodus bleibt; trifft die neue Regel nicht, auf „Alle Regeln“ schalten.
        if checking, !visibleIDs(checkResult).contains(rule.id) { model.ruleCheckShowsAll = true }
    }

    /// „Regel n zeigen“ im Vorrang-Hinweis (§14.2, §22.4): Regel auswählen; ist sie nicht sichtbar,
    /// im Prüfmodus „Alle Regeln“ zeigen, sonst Suche leeren.
    private func showRule(_ id: UUID) {
        if !visibleIDs(checkResult).contains(id) {
            if model.ruleCheckURL != nil {
                model.ruleCheckShowsAll = true
            } else {
                model.ruleQuery = ""
            }
        }
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

// MARK: - URL-Prüfung

/// Ergebniskarte der URL-Prüfung (§22.2): was bei einem echten Klick passiert.
private struct RuleCheckCard: View {
    let result: RuleCheckResult
    let winner: Rule?
    let winnerPosition: Int?
    let defaultAction: Action
    let showsExtensionNote: Bool
    @Binding var source: String
    @Binding var modifiers: ModifierSet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if winner != nil {
                    StatusPill(.ok, "Regel \(winnerPosition.map(String.init) ?? "?") greift", small: true).fixedSize()
                } else {
                    StatusPill(.neutral, "Keine Regel greift", small: true).fixedSize()
                }
                Spacer(minLength: 4)
                ViewThatFits(in: .horizontal) {
                    SimulationButton(source: $source, modifiers: $modifiers)
                    SimulationButton(source: $source, modifiers: $modifiers, compact: true)
                }
                .controlSize(.small)
            }
            if let winner {
                Text(winner.name.isEmpty ? "Ohne Namen" : winner.name)
                    .font(DS.cardTitle)
                    .fixedSize(horizontal: false, vertical: true)
                // URL nur, wenn Umschreibungen sie ändern (§22.2).
                let rewritten = result.decision.finalURL != result.decision.originalURL
                ActionText.opens(winner.action, url: rewritten ? result.decision.finalURL : nil)
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Standardaktion: \(ActionText.opens(defaultAction, url: nil))")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(result.decision.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(DS.small)
                    .foregroundStyle(DS.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsExtensionNote {
                Text("Links aus der Safari-Erweiterung verhalten sich anders (Tab „Safari“).")
                    .font(DS.small)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.neutralFill))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ergebnis der URL-Prüfung")
    }
}

/// Status einer Regel in der Liste im Prüfmodus (§22.3).
struct RuleCheckLine: Equatable {
    enum Kind { case wins, shadowed, disabledMatch, noMatch }
    let kind: Kind
    let text: String
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
    /// Prüfmodus (§22.3): Status-Zeile statt Chips.
    var checkLine: RuleCheckLine?
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
                        .foregroundStyle(rule.enabled && checkLine?.kind != .noMatch ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(position)")
                        .font(DS.small.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Position \(position)")
                }
                if let checkLine {
                    statusLine(checkLine)
                } else {
                    chips
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// Symbol + Text, nie nur Farbe (§22.3).
    @ViewBuilder private func statusLine(_ line: RuleCheckLine) -> some View {
        if line.kind == .disabledMatch {
            Chip(line.text, outlined: true, onAccent: onAccent, maxWidth: 200)
        } else {
            let (symbol, color): (String, Color) = switch line.kind {
            case .wins: ("checkmark", DS.green)
            case .shadowed: ("exclamationmark.triangle", DS.orange)
            case .disabledMatch, .noMatch: ("xmark", .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
                Text(line.text)
                    .font(line.kind == .wins ? DS.small.weight(.semibold) : DS.small)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(onAccent ? Color.white : color)
            .accessibilityElement(children: .combine)
        }
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
