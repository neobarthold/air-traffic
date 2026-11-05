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
            let decision = RuleEngine.decide(url: url, context: context, config: model.config)
            for warning in decision.warnings {
                Log.intake.warning("\(warning, privacy: .public)")
            }
            opener.execute(decision, context: context)
        }
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
