import Foundation

/// Ergebnis einer Agenten-Operation: maschinenlesbar (`json`, immer ein Objekt) und für Menschen (`text`).
public struct AgentResult: Sendable, Equatable {
    public var json: JSONValue
    public var text: String

    public init(json: JSONValue, text: String) {
        self.json = json
        self.text = text
    }
}

/// Gemeinsame Logik von Kommandozeile und MCP-Server (SPEC §24.3): lesen, prüfen, ändern.
/// Schreibt nur über `ConfigStore.modify` (koordiniert, atomar, mit Sicherung).
public struct AgentAPI: Sendable {
    public let store: ConfigStore
    public let resolver: any AppResolving
    /// Uhr für Sicherungsnamen (Tests).
    public var now: @Sendable () -> Date

    public init(store: ConfigStore, resolver: any AppResolving, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.resolver = resolver
        self.now = now
    }

    // MARK: Lesen

    /// Aktuelle Konfiguration; fehlt die Datei, eine leere (nur lesen).
    public func loadConfig() throws -> Config {
        try store.loadSnapshot()?.config ?? Config()
    }

    public func listRules() throws -> AgentResult {
        let config = try loadConfig()
        let items: [JSONValue] = config.rules.enumerated().map { index, rule in
            [
                "position": .number(Double(index + 1)),
                "id": .string(rule.id.uuidString.lowercased()),
                "name": .string(rule.name),
                "enabled": .bool(rule.enabled),
                "summary": .string(RuleDescriber.summary(rule)),
            ]
        }
        var lines = config.rules.isEmpty ? ["Keine Regeln."] : []
        let ids = config.rules.map { $0.id.uuidString.lowercased() }
        for (index, rule) in config.rules.enumerated() {
            let mark = rule.enabled ? "●" : "○"
            lines.append(String(format: "%3d  ", index + 1) + "\(mark) \(rule.name)  [\(Self.shortID(ids[index], among: ids))]")
            lines.append("       \(RuleDescriber.summary(rule))")
        }
        lines.append("")
        lines.append("Oben gewinnt: die erste aktive Regel, deren Bedingungen passen. ● aktiv, ○ aus.")
        return AgentResult(
            json: ["rules": .array(items), "count": .number(Double(config.rules.count)), "configPath": .string(configPath)],
            text: lines.joined(separator: "\n")
        )
    }

    public func getRule(_ ref: String) throws -> AgentResult {
        let config = try loadConfig()
        let index = try RuleRef.resolve(ref, in: config.rules)
        let rule = config.rules[index]
        let json = try ruleJSON(rule, position: index + 1)
        let text = "#\(index + 1) \(rule.name) (\(rule.enabled ? "aktiv" : "aus"))\n\(RuleDescriber.summary(rule))\n\n\(json.jsonString(pretty: true))"
        return AgentResult(json: ["rule": json], text: text)
    }

    // MARK: Schreiben

    /// Legt eine Regel an (Standard: ans Ende). `position` überschreibt ein `position`-Feld im JSON.
    public func createRule(_ json: JSONValue, position: Int? = nil, dryRun: Bool = false) throws -> AgentResult {
        var warnings: [String] = []
        let result = try store.modify(dryRun: dryRun, now: now()) { config throws -> UUID in
            let output = try RuleInput(resolver: resolver, browsers: config.browsers).makeRule(from: json)
            warnings = output.warnings
            try RuleEditing.insert(output.rule, at: position ?? output.position, into: &config)
            return output.rule.id
        }
        return try writeResult(
            verb: dryRun ? "Würde anlegen" : "Angelegt",
            ruleID: result.value, config: result.config, dryRun: dryRun,
            written: result.written, backup: result.backupURL, warnings: warnings
        )
    }

    /// Ersetzt die Felder aus `patch`; `conditions`/`rewrites` als ganze Liste, `position` verschiebt.
    public func updateRule(_ ref: String, patch: JSONValue, dryRun: Bool = false) throws -> AgentResult {
        var warnings: [String] = []
        let result = try store.modify(dryRun: dryRun, now: now()) { config throws -> UUID in
            let index = try RuleRef.resolve(ref, in: config.rules)
            let output = try RuleInput(resolver: resolver, browsers: config.browsers).apply(patch: patch, to: config.rules[index])
            warnings = output.warnings
            config.rules[index] = output.rule
            if let position = output.position { try RuleEditing.move(from: index, to: position, in: &config) }
            return output.rule.id
        }
        return try writeResult(
            verb: dryRun ? "Würde ändern" : (result.written ? "Geändert" : "Unverändert"),
            ruleID: result.value, config: result.config, dryRun: dryRun,
            written: result.written, backup: result.backupURL, warnings: warnings
        )
    }

