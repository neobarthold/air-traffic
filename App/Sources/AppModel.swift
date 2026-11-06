import AirTrafficCore
import AppKit
import Observation

/// Tabs des Einstellungsfensters in Toolbar-Reihenfolge (§23.5).
enum SettingsTab: Hashable, CaseIterable {
    case general, browsers, rules, safari, maintenance

    var label: String {
        switch self {
        case .general: "Allgemein"
        case .browsers: "Browser"
        case .rules: "Regeln"
        case .safari: "Safari"
        case .maintenance: "Updates & Import"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .browsers: "globe"
        case .rules: "point.topleft.down.to.point.bottomright.curvepath"
        case .safari: "safari"
        case .maintenance: "arrow.triangle.2.circlepath"
        }
    }
}

/// Hält die Konfiguration und speichert Änderungen debounced (300 ms).
@MainActor
@Observable
final class AppModel {
    let store: ConfigStore

    var config: Config {
        didSet {
            if config != oldValue, !isApplyingExternalChange { scheduleSave() }
            if config.appearance != oldValue.appearance { applyAppearanceIfEnabled() }
        }
    }

    /// Letzter Lade-/Speicherfehler für die Anzeige in den Einstellungen.
    var problem: String?

    // MARK: Änderungen von außen (§24.5)

    /// Hinweis „Regeln wurden von außen geändert und neu geladen.“ (orange Zeile, 6 s oder Klick).
    private(set) var showsExternalChangeNotice = false
    /// Zählt Neuladen von außen; Ansichten mit eigenem Zustand (Regel-Editor) bauen sich damit neu auf.
    private(set) var externalReloadCount = 0
    /// Fingerabdruck der zuletzt geladenen/gespeicherten Datei; Grundlage der Konfliktentscheidung.
    @ObservationIgnored private var knownFingerprint: String?
    @ObservationIgnored private var isApplyingExternalChange = false
    @ObservationIgnored private var watcher: ConfigFileWatcher?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// Ausgewählter Tab im Einstellungsfenster (z. B. Sprung zu „Allgemein“ aus dem Regel-Editor).
    var settingsTab: SettingsTab = .general

    /// Ausgewählte Regel im Tab „Regeln“ (bleibt beim Tab-Wechsel erhalten).
    var selectedRuleID: UUID?

    // MARK: Suche und URL-Prüfung der Regel-Liste (§13.2, §22)

    /// Inhalt des Suchfelds im Tab „Regeln“: Text oder zu prüfende URL.
    var ruleQuery = "" {
        didSet {
            // „Als Text suchen“ gilt nur für den Inhalt, für den es gewählt wurde (§22.1).
            if ruleQueryForcedText != nil, ruleQueryForcedText != ruleQuery { ruleQueryForcedText = nil }
            resetRuleCheckIfInactive()
        }
    }

    /// Inhalt, für den „Als Text suchen“ gewählt wurde; nil = automatische Erkennung.
    var ruleQueryForcedText: String? {
        didSet { resetRuleCheckIfInactive() }
    }

    /// Prüfmodus: „Alle Regeln“ statt „Nur Treffer“ (§22.2).
    var ruleCheckShowsAll = false
    /// Simulation im Prüfmodus (Quell-App, Modifier); gilt für Liste und Editor (§22.2, §22.4).
    var ruleCheckSource = ""
    var ruleCheckModifiers: ModifierSet = []

    /// Geprüfte URL, wenn das Suchfeld eine vollständige URL enthält und nicht als Text erzwungen ist.
    var ruleCheckURL: URL? {
        ruleQueryForcedText == ruleQuery ? nil : RuleCheck.url(from: ruleQuery)
    }

    var ruleCheckContext: LinkContext {
        let id = ruleCheckSource.trimmingCharacters(in: .whitespaces)
        return LinkContext(sourceBundleIdentifier: id.isEmpty ? nil : id, modifiers: ruleCheckModifiers)
    }

    /// Verlassen des Prüfmodus setzt Ansicht und Simulation zurück (§22.2).
    private func resetRuleCheckIfInactive() {
        guard ruleCheckURL == nil else { return }
        if ruleCheckShowsAll { ruleCheckShowsAll = false }
        if !ruleCheckSource.isEmpty { ruleCheckSource = "" }
        if !ruleCheckModifiers.isEmpty { ruleCheckModifiers = [] }
    }

