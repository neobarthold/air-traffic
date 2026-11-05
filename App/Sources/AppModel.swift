import AirTrafficCore
import Foundation
import Observation

enum SettingsTab: Hashable {
    case general, browsers, rules
}

/// Hält die Konfiguration und speichert Änderungen debounced (300 ms).
@MainActor
@Observable
final class AppModel {
    let store: ConfigStore

    var config: Config {
        didSet {
            if config != oldValue { scheduleSave() }
        }
    }

    /// Letzter Lade-/Speicherfehler für die Anzeige in den Einstellungen.
    var problem: String?

    /// Ausgewählter Tab im Einstellungsfenster (Sprung zu „Allgemein“ aus dem Regel-Editor).
    var settingsTab: SettingsTab = .general

    /// Ausgewählte Regel im Tab „Regeln“ (bleibt beim Tab-Wechsel erhalten).
    var selectedRuleID: UUID?

    /// `false` = nichts speichern (`--snapshot`); die Konfiguration bleibt unangetastet.
    @ObservationIgnored let persists: Bool

    /// Schlüsselbund-Ablage des OpenRouter-Keys (§12.1).
    @ObservationIgnored let keyStore: any APIKeyStore
    /// Key vorhanden (Schlüsselbund oder `OPENROUTER_API_KEY`); ohne Inhalt zu lesen.
    private(set) var hasAssistantKey = false

    /// Ergebnis der Binärsuche je CLI (§16.2); fehlt = noch nicht gesucht.
    private(set) var cliStatus: [AssistantCLI: CLIStatus] = [:]
    @ObservationIgnored let cliLocator: CLILocator

