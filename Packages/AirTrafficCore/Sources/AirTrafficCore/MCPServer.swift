import Foundation

/// MCP-Server über stdio (SPEC §24.6): JSON-RPC 2.0, eine Nachricht pro Zeile, ohne SDK.
/// `handle(line:)` ist rein bis auf die Agenten-Operationen; die Schleife liegt im Tool.
public struct MCPServer: Sendable {
    public static let defaultProtocolVersion = "2025-06-18"
    public static let supportedProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    public static let instructions = """
        Air Traffic leitet Links nach Regeln an Browser und Apps weiter. Rufe zuerst describe_rule_format und list_rules auf; \
        die Regeln werden von oben nach unten geprüft, die erste aktive passende gewinnt. \
        Prüfe jede Änderung mit check_url (oder einer testURL in der Regel) – vor jedem Schreiben legt Air Traffic eine Sicherung an. \
        Neue Regeln und Änderungen an rewrites oder action warten auf Freigabe durch den Nutzer in der App (pendingApproval: true) \
        und wirken bis dahin nicht; Name, Bedingungen, testURL, Position und an/aus wirken sofort. Freigeben kann nur der Nutzer – \
        es gibt dafür kein Tool, und pendingChange in Eingaben wird abgelehnt.
        """

    public let api: AgentAPI
    public let version: String

    public init(api: AgentAPI, version: String) {
        self.api = api
        self.version = version
    }

    // MARK: JSON-RPC

    /// Eine eingehende Zeile → Antwortzeile (kompaktes JSON) oder nil (Benachrichtigung, Leerzeile).
    public func handle(line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let message = JSONValue.parse(line) else {
            return Self.error(id: .null, code: -32700, message: "Parse error").jsonString()
        }
        return handle(message: message)?.jsonString()
    }

    public func handle(message: JSONValue) -> JSONValue? {
        guard let object = message.objectValue,
              object["jsonrpc"]?.stringValue == "2.0",
              let method = object["method"]?.stringValue
        else {
            // Antworten des Clients (ohne method) ignorieren; sonst ungültige Anfrage.
            if let object = message.objectValue, object["method"] == nil, object["id"] != nil,
               object["result"] != nil || object["error"] != nil {
                return nil
            }
            return Self.error(id: message["id"] ?? .null, code: -32600, message: "Invalid Request")
        }
        let id = object["id"]
        let params = object["params"] ?? [:]

        // Benachrichtigungen (ohne id) bekommen keine Antwort.
        guard let id, !id.isNull else { return nil }

        switch method {
        case "initialize":
            return Self.result(id: id, initialize(params))
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(MCPTools.all.map(\.descriptor))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "Invalid params: name fehlt")
            }
            guard let tool = MCPTools.all.first(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            let arguments = params["arguments"] ?? [:]
            if !arguments.isNull, arguments.objectValue == nil {
                return Self.error(id: id, code: -32602, message: "Invalid params: arguments muss ein Objekt sein")
            }
            return Self.result(id: id, call(tool, arguments: arguments.objectValue ?? [:]))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    func initialize(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.defaultProtocolVersion
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "air-traffic", "title": "Air Traffic", "version": .string(self.version)],
            "instructions": .string(Self.instructions),
        ]
    }

    /// Fachfehler → `isError: true` mit Text; Erfolg → Text-JSON und `structuredContent`.
    func call(_ tool: MCPTool, arguments: [String: JSONValue]) -> JSONValue {
        do {
            let result = try tool.run(api, MCPArguments(values: arguments))
            return [
                "content": [["type": "text", "text": .string(result.json.jsonString(pretty: true))]],
                "structuredContent": result.json,
                "isError": false,
            ]
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return [
                "content": [["type": "text", "text": .string("Fehler: \(message)")]],
                "isError": true,
            ]
        }
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}

// MARK: - Argumente

/// Zugriff auf Tool-Argumente mit deutschen Fehlermeldungen.
struct MCPArguments {
    let values: [String: JSONValue]

    func string(_ key: String) throws(AgentError) -> String {
        guard let value = values[key]?.stringValue, !value.isEmpty else { throw .usage("Argument „\(key)“ fehlt (Text).") }
        return value
    }

