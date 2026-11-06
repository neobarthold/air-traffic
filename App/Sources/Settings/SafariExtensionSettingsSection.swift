import AirTrafficCore
import AppKit
import SafariServices
import SwiftUI

/// Einstellungen → „Safari“ → „Safari-Erweiterung“ (SPEC §20.3, §21.2, §23.2).
struct SafariExtensionSettingsSection: View {
    static let extensionIdentifier = "de.neoskop.AirTraffic.SafariExtension"

    @Bindable var model: AppModel

    private enum ExtensionState: Equatable {
        case unknown, enabled, disabled
    }

    @State private var state: ExtensionState = .unknown
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(symbol: "safari", title: "Safari-Erweiterung")
            GroupCard {
                if let error {
                    Text(error)
                        .font(DS.help)
                        .foregroundStyle(DS.red)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider().padding(.leading, 12)
                }
                GroupRow(label: "Status") {
                    statusPill
                    Spacer()
                    Button("In Safari aktivieren …", action: showInSafari)
                        .help("Safari → Einstellungen → Erweiterungen öffnen")
                }
                behaviorRows
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    // MARK: Verhalten (§21.2)

    private var settings: ExtensionSettings { model.extensionSettings }

    private var applyRules: Binding<Bool> {
        Binding(
            get: { settings.applyRules },
            set: { value in model.updateExtensionSettings { $0.applyRules = value } }
        )
    }

    /// Picker „Wie Standardaktion“ (`nil`) / „Eigene Aktion“; eigene startet mit der Standardaktion.
    private var usesOwnAction: Binding<Bool> {
        Binding(
            get: { settings.fallbackAction != nil },
            set: { own in
                let start = model.config.defaultAction
                model.updateExtensionSettings { $0.fallbackAction = own ? ($0.fallbackAction ?? start) : nil }
            }
        )
    }

    private var ownAction: Binding<Action> {
        Binding(
            get: { settings.fallbackAction ?? model.config.defaultAction },
            set: { action in model.updateExtensionSettings { $0.fallbackAction = action } }
        )
    }

    @ViewBuilder
    private var behaviorRows: some View {
        GroupRow {
            Text("Regeln anwenden").font(DS.body)
            Spacer()
            Toggle("Regeln anwenden", isOn: applyRules)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        GroupRow {
            Text(settings.applyRules ? "Wenn keine Regel passt" : "Links aus Safari").font(DS.body)
            Spacer()
            Picker(settings.applyRules ? "Wenn keine Regel passt" : "Links aus Safari", selection: usesOwnAction) {
                Text("Wie Standardaktion").tag(false)
                Text("Eigene Aktion").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        if settings.fallbackAction != nil {
            GroupRow {
                ActionEditor(action: ownAction, browsers: model.config.browsers)
            }
        }
        Text(behaviorHelp)
            .font(DS.help)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private var behaviorHelp: String {
        let action = settings.fallbackAction.map(ActionText.describe)
            ?? "Standardaktion (\(ActionText.describe(model.config.defaultAction)))"
        let flow = settings.applyRules
            ? "Regeln und Umschreibungen greifen wie beim Standardbrowser; ohne Treffer: \(action)."
            : "Regeln werden übersprungen, der Link bleibt unverändert: \(action)."
        return "Gilt für „Mit Air Traffic öffnen“ und den Symbolleisten-Knopf. \(flow) „Mit Air Traffic auswählen …“ zeigt immer die Auswahl."
    }

    @ViewBuilder
    private var statusPill: some View {
        switch state {
        case .enabled: StatusPill(.ok, "Aktiv")
        case .disabled: StatusPill(.neutral, "Nicht aktiviert")
        case .unknown: StatusPill(.neutral, "Unbekannt", symbol: "questionmark")
        }
    }

    private func refresh() async {
        state = await Self.queryState()
    }

    /// Fehler (z. B. Erweiterung nicht registriert) → „Unbekannt“.
    private nonisolated static func queryState() async -> ExtensionState {
        do {
            let enabled = try await SFSafariExtensionManager.stateOfSafariExtension(withIdentifier: extensionIdentifier).isEnabled
            return enabled ? .enabled : .disabled
        } catch {
            Log.app.info("Status der Safari-Erweiterung unbekannt: \(error.localizedDescription, privacy: .public)")
            return .unknown
        }
    }

    private func showInSafari() {
        error = nil
        Task {
            do {
                try await SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.extensionIdentifier)
            } catch {
                self.error = "Safari-Einstellungen ließen sich nicht öffnen: \(error.localizedDescription)"
            }
        }
    }
}

/// Einstellungen → „Safari“ (§23.2): Einleitung und Abschnitt „Safari-Erweiterung“.
struct SafariSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsPage {
            PageHeaderCard(
                icon: Self.safariIcon,
                title: "Links aus Safari an Air Traffic schicken",
                detail: "Links, die du in Safari anklickst, gehen nicht über den Standardbrowser. Die Erweiterung schickt sie an Air Traffic: per Rechtsklick mit „Mit Air Traffic öffnen“ oder „Mit Air Traffic auswählen …“ und über ihren Knopf in der Symbolleiste."
            )
            SafariExtensionSettingsSection(model: model)
        }
    }

    /// Safari-Symbol; fehlt Safari (z. B. in einer VM), das Kompass-Symbol.
    private static var safariIcon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        }
        return NSImage(systemSymbolName: "safari", accessibilityDescription: nil) ?? NSApp.applicationIconImage
    }
}