    public func moveRule(_ ref: String, to position: Int, dryRun: Bool = false) throws -> AgentResult {
        let result = try store.modify(dryRun: dryRun, now: now()) { config throws -> UUID in
            let index = try RuleRef.resolve(ref, in: config.rules)
            try RuleEditing.move(from: index, to: position, in: &config)
            return config.rules[position - 1].id
        }
        return try writeResult(
            verb: dryRun ? "Würde verschieben" : (result.written ? "Verschoben" : "Unverändert"),
            ruleID: result.value, config: result.config, dryRun: dryRun,
            written: result.written, backup: result.backupURL, warnings: []
        )
    }

    public func setRuleEnabled(_ ref: String, enabled: Bool, dryRun: Bool = false) throws -> AgentResult {
        let result = try store.modify(dryRun: dryRun, now: now()) { config throws -> UUID in
            let index = try RuleRef.resolve(ref, in: config.rules)
            config.rules[index].enabled = enabled
            return config.rules[index].id
        }
        let verb = enabled ? "Aktiviert" : "Deaktiviert"
        return try writeResult(
            verb: dryRun ? "Würde \(enabled ? "aktivieren" : "deaktivieren")" : (result.written ? verb : "Unverändert"),
            ruleID: result.value, config: result.config, dryRun: dryRun,
            written: result.written, backup: result.backupURL, warnings: []
        )
    }

    public func deleteRule(_ ref: String, dryRun: Bool = false) throws -> AgentResult {
        let result = try store.modify(dryRun: dryRun, now: now()) { config throws -> (Rule, Int) in
            let index = try RuleRef.resolve(ref, in: config.rules)
            return (config.rules.remove(at: index), index)
        }
        let (rule, index) = result.value
        var json: [String: JSONValue] = [
            "deleted": try ruleJSON(rule, position: index + 1),
            "dryRun": .bool(dryRun),
            "written": .bool(result.written),
            "remaining": .number(Double(result.config.rules.count)),
        ]
        if let backup = result.backupURL { json["backup"] = .string(backup.path(percentEncoded: false)) }
        var lines = ["\(dryRun ? "Würde löschen" : "Gelöscht"): #\(index + 1) \(rule.name)", RuleDescriber.summary(rule)]
        if let backup = result.backupURL { lines.append("Sicherung: \(abbreviate(backup))") }
        if dryRun { lines.append("Probelauf – nichts geschrieben.") }
        return AgentResult(json: .object(json), text: lines.joined(separator: "\n"))
    }

    // MARK: Prüfen (§22)

    public func checkURL(_ text: String, source: String? = nil, modifiers: ModifierSet = []) throws -> AgentResult {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            throw AgentError.usage("Ungültige URL „\(text)“ – vollständig mit Schema angeben, z. B. https://…")
        }
        let config = try loadConfig()
        let source = source?.trimmingCharacters(in: .whitespaces)
        let context = LinkContext(sourceBundleIdentifier: (source ?? "").isEmpty ? nil : source, modifiers: modifiers)
        let result = RuleEngine.check(url: url, context: context, config: config)
        let byID = Dictionary(config.rules.enumerated().map { ($1.id, ($0 + 1, $1)) }, uniquingKeysWith: { a, _ in a })

        var decision: [String: JSONValue] = [
            "finalURL": .string(result.decision.finalURL.absoluteString),
            "action": try JSONValue(encoding: result.decision.action),
            "actionText": .string(RuleDescriber.action(result.decision.action)),
            "warnings": .array(result.decision.warnings.map(JSONValue.string)),
        ]
        if let id = result.decision.matchedRuleID, let (position, rule) = byID[id] {
            decision["matchedRule"] = ["position": .number(Double(position)), "id": .string(id.uuidString.lowercased()), "name": .string(rule.name)]
        } else {
            decision["matchedRule"] = .null
        }
        let entries: [JSONValue] = result.entries.map { entry in
            let rule = config.rules[entry.position - 1]
            var item: [String: JSONValue] = [
                "position": .number(Double(entry.position)),
                "id": .string(entry.ruleID.uuidString.lowercased()),
                "name": .string(rule.name),
                "enabled": .bool(rule.enabled),
                "matches": .bool(entry.matches),
                "status": .string(Self.statusName(entry.status)),
            ]
            if case .shadowed(let by) = entry.status, let (position, _) = byID[by] {
                item["shadowedByPosition"] = .number(Double(position))
            }
            if let failed = entry.firstFailedCondition {
                item["firstFailedCondition"] = .number(Double(failed + 1))
            }
            return .object(item)
        }