    func optionalString(_ key: String) throws(AgentError) -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let text = value.stringValue else { throw .usage("Argument „\(key)“ muss Text sein.") }
        return text
    }

    func int(_ key: String) throws(AgentError) -> Int {
        guard let value = try optionalInt(key) else { throw .usage("Argument „\(key)“ fehlt (Zahl).") }
        return value
    }

    func optionalInt(_ key: String) throws(AgentError) -> Int? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let n = value.intValue else { throw .usage("Argument „\(key)“ muss eine ganze Zahl sein.") }
        return n
    }

    func bool(_ key: String, default fallback: Bool) throws(AgentError) -> Bool {
        guard let value = values[key], !value.isNull else { return fallback }
        guard let flag = value.boolValue else { throw .usage("Argument „\(key)“ muss true oder false sein.") }
        return flag
    }

    func object(_ key: String) throws(AgentError) -> JSONValue {
        guard let value = values[key], value.objectValue != nil else { throw .usage("Argument „\(key)“ fehlt (Objekt).") }
        return value
    }

    func modifiers(_ key: String) throws(AgentError) -> ModifierSet {
        guard let value = values[key], !value.isNull else { return [] }
        guard let list = value.arrayValue else { throw .usage("Argument „\(key)“ muss eine Liste sein.") }
        return try AgentCLI.parseModifiers(list.map { $0.stringValue ?? "" })
    }

    func checkKeys(_ allowed: Set<String>) throws(AgentError) {
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw .usage("Unbekanntes Argument „\(unknown)“ (erlaubt: \(allowed.sorted().joined(separator: ", "))).")
        }
    }
}

// MARK: - Tools

struct MCPTool: Sendable {
    var name: String
    var title: String
    var description: String
    var inputSchema: JSONValue
    var annotations: JSONValue
    var run: @Sendable (AgentAPI, MCPArguments) throws -> AgentResult

    var descriptor: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": annotations,
        ]
    }
}

enum MCPTools {
    static let ref: JSONValue = [
        "type": "string",
        "description": "Regel: UUID, UUID-Präfix (ab 6 Zeichen), Position wie \"#3\" oder exakter Name",
    ]
    static let dryRun: JSONValue = ["type": "boolean", "description": "true = nur zeigen, nichts schreiben", "default": false]

    static func readOnly(_ title: String) -> JSONValue {
        ["title": .string(title), "readOnlyHint": true, "openWorldHint": false]
    }