    /// `false` = nichts speichern (`--snapshot`); die Konfiguration bleibt unangetastet.
    @ObservationIgnored let persists: Bool

    /// `true` = `config.appearance` steuert `NSApp.appearance` (§23.1). Aus in `--snapshot`,
    /// das die Darstellung selbst setzt.
    @ObservationIgnored var appliesAppearance = false {
        didSet { applyAppearanceIfEnabled() }
    }

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
            if let loaded = try store.loadSnapshot() {
                config = loaded.config
                knownFingerprint = loaded.fingerprint
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
        if persists {
            watcher = ConfigFileWatcher(fileURL: store.fileURL) { [weak self] in self?.checkForExternalChange() }
        }
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

    /// Koordiniert und atomar; wurde die Datei inzwischen von außen geändert, wird nicht
    /// überschrieben, sondern neu geladen (§24.5).
    private func saveNow() {
        saveTask = nil
        guard persists else { return }
        do {
            switch try store.save(config, ifUnchangedSince: knownFingerprint) {
            case .saved(let fingerprint):
                knownFingerprint = fingerprint
                if problem?.hasPrefix("Speichern") == true || problem?.hasPrefix("Von außen") == true { problem = nil }
            case .conflict(let current):
                Log.config.info("Speichern übersprungen: Konfiguration wurde von außen geändert")
                applyExternal(current)
            case .conflictUnreadable(let message):
                problem = "Von außen geändert, aber nicht lesbar (\(message)) – deine Änderung wurde nicht gespeichert."
            }
        } catch {
            problem = "Speichern fehlgeschlagen: \(error.localizedDescription)"
            Log.config.error("Speichern fehlgeschlagen: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Änderungen von außen (§24.5)

    /// Nach einer Datei-Benachrichtigung: eigene Speichervorgänge (gleicher Fingerabdruck) ignorieren.
    func checkForExternalChange() {
        guard persists else { return }
        let data: Data?
        do {
            data = try store.coordinatedData()
        } catch {
            Log.config.error("Konfiguration nicht lesbar: \(String(describing: error), privacy: .public)")
            return
        }
        guard ConfigSync.changeDecision(known: knownFingerprint, current: data.map(ConfigStore.fingerprint)) == .reload,
              let data
        else { return }
        do {
            applyExternal(ConfigSnapshot(config: try ConfigStore.decode(data), fingerprint: ConfigStore.fingerprint(data)))
        } catch {
            // Nicht übernehmen und nicht überschreiben: Speichern meldet den Konflikt, bis die Datei wieder gültig ist.
            problem = "Von außen geändert, aber nicht lesbar (\(error.localizedDescription))."
            Log.config.error("Externe Änderung nicht lesbar: \(String(describing: error), privacy: .public)")
        }
    }

    /// Übernimmt den Stand von der Platte; eine ausstehende eigene Änderung verfällt.
    private func applyExternal(_ snapshot: ConfigSnapshot) {
        saveTask?.cancel()
        saveTask = nil
        knownFingerprint = snapshot.fingerprint
        isApplyingExternalChange = true
        config = snapshot.config
        isApplyingExternalChange = false
        if let id = selectedRuleID, !config.rules.contains(where: { $0.id == id }) { selectedRuleID = nil }
        if problem?.hasPrefix("Von außen") == true { problem = nil }
        externalReloadCount += 1
        Log.config.info("Konfiguration von außen geändert und neu geladen")
        showExternalChangeNotice()
    }

    private func showExternalChangeNotice() {
        showsExternalChangeNotice = true
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.showsExternalChangeNotice = false
        }
    }

    func dismissExternalChangeNotice() {
        noticeTask?.cancel()
        showsExternalChangeNotice = false
    }

    // MARK: Darstellung (§23.1)

    /// Picker in Allgemein → „Darstellung“; `.system` landet als `nil` in der Config.
    var appearance: AppAppearance {
        get { config.effectiveAppearance }
        set { config.appearance = newValue }
    }

    /// Gilt für alle Fenster der App, auch das Auswahlfenster, Sheets, Popover und Alerts.
    private func applyAppearanceIfEnabled() {
        guard appliesAppearance else { return }
        NSApp.appearance = switch config.effectiveAppearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
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
