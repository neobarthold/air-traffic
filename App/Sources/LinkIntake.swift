import AirTrafficCore
import AppKit

/// Nimmt Links entgegen, erfasst den Kontext und lässt jede URL einzeln entscheiden.
@MainActor
final class LinkIntake {
    private let model: AppModel
    private let opener: Opener

    init(model: AppModel, opener: Opener) {
        self.model = model
        self.opener = opener
    }

    func receive(_ urls: [URL]) {
        let context = Self.captureContext()
        Log.intake.info("\(urls.count) URL(s) von \(context.sourceBundleIdentifier ?? "unbekannt", privacy: .public)")
        for url in urls {
            if AirTrafficURL.isAirTrafficURL(url) {
                receiveAirTrafficURL(url, context: context)
                continue
            }
            let decision = RuleEngine.decide(url: url, context: context, config: model.config)
            execute(decision, context: context)
        }
    }

    /// `airtraffic://open?url=…[&source=…][&prompt=1]` (SPEC §20.1), z. B. aus der Safari-Erweiterung.
    private func receiveAirTrafficURL(_ url: URL, context: LinkContext) {
        let request: AirTrafficURL.Request
        do throws(AirTrafficURL.ParseError) {
            request = try AirTrafficURL.parse(url)
        } catch {
            Log.intake.error("airtraffic-Link ignoriert: \(error.description, privacy: .public)")
            return
        }
        let linkContext = request.context(from: context)
        Log.intake.info(
            "airtraffic-Link, Quelle \(linkContext.sourceBundleIdentifier ?? "unbekannt", privacy: .public), Auswahl: \(request.prompt)"
        )
        let decision = AirTrafficURL.decide(request, context: context, config: model.config)
        execute(decision, context: linkContext)
    }

    private func execute(_ decision: Decision, context: LinkContext) {
        for warning in decision.warnings {
            Log.intake.warning("\(warning, privacy: .public)")
        }
        opener.execute(decision, context: context)
    }

    /// Quell-App (aus dem aktuellen Apple Event), Modifier, laufende Apps.
    static func captureContext() -> LinkContext {
        LinkContext(
            sourceBundleIdentifier: sourceBundleIdentifier(),
            modifiers: ModifierSet(NSEvent.modifierFlags),
            runningBundleIdentifiers: Apps.runningBundleIdentifiers()
        )
    }

    private static func sourceBundleIdentifier() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))
        else { return nil }
        let pid = pid_t(descriptor.int32Value)
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