    static func writing(_ title: String, destructive: Bool = false, idempotent: Bool = false) -> JSONValue {
        [
            "title": .string(title), "readOnlyHint": false, "destructiveHint": .bool(destructive),
            "idempotentHint": .bool(idempotent), "openWorldHint": false,
        ]
    }

    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": false,
        ]
    }

    // JSON Schema einer Regel (Eingabe); Einzelheiten liefert describe_rule_format.
    static let textCondition: JSONValue = object([
        "type": ["type": "string", "enum": ["url", "host", "path"]],
        "op": ["type": "string", "enum": .array(TextOp.allCases.map { .string($0.rawValue) })],
        "value": ["type": "string"],
        "caseSensitive": ["type": "boolean"],
    ], required: ["type", "op", "value"])

    static let appSchema: JSONValue = [
        "description": "App als Name, Bundle-ID oder Pfad (Text) oder Objekt",
        "anyOf": [
            ["type": "string"],
            object([
                "bundleIdentifier": ["type": "string"],
                "path": ["type": "string"],
                "displayName": ["type": "string"],
            ]),
        ],
    ]

    static let ruleProperties: [String: JSONValue] = [
        "id": ["type": "string", "description": "UUID; beim Anlegen weglassen"],
        "name": ["type": "string"],
        "enabled": ["type": "boolean"],
        "match": ["type": "string", "enum": ["all", "any", "none"]],
        "conditions": [
            "type": "array",
            "items": [
                "anyOf": [
                    textCondition,
                    object(["type": ["const": "sourceApp"], "bundleIdentifier": ["type": "string"], "negated": ["type": "boolean"]],
                           required: ["type", "bundleIdentifier"]),
                    object([
                        "type": ["const": "modifiers"],
                        "modifiers": ["type": "array", "items": ["type": "string", "enum": ["command", "option", "control", "shift"]]],
                        "negated": ["type": "boolean"],
                    ], required: ["type", "modifiers"]),
                    object(["type": ["const": "linkType"], "linkType": ["type": "string", "enum": ["web", "file"]]],
                           required: ["type", "linkType"]),
                ],
            ],
        ],
        "rewrites": [
            "type": "array",
            "items": object([
                "pattern": ["type": "string", "description": "Regex auf die ganze URL"],
                "template": ["type": "string", "description": "Ersetzung mit $1, $2 …"],
                "caseSensitive": ["type": "boolean"],
            ], required: ["pattern", "template"]),
        ],
        "action": [
            "anyOf": [
                object(["type": ["const": "open"], "app": appSchema], required: ["type", "app"]),
                object(["type": ["const": "openFirstRunning"], "fallback": appSchema], required: ["type"]),
                object(["type": ["const": "prompt"], "scope": ["type": "string", "enum": ["all", "running"]]], required: ["type"]),
            ],
        ],
        "testURL": ["type": ["string", "null"], "description": "Beispiel-URL; nach jeder Änderung geprüft"],
        "position": ["type": "integer", "minimum": 1, "description": "1-basiert; oben gewinnt"],
    ]

    static let all: [MCPTool] = [
        MCPTool(
            name: "describe_rule_format",
            title: "Regelformat beschreiben",
            description: "Beschreibt das Regelformat (Bedingungen, Operatoren, Match-Modi, Aktionen, Umschreibungen mit $1) mit drei Beispielen. Vor dem ersten Anlegen oder Ändern aufrufen.",
            inputSchema: object([:]),
            annotations: readOnly("Regelformat beschreiben"),
            run: { api, args in
                try args.checkKeys([])
                return api.describeRuleFormat()
            }
        ),
        MCPTool(
            name: "list_rules",
            title: "Regeln auflisten",
            description: "Alle Regeln in Prüfreihenfolge mit Position, id, Name, aktiv, Kurzbeschreibung (mit Ziel von Umschreibungen) und pendingApproval. Oben gewinnt.",
            inputSchema: object([:]),
            annotations: readOnly("Regeln auflisten"),
            run: { api, args in
                try args.checkKeys([])
                return try api.listRules()
            }
        ),
        MCPTool(
            name: "get_rule",
            title: "Regel lesen",
            description: "Eine Regel vollständig im JSON-Format von config.json (plus position).",
            inputSchema: object(["ref": ref], required: ["ref"]),
            annotations: readOnly("Regel lesen"),
            run: { api, args in
                try args.checkKeys(["ref"])
                return try api.getRule(try args.string("ref"))
            }
        ),
        MCPTool(
            name: "create_rule",
            title: "Regel anlegen",
            description: "Legt eine Regel an (Standard: ans Ende, sonst an position). action.app darf ein App-Name, eine Bundle-ID oder ein Pfad sein. Die neue Regel wartet auf Freigabe durch den Nutzer in Air Traffic und wirkt erst danach. Antwortet mit der Regel und einer Prüfung ihrer testURL (vorher und nach Freigabe).",
            inputSchema: object([
                "rule": object(ruleProperties, required: ["name", "action"]),
                "position": ["type": "integer", "minimum": 1, "description": "Einfügeposition (1-basiert); Standard: ans Ende"],
                "dry_run": dryRun,
            ], required: ["rule"]),
            annotations: writing("Regel anlegen"),
            run: { api, args in
                try args.checkKeys(["rule", "position", "dry_run"])
                return try api.createRule(try args.object("rule"), position: try args.optionalInt("position"), dryRun: try args.bool("dry_run", default: false))
            }
        ),
        MCPTool(
            name: "update_rule",
            title: "Regel ändern",
            description: "Ändert eine Regel: Felder aus changes ersetzen die bisherigen; conditions und rewrites immer als ganze Liste angeben. testURL: null entfernt die Test-URL, position verschiebt. Änderungen an rewrites oder action warten auf Freigabe durch den Nutzer in Air Traffic.",
            inputSchema: object([
                "ref": ref,
                "changes": object(ruleProperties),
                "dry_run": dryRun,
            ], required: ["ref", "changes"]),
            annotations: writing("Regel ändern"),
            run: { api, args in
                try args.checkKeys(["ref", "changes", "dry_run"])
                return try api.updateRule(try args.string("ref"), patch: try args.object("changes"), dryRun: try args.bool("dry_run", default: false))
            }
        ),
        MCPTool(
            name: "move_rule",
            title: "Regel verschieben",
            description: "Verschiebt eine Regel an eine Position (1 = oben, gewinnt zuerst).",
            inputSchema: object([
                "ref": ref,
                "to": ["type": "integer", "minimum": 1, "description": "Zielposition (1-basiert)"],
                "dry_run": dryRun,
            ], required: ["ref", "to"]),
            annotations: writing("Regel verschieben", idempotent: true),
            run: { api, args in
                try args.checkKeys(["ref", "to", "dry_run"])
                return try api.moveRule(try args.string("ref"), to: try args.int("to"), dryRun: try args.bool("dry_run", default: false))
            }
        ),
        MCPTool(
            name: "set_rule_enabled",
            title: "Regel an/aus",
            description: "Schaltet eine Regel an oder aus. Eine Regel, die auf Freigabe wartet, wird dadurch nicht wirksam.",
            inputSchema: object([
                "ref": ref,
                "enabled": ["type": "boolean"],
                "dry_run": dryRun,
            ], required: ["ref", "enabled"]),
            annotations: writing("Regel an/aus", idempotent: true),
            run: { api, args in
                try args.checkKeys(["ref", "enabled", "dry_run"])
                guard let enabled = args.values["enabled"]?.boolValue else { throw AgentError.usage("Argument „enabled“ fehlt (true/false).") }
                return try api.setRuleEnabled(try args.string("ref"), enabled: enabled, dryRun: try args.bool("dry_run", default: false))
            }
        ),
        MCPTool(
            name: "delete_rule",
            title: "Regel löschen",
            description: "Löscht eine Regel (vorher wird eine Sicherung der Konfiguration angelegt).",
            inputSchema: object(["ref": ref, "dry_run": dryRun], required: ["ref"]),
            annotations: writing("Regel löschen", destructive: true),
            run: { api, args in
                try args.checkKeys(["ref", "dry_run"])
                return try api.deleteRule(try args.string("ref"), dryRun: try args.bool("dry_run", default: false))
            }
        ),
        MCPTool(
            name: "check_url",
            title: "URL prüfen",
            description: "Prüft eine URL gegen alle Regeln wie ein echter Klick, ohne etwas zu öffnen: welche Regel greift, Ergebnis-URL, Aktion und Status jeder Regel (wins, shadowed, disabledMatch, noMatch).",
            inputSchema: object([
                "url": ["type": "string", "description": "vollständige URL mit Schema"],
                "source": ["type": "string", "description": "Bundle-ID der Quell-App, z. B. com.tinyspeck.slackmacgap"],
                "modifiers": ["type": "array", "items": ["type": "string", "enum": ["command", "option", "control", "shift"]]],
            ], required: ["url"]),
            annotations: readOnly("URL prüfen"),
            run: { api, args in
                try args.checkKeys(["url", "source", "modifiers"])
                return try api.checkURL(try args.string("url"), source: try args.optionalString("source"), modifiers: try args.modifiers("modifiers"))
            }
        ),
        MCPTool(
            name: "list_browsers",
            title: "Browser auflisten",
            description: "Browserliste der App (Reihenfolge im Auswahlfenster) und weitere installierte Browser. Ziel-Apps in Regeln dürfen beliebige installierte Apps sein.",
            inputSchema: object([:]),
            annotations: readOnly("Browser auflisten"),
            run: { api, args in
                try args.checkKeys([])
                return try api.listBrowsers()
            }
        ),
        MCPTool(
            name: "get_settings",
            title: "Einstellungen lesen",
            description: "Standardaktion (wenn keine Regel passt), Verhalten der Safari-Erweiterung und Darstellung. Nur lesen.",
            inputSchema: object([:]),
            annotations: readOnly("Einstellungen lesen"),
            run: { api, args in
                try args.checkKeys([])
                return try api.getSettings()
            }
        ),
    ]
}
