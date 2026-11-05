import AppKit
import SafariServices
import SwiftUI

/// Einstellungen → Allgemein → „Safari-Erweiterung“ (SPEC §20.3).
struct SafariExtensionSettingsSection: View {
    static let extensionIdentifier = "de.neoskop.AirTraffic.SafariExtension"

    private enum ExtensionState: Equatable {
        case unknown, enabled, disabled
    }

    @State private var state: ExtensionState = .unknown
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(symbol: "safari", title: "Safari-Erweiterung")
            GroupCard {
                Text(
                    "Links, die du in Safari anklickst, gehen nicht über den Standardbrowser. Mit der Erweiterung schickst du sie per Rechtsklick oder Symbolleisten-Knopf an Air Traffic – dann greifen deine Regeln."
                )
                .font(DS.help)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider().padding(.leading, 12)
                if let error {
                    Text(error)
                        .font(DS.help)
                        .foregroundStyle(DS.red)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider().padding(.leading, 12)
                }
                GroupRow(label: "Status", divider: false) {
                    statusPill
                    Spacer()
                    Button("In Safari aktivieren …", action: showInSafari)
                        .help("Safari → Einstellungen → Erweiterungen öffnen")
                }
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
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
