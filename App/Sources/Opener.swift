import AirTrafficCore
import AppKit

/// Führt eine `Decision` aus: App öffnen oder Chooser zeigen.
@MainActor
final class Opener {
    private let model: AppModel
    private let chooser: ChooserController

    init(model: AppModel, chooser: ChooserController) {
        self.model = model
        self.chooser = chooser
    }

    func execute(_ decision: Decision, context: LinkContext) {
        let url = decision.finalURL
        // Schleifenschutz (§20.1): Air Traffic öffnet `airtraffic://` nie selbst – auch nicht nach Umschreibungen.
        guard !AirTrafficURL.isAirTrafficURL(url) else {
            Log.opener.error("airtraffic-Link als Ziel verworfen (Schleifenschutz)")
            return
        }
        let request = ChooserRequest(
            url: url,
            sourceBundleIdentifier: context.sourceBundleIdentifier,
            scope: .all,
            hint: decision.warnings.first
        )

        switch decision.action {
        case .open(let app):
            openOrPrompt(url, app: app, request: request)

        case .openFirstRunning(let fallback):
            let browsers = model.effectiveBrowsers
            let target = browsers.first(where: Apps.isRunning) ?? fallback ?? browsers.first
            guard let target else {
                chooser.present(request.with(hint: "Kein Browser konfiguriert."))
                return
            }
            openOrPrompt(url, app: target, request: request)

        case .prompt(let scope):
            var r = request
            r.scope = scope
            chooser.present(r)
        }
    }

    private func openOrPrompt(_ url: URL, app: AppRef, request: ChooserRequest) {
        var target = app
        // Schleifenschutz: Ziel ist Air Traffic selbst → erster Browser.
        if Apps.isSelf(target) {
            guard let first = model.effectiveBrowsers.first else {
                chooser.present(request.with(hint: "Ziel wäre Air Traffic selbst; kein Browser konfiguriert."))
                return
            }
            Log.opener.notice("Schleifenschutz: \(app.displayName, privacy: .public) → \(first.displayName, privacy: .public)")
            target = first
        }
        if !open(url, with: target, activates: true) {
            chooser.present(request.with(hint: "„\(target.displayName)“ wurde nicht gefunden."))
        }
    }

    /// Öffnet die URL mit der App. `false`, wenn die App nicht auffindbar ist.
    @discardableResult
    func open(_ url: URL, with app: AppRef, activates: Bool) -> Bool {
        guard !AirTrafficURL.isAirTrafficURL(url) else {
            Log.opener.error("airtraffic-Link als Ziel verworfen (Schleifenschutz)")
            return false
        }
        guard let appURL = Apps.url(for: app), !Apps.isSelf(appURL) else {
            Log.opener.error("App nicht gefunden: \(app.displayName, privacy: .public) (\(app.path, privacy: .public))")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        Log.opener.info("Öffne \(url.absoluteString, privacy: .private) mit \(appURL.lastPathComponent, privacy: .public)")
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error {
                Log.opener.error("Öffnen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }
}
