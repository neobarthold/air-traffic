import Foundation

// Getrennt von `AirTrafficURL.swift`, weil jene Datei auch in die Safari-Erweiterung kompiliert wird
// und dort weder `RuleEngine` noch `Config` existieren.
extension AirTrafficURL.Request {
    /// Kontext für die Regeln: `source` ersetzt die per Absender-PID ermittelte Quell-App.
    public func context(from base: LinkContext) -> LinkContext {
        var context = base
        if let source { context.sourceBundleIdentifier = source }
        return context
    }
}

extension AirTrafficURL {
    /// Entscheidung für einen `airtraffic://open`-Link (SPEC §20.1): normaler Ablauf (§5);
    /// mit `prompt` werden nur die Umschreibungen der passenden Regel übernommen, danach immer
    /// das Auswahlfenster mit allen Browsern.
    public static func decide(_ request: Request, context: LinkContext, config: Config) -> Decision {
        var decision = RuleEngine.decide(url: request.url, context: request.context(from: context), config: config)
        if request.prompt { decision.action = .prompt(.all) }
        return decision
    }
}