        var lines = ["URL: \(url.absoluteString)"]
        if let source = context.sourceBundleIdentifier { lines.append("Quell-App: \(source)") }
        if !modifiers.isEmpty { lines.append("Modifier: \(modifiers.names.joined(separator: "+"))") }
        if let id = result.decision.matchedRuleID, let (position, rule) = byID[id] {
            lines.append("Greift: #\(position) \(rule.name)")
        } else {
            lines.append("Keine Regel greift – Standardaktion.")
        }
        lines.append("Ergebnis: \(RuleDescriber.action(result.decision.action))")
        if result.decision.finalURL != url { lines.append("Umgeschrieben: \(result.decision.finalURL.absoluteString)") }
        for warning in result.decision.warnings { lines.append("Warnung: \(warning)") }
        lines.append("")
        for entry in result.entries {
            let rule = config.rules[entry.position - 1]
            lines.append(String(format: "%3d  ", entry.position) + "\(Self.statusText(entry, byID: byID)) \(rule.name)")
        }
        return AgentResult(
            json: [
                "url": .string(url.absoluteString),
                "source": source.map(JSONValue.string) ?? .null,
                "modifiers": .array(modifiers.names.map(JSONValue.string)),
                "decision": .object(decision),
                "rules": .array(entries),
            ],
            text: lines.joined(separator: "\n")
        )
    }

    /// Kürzestes eindeutiges Präfix (mindestens 8 Zeichen) – als `<ref>` verwendbar.
    static func shortID(_ id: String, among ids: [String]) -> String {
        var length = 8
        while length < id.count, ids.contains(where: { $0 != id && $0.hasPrefix(id.prefix(length)) }) {
            length += 1
        }
        return String(id.prefix(length))
    }

    static func statusName(_ status: RuleCheckStatus) -> String {
        switch status {
        case .wins: "wins"
        case .shadowed: "shadowed"
        case .disabledMatch: "disabledMatch"
        case .noMatch: "noMatch"
        }
    }

    private static func statusText(_ entry: RuleCheckEntry, byID: [UUID: (Int, Rule)]) -> String {
        let text: String = switch entry.status {
        case .wins: "greift"
        case .shadowed(let by): "verdeckt von #\(byID[by]?.0 ?? 0)"
        case .disabledMatch: "passt, aber aus"
        case .noMatch: entry.firstFailedCondition.map { "–  (Bed. \($0 + 1))" } ?? "–"
        }
        return text.padding(toLength: 18, withPad: " ", startingAt: 0)
    }

    // MARK: Browser, Einstellungen

    public func listBrowsers() throws -> AgentResult {
        let config = try loadConfig()
        let installed = resolver.installedBrowsers()
        let browsers: [JSONValue] = try config.browsers.enumerated().map { index, app in
            guard case .object(var item) = try JSONValue(encoding: app) else { return .null }
            item["position"] = .number(Double(index + 1))
            item["installed"] = .bool(resolver.isInstalled(app))
            return .object(item)
        }
        let others = installed.filter { app in !config.browsers.contains { $0.refersToSameApp(as: app) } }
        let hint = "Für Aktionen („open“, „fallback“) kann jede installierte App per Name, Bundle-ID oder Pfad angegeben werden, nicht nur Browser aus der Liste. Die Liste selbst ändert nur die App."
        var lines = config.browsers.isEmpty ? ["Keine Browserliste – die App zeigt alle installierten Browser."] : ["Browserliste (Reihenfolge im Auswahlfenster):"]
        for (index, app) in config.browsers.enumerated() {
            let missing = resolver.isInstalled(app) ? "" : "  (nicht gefunden)"
            lines.append(String(format: "%3d  ", index + 1) + "\(app.displayName)  \(app.bundleIdentifier ?? app.path)\(missing)")
        }
        if !others.isEmpty {
            lines.append("")
            lines.append("Weitere installierte Browser:")
            for app in others { lines.append("     \(app.displayName)  \(app.bundleIdentifier ?? app.path)") }
        }
        lines.append("")
        lines.append(hint)
        return AgentResult(
            json: [
                "browsers": .array(browsers),
                "otherInstalledBrowsers": .array(try others.map { try JSONValue(encoding: $0) }),
                "hint": .string(hint),
            ],
            text: lines.joined(separator: "\n")
        )
    }

    public func getSettings() throws -> AgentResult {
        let config = try loadConfig()
        let ext = config.extensionSettings ?? ExtensionSettings()
        let appearance = config.effectiveAppearance.rawValue
        var extJSON: [String: JSONValue] = ["applyRules": .bool(ext.applyRules)]
        extJSON["fallbackAction"] = try ext.fallbackAction.map { try JSONValue(encoding: $0) } ?? .null
        let lines = [
            "Konfiguration: \(abbreviate(store.fileURL))",
            "Regeln: \(config.rules.count), Browser in der Liste: \(config.browsers.count)",
            "Wenn keine Regel passt: \(RuleDescriber.action(config.defaultAction))",
            "Safari-Erweiterung: Regeln \(ext.applyRules ? "anwenden" : "überspringen"), sonst \(ext.fallbackAction.map(RuleDescriber.action) ?? "Standardaktion")",
            "Darstellung: \(appearance)",
            "",
            "Nur lesen – diese Einstellungen ändert die App.",
        ]
        return AgentResult(
            json: [
                "configPath": .string(configPath),
                "defaultAction": try JSONValue(encoding: config.defaultAction),
                "defaultActionText": .string(RuleDescriber.action(config.defaultAction)),
                "extension": .object(extJSON),
                "appearance": .string(appearance),
                "ruleCount": .number(Double(config.rules.count)),
                "browserCount": .number(Double(config.browsers.count)),
            ],
            text: lines.joined(separator: "\n")
        )
    }

    public func describeRuleFormat() -> AgentResult {
        AgentResult(json: RuleFormat.json, text: RuleFormat.text)
    }

    // MARK: Hilfen

    var configPath: String { store.fileURL.path(percentEncoded: false) }

    func ruleJSON(_ rule: Rule, position: Int) throws -> JSONValue {
        guard case .object(var object) = try JSONValue(encoding: rule) else { return .null }
        object["position"] = .number(Double(position))
        // UUIDs klein wie in den übrigen Ausgaben; `Rule` dekodiert beides.
        object["id"] = .string(rule.id.uuidString.lowercased())
        return .object(object)
    }

    /// Antwort jeder Schreiboperation: Regel nach der Änderung + `check`-Vorschau ihrer Test-URL (§24.3).
    private func writeResult(
        verb: String, ruleID: UUID, config: Config, dryRun: Bool,
        written: Bool, backup: URL?, warnings: [String]
    ) throws -> AgentResult {
        guard let index = config.rules.firstIndex(where: { $0.id == ruleID }) else {
            throw AgentError.notFound(ruleID.uuidString)
        }
        let rule = config.rules[index]
        var json: [String: JSONValue] = [
            "rule": try ruleJSON(rule, position: index + 1),
            "dryRun": .bool(dryRun),
            "written": .bool(written),
            "warnings": .array(warnings.map(JSONValue.string)),
        ]
        if let backup { json["backup"] = .string(backup.path(percentEncoded: false)) }
        var lines = ["\(verb): #\(index + 1) \(rule.name) (\(rule.enabled ? "aktiv" : "aus"))", RuleDescriber.summary(rule)]
        for warning in warnings { lines.append("Warnung: \(warning)") }

        if let preview = testPreview(rule: rule, config: config) {
            json["check"] = preview.json
            lines.append(preview.text)
        } else {
            json["check"] = .null
        }
        if let backup { lines.append("Sicherung: \(abbreviate(backup))") }
        if dryRun {
            lines.append("")
            lines.append("Probelauf – nichts geschrieben. Regel danach:")
            lines.append(try ruleJSON(rule, position: index + 1).jsonString(pretty: true))
        }
        return AgentResult(json: .object(json), text: lines.joined(separator: "\n"))
    }

    /// Kurze Prüfung der Test-URL gegen die ganze Config (ohne Quell-App/Modifier).
    func testPreview(rule: Rule, config: Config) -> (json: JSONValue, text: String)? {
        guard let text = rule.testURL?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let url = URL(string: text), url.scheme != nil
        else { return nil }
        let result = RuleEngine.check(url: url, context: LinkContext(), config: config)
        guard let entry = result.entries.first(where: { $0.ruleID == rule.id }) else { return nil }
        let winner = result.decision.matchedRuleID.flatMap { id in config.rules.firstIndex { $0.id == id } }
        let summary: String = switch entry.status {
        case .wins:
            "greift → \(RuleDescriber.action(result.decision.action))"
                + (result.decision.finalURL != url ? ", URL: \(result.decision.finalURL.absoluteString)" : "")
        case .shadowed:
            "passt, aber #\((winner ?? 0) + 1) „\(winner.map { config.rules[$0].name } ?? "?")“ greift vorher"
        case .disabledMatch:
            "passt, Regel ist aber aus"
        case .noMatch:
            "trifft nicht" + (entry.firstFailedCondition.map { " (Bedingung \($0 + 1) nicht erfüllt)" } ?? "")
        }
        var json: [String: JSONValue] = [
            "url": .string(url.absoluteString),
            "status": .string(Self.statusName(entry.status)),
            "summary": .string(summary),
            "finalURL": .string(result.decision.finalURL.absoluteString),
            "actionText": .string(RuleDescriber.action(result.decision.action)),
        ]
        if let winner { json["winnerPosition"] = .number(Double(winner + 1)) }
        return (.object(json), "Test-URL \(url.absoluteString): \(summary)")
    }

    private func abbreviate(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
