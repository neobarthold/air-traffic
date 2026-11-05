import AirTrafficCore
import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var model: AppModel
    @State private var isDefault = Apps.isAirTrafficDefaultBrowser
    @State private var defaultError: String?
    @State private var preview: ImportPreview?
    @State private var importError: String?
    @State private var choosyAvailable = ChoosyImporter.choosyFilesExist()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.help)
                        .foregroundStyle(DS.orange)
                        .textSelection(.enabled)
                        .tintedRow(DS.orange)
                }

                statusCard

                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(symbol: "arrow.right", title: "Wenn keine Regel passt")
                    GroupCard {
                        GroupRow(label: "Aktion", divider: false) {
                            ActionEditor(action: $model.config.defaultAction, browsers: model.config.browsers)
                        }
                    }
                }

                SafariExtensionSettingsSection(model: model)

                AssistantSettingsSection(model: model)

                UpdatesSettingsSection(updates: model.updates)

                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(symbol: "square.and.arrow.down", title: "Import & Konfiguration")
                    GroupCard {
                        if choosyAvailable {
                            GroupRow(label: "Choosy") {
                                Text("Regeln und Browser übernehmen").font(DS.body).foregroundStyle(.secondary)
                                Button("Importieren …", action: runImport)
                            }
                            if let importError {
                                Text(importError)
                                    .font(DS.help)
                                    .foregroundStyle(DS.red)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                Divider().padding(.leading, 12)
                            }
                        }
                        GroupRow(label: "Datei") {
                            Text(abbreviatedConfigPath)
                                .font(DS.mono)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(model.store.fileURL.path(percentEncoded: false))
                            Button("Im Finder zeigen", action: revealConfig)
                                .help("Konfigurationsordner im Finder zeigen")
                                .fixedSize()
                        }
                        GroupRow(divider: false) {
                            Button("Air Traffic beenden") { NSApp.terminate(nil) }
                        }
                    }
                }
            }
            .frame(maxWidth: 600)
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background(DS.textBackground)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .sheet(item: $preview) { preview in
            ImportPreviewView(
                result: preview.result,
                onReplace: { model.applyImport(preview.result, replace: true); self.preview = nil },
                onAppend: { model.applyImport(preview.result, replace: false); self.preview = nil },
                onCancel: { self.preview = nil }
            )
        }
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isDefault ? "Air Traffic ist dein Standardbrowser" : "Air Traffic ist nicht Standardbrowser")
                        .font(.system(size: 15, weight: .semibold))
                    Text(statusDetail)
                        .font(DS.help)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isDefault {
                    VStack(alignment: .trailing, spacing: 6) {
                        StatusPill(.ok, "Standardbrowser")
                        TextLinkButton("Status prüfen", action: refresh)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Als Standardbrowser festlegen", action: makeDefault)
                            .buttonStyle(.borderedProminent)
                        TextLinkButton("Status prüfen", action: refresh)
                    }
                }
            }
            if let defaultError {
                Text(defaultError).font(DS.help).foregroundStyle(DS.red).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: DS.cardRadius).fill(DS.controlBackground))
        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius).strokeBorder(DS.separator, lineWidth: 0.5))
    }

    private var statusDetail: String {
        guard isDefault else { return "Links öffnen direkt im bisherigen Browser – Regeln greifen nicht." }
        let count = model.config.rules.filter(\.enabled).count
        let rules = count == 1 ? "1 Regel" : "\(count) Regeln"
        return "Jeder Link läuft durch \(rules). Ohne Treffer: \(ActionText.describe(model.config.defaultAction))."
    }

    private var abbreviatedConfigPath: String {
        (model.store.fileURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    private func refresh() {
        isDefault = Apps.isAirTrafficDefaultBrowser
        choosyAvailable = ChoosyImporter.choosyFilesExist()
    }

    /// Nur auf Knopfdruck – macOS fragt selbst nach.
    private func makeDefault() {
        defaultError = nil
        let appURL = Bundle.main.bundleURL
        let workspace = NSWorkspace.shared
        workspace.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "http") { error in
            Task { @MainActor in
                if let error {
                    defaultError = "http: \(error.localizedDescription)"
                    refresh()
                    return
                }
                NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: "https") { error in
                    Task { @MainActor in
                        if let error { defaultError = "https: \(error.localizedDescription)" }
                        refresh()
                    }
                }
            }
        }
    }

    private func runImport() {
        importError = nil
        do {
            let result = try ChoosyImporter.importConfig(
                behavioursURL: ChoosyImporter.defaultBehavioursURL,
                preferencesURL: ChoosyImporter.defaultPreferencesURL
            )
            preview = ImportPreview(result: result)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func revealConfig() {
        let file = model.store.fileURL
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let dir = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }
}

struct ImportPreview: Identifiable {
    let id = UUID()
    let result: ImportResult
}

struct ImportPreviewView: View {
    let result: ImportResult
    let onReplace: () -> Void
    let onAppend: () -> Void
    let onCancel: () -> Void

    private var reviewIDs: Set<UUID> { Set(result.rulesNeedingReview.map(\.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Aus Choosy importieren").font(.title2.bold())
            Text("\(result.config.rules.count) Regeln, \(result.config.browsers.count) Browser, Standardaktion: \(ActionText.describe(result.config.defaultAction))")
                .foregroundStyle(.secondary)

            List {
                Section("Regeln") {
                    ForEach(result.config.rules) { rule in
                        HStack {
                            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(rule.enabled ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(rule.name)
                                Text(RuleText.summary(rule)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if reviewIDs.contains(rule.id) {
                                Text("prüfen")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(.orange.opacity(0.25)))
                            }
                        }
                    }
                }
                if !result.config.browsers.isEmpty {
                    Section("Browser") {
                        ForEach(result.config.browsers, id: \.path) { app in
                            Text("\(app.displayName) – \(app.path)")
                        }
                    }
                }
                if !result.report.isEmpty {
                    Section("Hinweise") {
                        ForEach(result.report) { note in
                            VStack(alignment: .leading) {
                                if let name = note.ruleName { Text(name).bold() }
                                Text(note.message).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 280)

            HStack {
                Button("Abbrechen", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Anhängen", action: onAppend)
                Button("Ersetzen", action: onReplace).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}
