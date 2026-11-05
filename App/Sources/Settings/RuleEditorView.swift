import AirTrafficCore
import SwiftUI

/// Regel-Editor (SPEC §14, §15.4): Kopf, Ablauf „Wenn → Umschreiben → Öffnen“, Testleiste unten.
struct RuleEditorView: View {
    @Binding var rule: Rule
    @Bindable var model: AppModel
    /// Position in der Gesamtliste (1-basiert).
    let position: Int
    /// „Regel n zeigen“ im Vorrang-Hinweis: diese Regel in der Liste auswählen.
    let onShowRule: (UUID) -> Void
    @State private var assistRequest: RegexAssistantRequest?
    @State private var showKeyHint = false
    @State private var showSimulation = false
    @State private var simulatedSource = ""
    @State private var simulatedModifiers: ModifierSet = []
    @State private var editorHeight: CGFloat = 560
    @State private var resultHeight: CGFloat = 20

    /// Test-URL der Regel (§14.1); leer = nil, damit nichts geschrieben wird.
    private var testURLText: Binding<String> {
        Binding(
            get: { rule.testURL ?? "" },
            set: { rule.testURL = $0.isEmpty ? nil : $0 }
        )
    }

    private var trimmedTestURL: String {
        (rule.testURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gültige Test-URL (mit Schema) oder nil.
    private var testURL: URL? {
        guard !trimmedTestURL.isEmpty, let url = URL(string: trimmedTestURL),
              let scheme = url.scheme, !scheme.isEmpty
        else { return nil }
        return url
    }

    private var testContext: LinkContext {
        let id = simulatedSource.trimmingCharacters(in: .whitespaces)
        return LinkContext(sourceBundleIdentifier: id.isEmpty ? nil : id, modifiers: simulatedModifiers)
    }

    private var simulationActive: Bool {
        !simulatedSource.trimmingCharacters(in: .whitespaces).isEmpty || !simulatedModifiers.isEmpty
    }

    var body: some View {
        let result = testURL.map {
            RuleEngine.test(rule: rule, url: $0, context: testContext, config: model.config)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pipeline(result)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { testBar(result) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { editorHeight = $0 }
        .sheet(item: $assistRequest) { request in
            RegexAssistantSheet(
                request: request,
                subtitle: model.assistantSubtitle,
                recipient: model.assistantProvider.recipient,
                makeAssistant: model.makeRegexAssistant
            )
        }
        .alert(unavailableTitle, isPresented: $showKeyHint) {
            Button("Zu „Allgemein“") { model.settingsTab = .general }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(unavailableMessage)
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            RuleTargetIcon(action: rule.action, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                InlineNameField(text: $rule.name)
                Text(position == 1
                     ? "Regel 1 von \(model.config.rules.count) · wird als erste geprüft"
                     : "Regel \(position) von \(model.config.rules.count)")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            Spacer(minLength: 12)
            Toggle("Aktiv", isOn: $rule.enabled)
                .toggleStyle(.switch)
                .font(DS.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Ablauf

    private func pipeline(_ result: RuleTestResult?) -> some View {
        let matched = result?.matches == true
        let nodes: [PipelineNode.State] = if let result {
            [
                result.matches ? .passed : .failed,
                result.matches && !rule.rewrites.isEmpty ? .passed : .idle,
                result.matches ? .passed : .idle,
            ]
        } else {
            [.neutral(1), .neutral(2), .neutral(3)]
        }
        let rail = matched ? DS.green.opacity(0.55) : DS.separator
        return VStack(alignment: .leading, spacing: 12) {
            PipelineRow(node: nodes[0], railBelow: rail) { conditionsCard(result) }
            PipelineRow(node: nodes[1], railBelow: rail) { rewritesCard(result) }
            PipelineRow(node: nodes[2], railBelow: nil) { actionCard }
        }
    }

    private func conditionsCard(_ result: RuleTestResult?) -> some View {
        StageCard(symbol: "line.3.horizontal.decrease", title: "Wenn", subtitle: "diese Bedingungen zutreffen:") {
            Picker("Passt, wenn", selection: $rule.match) {
                Text("alle").tag(MatchMode.all)
                Text("eine").tag(MatchMode.any)
                Text("keine").tag(MatchMode.none)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("alle / irgendeine / keine Bedingung muss zutreffen")
        } content: {
            ForEach(Array(rule.conditions.indices), id: \.self) { index in
                ConditionRow(
                    condition: .element(of: $rule.conditions, at: index, fallback: .linkType(.web)),
                    testResult: result.flatMap {
                        $0.conditionResults.indices.contains(index) ? $0.conditionResults[index] : nil
                    },
                    onDelete: { if rule.conditions.indices.contains(index) { rule.conditions.remove(at: index) } },
                    onAssist: { target, match in assistCondition(at: index, target: target, match: match) }
                )
                Divider()
            }
            if rule.conditions.isEmpty {
                Text("Ohne Bedingungen passt die Regel immer.")
                    .font(DS.help)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            TextLinkButton("Bedingung", symbol: "plus") {
                rule.conditions.append(.host(TextMatch(op: .equals, value: "")))
            }
            .padding(.top, 8)
            .help("Bedingung hinzufügen")
        }
    }

    private var rewriteSubtitle: String {
        switch rule.rewrites.count {
        case 0: "keine – URL bleibt unverändert"
        case 1: "1 Schritt"
        case let n: "\(n) Schritte, nacheinander"
        }
    }

    private func rewritesCard(_ result: RuleTestResult?) -> some View {
        StageCard(symbol: "wand.and.rays", title: "Umschreiben", subtitle: rewriteSubtitle) {
            Button { assistRewrite(at: nil) } label: {
                Label("Neue mit KI …", systemImage: "sparkles")
            }
            .help("Neue Umschreibung mit KI beschreiben")
        } content: {
            ForEach(Array(rule.rewrites.indices), id: \.self) { index in
                RewriteRow(
                    rewrite: .element(of: $rule.rewrites, at: index, fallback: Rewrite(pattern: "", template: "")),
                    number: rule.rewrites.count > 1 ? index + 1 : nil,
                    step: result.flatMap { rewriteStep($0, at: index) },
                    onDelete: { if rule.rewrites.indices.contains(index) { rule.rewrites.remove(at: index) } },
                    onAssist: { assistRewrite(at: index) }
                )
            }
            TextLinkButton("Umschreibung", symbol: "plus") {
                rule.rewrites.append(Rewrite(pattern: "^(.*)$", template: "$1"))
            }
            .padding(.top, 8)
            .help("Umschreibung hinzufügen")
            Text("Regulärer Ausdruck auf die gesamte URL; in der Vorlage stehen $1, $2 … für Gruppen. Umschreibungen laufen nacheinander.")
                .font(DS.small)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
    }

    private var actionCard: some View {
        StageCard(symbol: "arrow.up.forward.app", title: "Öffnen") {
            ActionEditor(action: $rule.action, browsers: model.config.browsers)
        } content: {
            EmptyView()
        }
    }

    // MARK: Testleiste

    private func testBar(_ result: RuleTestResult?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label("Test", systemImage: "flask")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .frame(width: 52, alignment: .leading)
                DSTextField("Test-URL", text: testURLText, prompt: "https://…", mono: true)
                Button { showSimulation.toggle() } label: {
                    Label("Simulieren …", systemImage: "slider.horizontal.3")
                }
                .overlay(alignment: .topTrailing) {
                    if simulationActive {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 2, y: -2)
                            .accessibilityHidden(true)
                    }
                }
                .help("Quell-App und Modifier simulieren")
                .accessibilityValue(simulationActive ? "Simulation aktiv" : "")
                .popover(isPresented: $showSimulation, arrowEdge: .top) { simulationPopover }
            }

            ScrollView {
                testResults(result)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resultHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(resultHeight, max(editorHeight * 0.4 - 40, 40)))
        }
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .background(DS.windowBackground)
        .overlay(alignment: .top) { Divider() }
    }

    private var simulationPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weitere Bedingungen simulieren").font(DS.cardTitle)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Quell-App").font(DS.body)
                    SourceAppField(bundleIdentifier: $simulatedSource).frame(width: 300)
                }
                GridRow {
                    Text("Modifier").font(DS.body)
                    ModifierToggles(modifiers: $simulatedModifiers)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder private func testResults(_ result: RuleTestResult?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let result {
                let shadowRule = result.shadowedBy.flatMap { id in model.rule(withID: id) }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if result.matches {
                        StatusPill(.ok, shadowRule == nil ? "Trifft" : "Diese Regel trifft")
                            .fixedSize()
                        opensText(result.finalURL, hypothetical: shadowRule != nil)
                            .font(DS.help)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        StatusPill(.neutral, notMatchedText(result), symbol: "xmark").fixedSize()
                    }
                    if !rule.enabled {
                        StatusPill(.neutral, "Regel ist aus – Test läuft trotzdem").fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                if let shadowRule, let shadowIndex = model.config.rules.firstIndex(where: { $0.id == shadowRule.id }) {
                    shadowRow(shadowRule, number: shadowIndex + 1)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle")
                        .font(DS.help)
                        .foregroundStyle(DS.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .tintedRow(DS.red)
                }
            } else if trimmedTestURL.isEmpty {
                StatusPill(.neutral, "Test-URL eingeben, um die Regel zu prüfen", symbol: nil).fixedSize()
            } else {
                StatusPill(.neutral, "Keine gültige URL", symbol: "exclamationmark.triangle").fixedSize()
            }
        }
        .padding(.leading, 60)
    }

    private func notMatchedText(_ result: RuleTestResult) -> String {
        guard rule.match == .all, let index = result.conditionResults.firstIndex(of: false),
              rule.conditions.indices.contains(index)
        else { return "Trifft nicht" }
        return "Trifft nicht · Bedingung \(index + 1) (\(RuleText.fieldName(rule.conditions[index]))) nicht erfüllt"
    }

    /// „öffnet ‹URL› in ‹App›“ bzw. die Aktion in Worten.
    private func opensText(_ url: URL, hypothetical: Bool) -> Text {
        let urlText = Text(url.absoluteString).font(DS.monoSmall).foregroundStyle(.primary)
        switch rule.action {
        case .open(let app):
            let appText = Text(app.displayName).fontWeight(.semibold).foregroundStyle(.primary)
            return Text("\(hypothetical ? "würde öffnen" : "öffnet") \(urlText) in \(appText)")
        case .openFirstRunning(let fallback):
            let rest = fallback.map { ", sonst in \($0.displayName)" } ?? ""
            return Text("\(hypothetical ? "würde öffnen" : "öffnet") \(urlText) im ersten laufenden Browser\(rest)")
        case .prompt(let scope):
            let which = scope == .all ? "alle Browser" : "laufende Browser"
            return Text("\(hypothetical ? "würde" : "zeigt") \(urlText) im Auswahlfenster\(hypothetical ? " zeigen" : "") (\(which))")
        }
    }

    private func actionPhrase(_ action: Action) -> String {
        switch action {
        case .open(let app): "öffnet \(app.displayName)"
        case .openFirstRunning: "öffnet den ersten laufenden Browser"
        case .prompt: "zeigt die Auswahl"
        }
    }

    private func shadowRow(_ other: Rule, number: Int) -> some View {
        let name = other.name.isEmpty ? "Ohne Namen" : other.name
        let emphasized = Text("„\(name)“ (Regel \(number))").fontWeight(.semibold)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)
            Text("Bei einem echten Klick greift zuerst \(emphasized) und \(actionPhrase(other.action)). Diese Regel wird für diese URL nie erreicht.")
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Regel \(number) zeigen") { onShowRule(other.id) }
                .foregroundStyle(.primary)
                .fixedSize()
        }
        .font(DS.help)
        .foregroundStyle(DS.orange)
        .tintedRow(DS.orange)
        .accessibilityElement(children: .combine)
    }

    /// Eingabe und Zwischenergebnis der Umschreibung `index` für die Test-URL.
    private func rewriteStep(_ result: RuleTestResult, at index: Int) -> RewriteStep? {
        guard result.rewriteSteps.indices.contains(index) else { return nil }
        let input = index == 0 ? (testURL?.absoluteString ?? "") : result.rewriteSteps[index - 1]
        return RewriteStep(input: input, output: result.rewriteSteps[index])
    }

    // MARK: KI-Assistent

    /// Alert ohne Verfügbarkeit nennt den aktiven Anbieter (§16.4).
    private var unavailableTitle: String {
        switch model.assistantProvider {
        case .openRouter: "Kein API-Key für den KI-Assistenten"
        case .claudeCLI, .codexCLI: "\(model.assistantProvider.displayName) nicht gefunden"
        }
    }

    private var unavailableMessage: String {
        switch model.assistantProvider {
        case .openRouter:
            "Trage unter Allgemein → „KI-Assistent“ einen OpenRouter-API-Key ein oder wähle einen anderen Anbieter."
        case .claudeCLI, .codexCLI:
            "Der KI-Assistent nutzt „\(model.assistantProvider.pickerTitle)“, aber die CLI wurde nicht gefunden. "
                + "Unter Allgemein → „KI-Assistent“ kannst du den Pfad wählen oder einen anderen Anbieter einstellen."
        }
    }

    private func openAssistant(_ request: RegexAssistantRequest) {
        model.refreshAssistantKey()
        if model.assistantAvailable {
            assistRequest = request
            return
        }
        // CLI evtl. nur über die Login-Shell auffindbar.
        Task {
            await model.refreshAssistantAvailability()
            if model.assistantAvailable {
                assistRequest = request
            } else {
                showKeyHint = true
            }
        }
    }

    /// `index == nil` → neue Umschreibung; sonst diese ersetzen/verfeinern.
    private func assistRewrite(at index: Int?) {
        let existing = index.flatMap { rule.rewrites.indices.contains($0) ? rule.rewrites[$0] : nil }
        openAssistant(RegexAssistantRequest(
            mode: .rewrite,
            context: index.map { "Umschreibung \($0 + 1) ersetzen oder verfeinern" } ?? "Neue Umschreibung",
            examples: assistantExamples(beforeRewrite: index ?? rule.rewrites.count),
            current: existing.map { RegexSuggestion(pattern: $0.pattern, template: $0.template) },
            caseSensitive: existing?.caseSensitive ?? false,
            apply: { pattern, template, examples in
                let template = template ?? ""
                if let index, rule.rewrites.indices.contains(index) {
                    rule.rewrites[index].pattern = pattern
                    rule.rewrites[index].template = template
                } else {
                    rule.rewrites.append(Rewrite(pattern: pattern, template: template))
                }
                adoptTestURL(examples)
            }
        ))
    }

    private func assistCondition(at index: Int, target: RegexTarget, match: TextMatch) {
        openAssistant(RegexAssistantRequest(
            mode: .condition(target),
            context: "Bedingung \(index + 1): \(target == .url ? "URL" : target == .host ? "Host" : "Pfad") passt auf Regex",
            examples: assistantExamples(beforeRewrite: 0),
            current: match.value.isEmpty ? nil : RegexSuggestion(pattern: match.value, template: nil),
            caseSensitive: match.caseSensitive,
            apply: { pattern, _, examples in
                guard rule.conditions.indices.contains(index) else { return }
                switch rule.conditions[index] {
                case .url(var m): m.value = pattern; rule.conditions[index] = .url(m)
                case .host(var m): m.value = pattern; rule.conditions[index] = .host(m)
                case .path(var m): m.value = pattern; rule.conditions[index] = .path(m)
                default: break
                }
                adoptTestURL(examples)
            }
        ))
    }

    /// Noch keine Test-URL? Dann die erste Beispiel-URL aus dem Sheet übernehmen.
    private func adoptTestURL(_ examples: [String]) {
        guard trimmedTestURL.isEmpty, let first = examples.first else { return }
        rule.testURL = first
    }

    /// Vorbelegung der Beispiel-URLs im KI-Sheet (§14.1): Test-URL nach den Umschreibungen vor `index`.
    private func assistantExamples(beforeRewrite index: Int) -> [String] {
        guard !trimmedTestURL.isEmpty else { return [] }
        var text = trimmedTestURL
        for rewrite in rule.rewrites.prefix(index) {
            guard let next = try? Rewriter.apply(rewrite, to: text) else { break }
            text = next
        }
        return [text]
    }
}

// MARK: - Bausteine

/// Zeile im Ablauf: Knoten links, Schiene zur nächsten Stufe, Karte rechts.
private struct PipelineRow<Content: View>: View {
    let node: PipelineNode.State
    let railBelow: Color?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PipelineNode(state: node).padding(.top, 8)
            content
        }
        .background(alignment: .topLeading) {
            if let railBelow {
                // Von Knotenmitte bis zur Mitte des nächsten Knotens (Zeilenabstand 12).
                Rectangle()
                    .fill(railBelow)
                    .frame(width: 2)
                    .padding(.top, 20)
                    .padding(.bottom, -32)
                    .offset(x: 11)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Regelname als Inline-Textfeld (Titel 20 semibold, feiner Rahmen bei Hover und Fokus).
private struct InlineNameField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        TextField("Name", text: $text, prompt: Text("Ohne Namen"))
            .textFieldStyle(.plain)
            .font(DS.title)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: DS.fieldRadius)
                    .fill(focused ? DS.textBackground : (hovering ? DS.neutralFill : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.fieldRadius)
                    .strokeBorder(
                        focused ? Color.accentColor : DS.hairline,
                        lineWidth: focused ? 1 : (hovering ? 0.5 : 0)
                    )
            )
            .onHover { hovering = $0 }
            .accessibilityLabel("Regelname")
    }
}

/// Eingabe und Ergebnis einer Umschreibung für die Test-URL.
private struct RewriteStep {
    let input: String
    let output: String
}

private struct ConditionRow: View {
    @Binding var condition: Condition
    /// Ergebnis für die Test-URL; nil = keine gültige Test-URL.
    let testResult: Bool?
    let onDelete: () -> Void
    let onAssist: (RegexTarget, TextMatch) -> Void

    private enum Kind: Hashable, CaseIterable {
        case url, host, path, sourceApp, modifiers, linkType
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch condition {
                case .url: .url
                case .host: .host
                case .path: .path
                case .sourceApp: .sourceApp
                case .modifiers: .modifiers
                case .linkType: .linkType
                }
            },
            set: { newKind in
                let text: TextMatch = switch condition {
                case .url(let m), .host(let m), .path(let m): m
                default: TextMatch(op: .equals, value: "")
                }
                switch newKind {
                case .url: condition = .url(text)
                case .host: condition = .host(text)
                case .path: condition = .path(text)
                case .sourceApp: condition = .sourceApp(bundleIdentifier: "", negated: false)
                case .modifiers: condition = .modifiers([.command], negated: false)
                case .linkType: condition = .linkType(.web)
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("Feld", selection: kind) {
                    Text("URL").tag(Kind.url)
                    Text("Host").tag(Kind.host)
                    Text("Pfad").tag(Kind.path)
                    Text("Quell-App").tag(Kind.sourceApp)
                    Text("Modifier").tag(Kind.modifiers)
                    Text("Linktyp").tag(Kind.linkType)
                }
                .labelsHidden()
                .fixedSize()
                .help("Feld")

                operatorPicker

                Spacer(minLength: 0)
                if let testResult { ConditionStatus(passed: testResult) }
            }
            HStack(spacing: 6) {
                valueEditor
                tools
            }
            if let error = regexError {
                Text(error).font(DS.small).foregroundStyle(DS.red).textSelection(.enabled)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var operatorPicker: some View {
        switch condition {
        case .url(let m), .host(let m), .path(let m):
            Picker("Operator", selection: textBinding(m, \.op)) {
                ForEach(TextOp.allCases, id: \.self) { Text(RuleText.opName($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Operator")
        case .sourceApp(let id, let negated):
            Picker("Operator", selection: Binding(
                get: { negated },
                set: { condition = .sourceApp(bundleIdentifier: id, negated: $0) }
            )) {
                Text("ist").tag(false)
                Text("ist nicht").tag(true)
            }
            .labelsHidden()
            .fixedSize()
        case .modifiers(let set, let negated):
            Picker("Operator", selection: Binding(
                get: { negated },
                set: { condition = .modifiers(set, negated: $0) }
            )) {
                Text("sind genau").tag(false)
                Text("sind nicht genau").tag(true)
            }
            .labelsHidden()
            .fixedSize()
        case .linkType:
            EmptyView()
        }
    }

    @ViewBuilder private var valueEditor: some View {
        switch condition {
        case .url(let m), .host(let m), .path(let m):
            DSTextField("Wert", text: textBinding(m, \.value), mono: true, isError: regexError != nil)
        case .sourceApp(let id, let negated):
            SourceAppField(bundleIdentifier: Binding(
                get: { id },
                set: { condition = .sourceApp(bundleIdentifier: $0, negated: negated) }
            ))
        case .modifiers(let set, let negated):
            ModifierToggles(modifiers: Binding(
                get: { set },
                set: { condition = .modifiers($0, negated: negated) }
            ))
            Spacer(minLength: 0)
        case .linkType(let type):
            Picker("Linktyp", selection: Binding(
                get: { type },
                set: { condition = .linkType($0) }
            )) {
                Text("Web (http/https)").tag(LinkType.web)
                Text("Datei").tag(LinkType.file)
            }
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var tools: some View {
        switch condition {
        case .url(let m), .host(let m), .path(let m):
            AaToggle(isOn: textBinding(m, \.caseSensitive))
            if m.op == .regex {
                IconButton("sparkles", help: "Regex mit KI erstellen", tint: DS.brand) { onAssist(regexTarget, m) }
            }
        default:
            EmptyView()
        }
        IconButton("minus", help: "Bedingung entfernen", action: onDelete)
    }

    private var regexTarget: RegexTarget {
        switch condition {
        case .host: .host
        case .path: .path
        default: .url
        }
    }

    private var regexError: String? {
        switch condition {
        case .url(let m), .host(let m), .path(let m):
            guard m.op == .regex else { return nil }
            return Rewriter.validationError(for: Rewrite(pattern: m.value, template: "", caseSensitive: m.caseSensitive))
                .map { "Ungültiger regulärer Ausdruck: \($0)" }
        default:
            return nil
        }
    }

    private func textBinding<T>(_ current: TextMatch, _ keyPath: WritableKeyPath<TextMatch, T>) -> Binding<T> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                var m = current
                m[keyPath: keyPath] = newValue
                switch condition {
                case .url: condition = .url(m)
                case .host: condition = .host(m)
                case .path: condition = .path(m)
                default: break
                }
            }
        )
    }
}

private struct RewriteRow: View {
    @Binding var rewrite: Rewrite
    /// Schrittnummer (ab 2 Schritten), sonst nil.
    let number: Int?
    /// Zwischenergebnis für die Test-URL; nil = keine gültige Test-URL.
    let step: RewriteStep?
    let onDelete: () -> Void
    let onAssist: () -> Void

    private var error: String? { Rewriter.validationError(for: rewrite) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let number {
                HStack(spacing: 6) {
                    Text("\(number)")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(DS.neutralFill))
                    Text("Schritt \(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 8) {
                label("Muster")
                DSTextField("Muster", text: $rewrite.pattern, prompt: "Regex", mono: true, isError: error != nil)
                AaToggle(isOn: $rewrite.caseSensitive)
                IconButton("sparkles", help: "Diesen Schritt mit KI verfeinern", tint: DS.brand, action: onAssist)
                IconButton("minus", help: "Umschreibung entfernen", action: onDelete)
            }
            .padding(.vertical, 5)
            HStack(spacing: 8) {
                label("Vorlage")
                DSTextField("Vorlage", text: $rewrite.template, prompt: "Vorlage mit $1 …", mono: true)
                Color.clear.frame(width: 24 + 22 + 22 + 16, height: 1)
            }
            .padding(.vertical, 5)
            preview
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(DS.small).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
    }

    @ViewBuilder private var preview: some View {
        Group {
            if let error {
                Text("Ungültiger regulärer Ausdruck: \(error)")
                    .font(DS.small)
                    .foregroundStyle(DS.red)
                    .textSelection(.enabled)
            } else if let step {
                if !patternMatches(step.input) {
                    Text("Muster trifft nicht – URL bleibt unverändert")
                        .font(DS.small)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        groupLegend(step.input)
                        resultBlock(step)
                        if Rewriter.validURL(step.output) == nil {
                            Text("Ergebnis ist keine gültige URL – es würde die Original-URL verwendet.")
                                .font(DS.small)
                                .foregroundStyle(DS.red)
                        }
                    }
                }
            }
        }
        .padding(.leading, 60)
        .padding(.vertical, 2)
    }

    /// „Gruppen: $1 = … $2 = …“ für den ersten Treffer des Musters.
    @ViewBuilder private func groupLegend(_ input: String) -> some View {
        let groups = captureGroups(in: input)
        if !groups.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 4) {
                Text("Gruppen:").font(DS.small).foregroundStyle(.secondary)
                ForEach(Array(groups.enumerated()), id: \.offset) { index, value in
                    let color = DS.groupColors[index % DS.groupColors.count]
                    Text("$\(index + 1) = \(value)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.14)))
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var regex: NSRegularExpression? {
        try? NSRegularExpression(pattern: rewrite.pattern, options: rewrite.caseSensitive ? [] : [.caseInsensitive])
    }

    private func patternMatches(_ input: String) -> Bool {
        regex?.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
    }

    private func captureGroups(in input: String) -> [String] {
        guard let regex, let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              match.numberOfRanges > 1
        else { return [] }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: input).map { String(input[$0]) } ?? ""
        }
    }

    /// Eingabe (sekundär) und „→ Ausgabe“, geänderter Mittelteil grün hinterlegt; immer vollständig.
    private func resultBlock(_ step: RewriteStep) -> some View {
        var output = AttributedString("→ ")
        if let changed = TextDiff.changedRange(from: step.input, to: step.output) {
            output += AttributedString(String(step.output[..<changed.lowerBound]))
            var middle = AttributedString(String(step.output[changed]))
            middle.backgroundColor = DS.green.opacity(DS.tint)
            middle.foregroundColor = DS.green
            output += middle
            output += AttributedString(String(step.output[changed.upperBound...]))
        } else {
            output += AttributedString(step.output)
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(step.input).foregroundStyle(.secondary)
            Text(output).foregroundStyle(.primary)
        }
        .font(DS.monoSmall)
        .lineSpacing(2)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.neutralFill))
    }
}