    /// Sparkle-Updater (§17); `nil` in `--snapshot` und Debug-Schaltern.
    @ObservationIgnored var updates: UpdateController?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(
        store: ConfigStore,
        keyStore: any APIKeyStore = KeychainAPIKeyStore(),
        cliLocator: CLILocator = .system,
        persists: Bool = true
    ) {
        self.store = store
        self.keyStore = keyStore
        self.cliLocator = cliLocator
        self.persists = persists
        do {
            if let loaded = try store.load() {
                config = loaded
                Log.config.info("Konfiguration geladen: \(store.fileURL.path, privacy: .public)")
            } else {
                config = AppModel.firstRunConfig()
                Log.config.info("Erster Start – Browser erkannt: \(self.config.browsers.count)")
                saveNow()
            }
        } catch where !persists {
            config = AppModel.firstRunConfig()
            problem = "Konfiguration war nicht lesbar (\(error.localizedDescription))."
        } catch {
            // Defekte Datei sichern statt überschreiben.
            let backup = store.fileURL.deletingPathExtension()
                .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: store.fileURL, to: backup)
            config = AppModel.firstRunConfig()
            problem = "Konfiguration war nicht lesbar (\(error.localizedDescription)). Gesichert als \(backup.lastPathComponent)."
            Log.config.error("Konfiguration nicht lesbar: \(String(describing: error), privacy: .public)")
            saveNow()
        }
        refreshAssistantKey()
    }

    /// Erster Start: installierte Browser erkennen, Auswahl zeigen, keine Regeln.
    static func firstRunConfig() -> Config {
        Config(browsers: Apps.installedBrowsers(), rules: [], defaultAction: .prompt(.all))
    }

    /// Browserliste ohne Air Traffic selbst; leer → installierte Browser.
    var effectiveBrowsers: [AppRef] {
        let list = config.browsers.filter { !Apps.isSelf($0) }
        return list.isEmpty ? Apps.installedBrowsers() : list
    }

    func rule(withID id: UUID?) -> Rule? {
        guard let id else { return nil }
        return config.rules.first { $0.id == id }
    }

    // MARK: Speichern

    private func scheduleSave() {
        guard persists else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func flushPendingSave() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveNow()
    }

    private func saveNow() {
        saveTask = nil
        guard persists else { return }
        do {
            try store.save(config)
            if problem?.hasPrefix("Speichern") == true { problem = nil }
        } catch {
            problem = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            Log.config.error("Speichern fehlgeschlagen: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: KI-Assistent

    func refreshAssistantKey() {
        let env = ProcessInfo.processInfo.environment[APIKeyResolver.environmentKey] ?? ""
        hasAssistantKey = keyStore.hasKey() || !env.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func saveAssistantKey(_ key: String) throws {
        try keyStore.saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshAssistantKey()
    }

    func deleteAssistantKey() throws {
        try keyStore.deleteKey()
        refreshAssistantKey()
    }

    // MARK: Anbieter (§16)

    var assistantProvider: AssistantProvider { config.assistantProvider }

    /// Ändert die Assistenz-Einstellungen; alles auf Standard → Abschnitt fällt aus der Config.
    func updateAssistant(_ change: (inout AssistantSettings) -> Void) {
        var settings = config.assistant ?? AssistantSettings()
        change(&settings)
        let normalized = settings.normalized()
        config.assistant = normalized.isEmpty ? nil : normalized
    }

    // MARK: Safari-Erweiterung (§21.2)

    var extensionSettings: ExtensionSettings { config.extensionSettings ?? ExtensionSettings() }

    /// Ändert das Verhalten für Links aus der Erweiterung; alles auf Standard → Abschnitt fällt aus der Config.
    func updateExtensionSettings(_ change: (inout ExtensionSettings) -> Void) {
        var settings = extensionSettings
        change(&settings)
        config.extensionSettings = settings.isDefault ? nil : settings
    }

    /// OpenRouter: Key vorhanden; CLI: Binärdatei gefunden (Cache oder schnelle Suche ohne Login-Shell).
    var assistantAvailable: Bool {
        guard let cli = assistantProvider.cli else { return hasAssistantKey }
        if cliStatus[cli]?.url != nil { return true }
        return cliLocator.locateWithoutShell(cli, configuredPath: config.assistant?.path(for: cli)) != nil
    }

    /// Vollständige Prüfung für den aktiven Anbieter (inkl. Login-Shell bei CLIs).
    func refreshAssistantAvailability() async {
        refreshAssistantKey()
        if let cli = assistantProvider.cli { await refreshCLIStatus(cli) }
    }

    /// Sucht die CLI (konfigurierter Pfad → feste Orte → Login-Shell) und liest ihre Version.
    func refreshCLIStatus(_ cli: AssistantCLI) async {
        let path = config.assistant?.path(for: cli)
        let url = await cliLocator.locate(cli, configuredPath: path)
        var version: String?
        if let url { version = await CLITransport.version(of: url) }
        // Pfad inzwischen geändert → Ergebnis verwerfen.
        guard config.assistant?.path(for: cli) == path else { return }
        cliStatus[cli] = CLIStatus(url: url, version: version)
    }

    /// Client für den Anbieter; wirft `LLMError.missingAPIKey` ohne OpenRouter-Key.
    func makeLLMClient(for provider: AssistantProvider) throws -> any LLMClient {
        switch provider {
        case .openRouter:
            return OpenRouterClient(apiKey: try APIKeyResolver.resolve(store: keyStore))
        case .claudeCLI:
            return ClaudeCLIClient(transport: transport(for: .claude))
        case .codexCLI:
            return CodexCLIClient(transport: transport(for: .codex))
        }
    }

    private func transport(for cli: AssistantCLI) -> CLITransport {
        // Gefundener Pfad zuerst, damit die Suche nicht bei jeder Anfrage läuft.
        let path = cliStatus[cli]?.url?.path(percentEncoded: false) ?? config.assistant?.path(for: cli)
        return CLITransport(cli: cli, configuredPath: path, locator: cliLocator)
    }

    /// Assistent für den aktiven Anbieter und dessen Modell.
    func makeRegexAssistant() throws -> RegexAssistant {
        let provider = assistantProvider
        return RegexAssistant(client: try makeLLMClient(for: provider), model: config.assistantModel(for: provider))
    }

    /// „Anbieter · Modell“ für das KI-Sheet.
    var assistantSubtitle: String {
        "\(assistantProvider.displayName) · \(config.assistantModelLabel(for: assistantProvider))"
    }

    // MARK: Import

    func applyImport(_ result: ImportResult, replace: Bool) {
        var next = config
        if replace {
            next.rules = result.config.rules
            next.defaultAction = result.config.defaultAction
            if !result.config.browsers.isEmpty { next.browsers = result.config.browsers }
        } else {
            next.rules += result.config.rules
            for browser in result.config.browsers where !next.browsers.contains(where: { $0.refersToSameApp(as: browser) }) {
                next.browsers.append(browser)
            }
        }
        config = next
    }
}

/// Ergebnis der Binärsuche für eine CLI.
struct CLIStatus: Equatable {
    var url: URL?
    var version: String?
}
