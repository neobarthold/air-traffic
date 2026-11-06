import Foundation

/// Ergebnis von `RuleEngine.test` für eine einzelne Regel (§14.3).
public struct RuleTestResult: Sendable, Equatable {
    /// Bedingungen passen (unabhängig von `enabled`).
    public var matches: Bool
    /// Ergebnis je Bedingungszeile, gleiche Reihenfolge wie `rule.conditions`.
    public var conditionResults: [Bool]
    /// Zwischenergebnis nach jeder Umschreibung, gleiche Reihenfolge wie `rule.rewrites`.
    public var rewriteSteps: [String]
    /// URL nach allen Umschreibungen (ungültig → Original-URL, mit Warnung).
    public var finalURL: URL
    /// Ungültige Regex in Bedingungen/Umschreibungen, ungültige Ergebnis-URL.
    public var warnings: [String]
    /// Erste frühere aktivierte Regel, die für diese URL trifft; nil, wenn keine
    /// oder die Regel selbst nicht in der Config ist.
    public var shadowedBy: UUID?

    public init(
        matches: Bool,
        conditionResults: [Bool],
        rewriteSteps: [String],
        finalURL: URL,
        warnings: [String],
        shadowedBy: UUID?
    ) {
        self.matches = matches
        self.conditionResults = conditionResults
        self.rewriteSteps = rewriteSteps
        self.finalURL = finalURL
        self.warnings = warnings
        self.shadowedBy = shadowedBy
    }
}

/// Reine, testbare Entscheidungslogik: erste aktivierte, passende Regel → Rewrites → Aktion.
///
/// Laufzeit-Schutz (§26.3): URLs über `MatchLimits.maxURLLength` werden nicht geprüft; reguläre
/// Ausdrücke teilen sich je Link ein Zeitbudget. Wartende Änderungen von außen (§26.1) gelten nicht:
/// ausgewertet wird `Rule.effective`.
public enum RuleEngine {
    public static func decide(url: URL, context: LinkContext, config: Config) -> Decision {
        if MatchLimits.isTooLong(url) {
            return Decision(
                originalURL: url, finalURL: url, matchedRuleID: nil,
                action: .prompt(.all), warnings: [MatchLimits.tooLongWarning]
            )
        }
        let budget = MatchBudget()
        var warnings: [String] = []

        for stored in config.rules {
            guard let rule = stored.effective, rule.enabled else { continue }
            var ruleWarnings: [String] = []
            guard matches(rule: rule, url: url, context: context, warnings: &ruleWarnings, budget: budget) else {
                warnings += ruleWarnings
                continue
            }
            warnings += ruleWarnings
            let rewritten = Rewriter.apply(rule.rewrites, to: url, budget: budget)
            warnings += rewritten.warnings.map { "Regel „\(rule.name)“: \($0)" }
            return Decision(
                originalURL: url,
                finalURL: rewritten.url,
                matchedRuleID: rule.id,
                action: rule.action,
                warnings: warnings
            )
        }

        return Decision(
            originalURL: url,
            finalURL: url,
            matchedRuleID: nil,
            action: config.defaultAction,
            warnings: warnings
        )
    }

    /// Testet eine einzelne Regel für den Abschnitt „Test“ im Regel-Editor (§14.3).
    /// Wertet `rule` unabhängig von `enabled` und einer wartenden Freigabe aus (Vorschau des Stands
    /// im Editor). `rewriteSteps` und `finalURL` zeigen, was die Umschreibungen ergeben – unabhängig
    /// davon, ob die Bedingungen passen.
    public static func test(rule: Rule, url: URL, context: LinkContext, config: Config) -> RuleTestResult {
        let budget = MatchBudget()
        var warnings: [String] = []

        let conditionResults = rule.conditions.enumerated().map { index, condition in
            var message: String?
            let result = evaluate(condition, url: url, context: context, error: &message, budget: budget)
            if let message { warnings.append("Bedingung \(index + 1): \(message)") }
            return result
        }
        let matches = combine(conditionResults, mode: rule.match)

        // Zwischenergebnisse je Umschreibung (ungültiges Muster → Text bleibt unverändert).
        var rewriteSteps: [String] = []
        var current = url.absoluteString
        for rewrite in rule.rewrites {
            if let next = try? Rewriter.apply(rewrite, to: current, budget: budget) { current = next }
            rewriteSteps.append(current)
        }
        let rewritten = Rewriter.apply(rule.rewrites, to: url, budget: budget)
        warnings += rewritten.warnings
        warnings += rewritten.notes

        // Erste frühere aktivierte Regel, die trifft (wie `decide` mit voller Config).
        var shadowedBy: UUID?
        if let ownIndex = config.rules.firstIndex(where: { $0.id == rule.id }) {
            shadowedBy = config.rules[..<ownIndex].first { stored in
                guard let earlier = stored.effective, earlier.enabled else { return false }
                var ignored: [String] = []
                return Self.matches(rule: earlier, url: url, context: context, warnings: &ignored, budget: budget)
            }?.id
        }

        return RuleTestResult(
            matches: matches,
            conditionResults: conditionResults,
            rewriteSteps: rewriteSteps,
            finalURL: rewritten.url,
            warnings: warnings,
            shadowedBy: shadowedBy
        )
    }

    /// Prüft, ob die Bedingungen einer Regel passen (ignoriert `enabled`).
    public static func matches(rule: Rule, url: URL, context: LinkContext) -> Bool {
        var ignored: [String] = []
        return matches(rule: rule, url: url, context: context, warnings: &ignored, budget: MatchBudget())
    }

    /// Zeitlimit überschritten → Regel gilt als „trifft nicht“ (§26.3).
    static func matches(
        rule: Rule, url: URL, context: LinkContext, warnings: inout [String], budget: MatchBudget?
    ) -> Bool {
        if rule.conditions.isEmpty { return true }
        var results: [Bool] = []
        for condition in rule.conditions {
            var message: String?
            results.append(evaluate(condition, url: url, context: context, error: &message, budget: budget))
            if let message {
                warnings.append("Regel „\(rule.name)“: \(message)")
                if message == TextMatcher.timeoutMessage { return false }
            }
        }
        return combine(results, mode: rule.match)
    }

    /// Verknüpft Bedingungsergebnisse nach Match-Modus; leer = passt immer.
    static func combine(_ results: [Bool], mode: MatchMode) -> Bool {
        if results.isEmpty { return true }
        switch mode {
        case .all: return results.allSatisfy { $0 }
        case .any: return results.contains(true)
        case .none: return !results.contains(true)
        }
    }

    public static func evaluate(_ condition: Condition, url: URL, context: LinkContext) -> Bool {
        var ignored: String?
        return evaluate(condition, url: url, context: context, error: &ignored, budget: MatchBudget())
    }

    static func evaluate(
        _ condition: Condition, url: URL, context: LinkContext, error: inout String?, budget: MatchBudget?
    ) -> Bool {
        switch condition {
        case .url(let m):
            return TextMatcher.matches(m, url.absoluteString, problem: &error, budget: budget)
        case .host(let m):
            return TextMatcher.matches(m, url.host(percentEncoded: false) ?? "", problem: &error, budget: budget)
        case .path(let m):
            return TextMatcher.matches(m, url.path(percentEncoded: false), problem: &error, budget: budget)
        case .sourceApp(let bundleIdentifier, let negated):
            let isSource = context.sourceBundleIdentifier.map {
                $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            } ?? false
            return isSource != negated
        case .modifiers(let set, let negated):
            return (context.modifiers == set) != negated
        case .linkType(let type):
            return (url.isFileURL ? LinkType.file : .web) == type
        }
    }
}

/// Textvergleiche für `TextMatch`.
public enum TextMatcher {
    static let timeoutMessage = "Zeitlimit überschritten"

    public static func matches(_ m: TextMatch, _ subject: String) -> Bool {
        var ignored: String?
        return matches(m, subject, problem: &ignored, budget: MatchBudget())
    }

    static func matches(_ m: TextMatch, _ subject: String, problem: inout String?, budget: MatchBudget?) -> Bool {
        let options: String.CompareOptions = m.caseSensitive ? [] : [.caseInsensitive]
        switch m.op {
        case .equals:
            return equal(subject, m.value, caseSensitive: m.caseSensitive)
        case .notEquals:
            return !equal(subject, m.value, caseSensitive: m.caseSensitive)
        case .contains:
            return contains(subject, m.value, options: options)
        case .notContains:
            return !contains(subject, m.value, options: options)
        case .beginsWith:
            return m.value.isEmpty || subject.range(of: m.value, options: options.union(.anchored)) != nil
        case .endsWith:
            return m.value.isEmpty
                || subject.range(of: m.value, options: options.union([.anchored, .backwards])) != nil
        case .wildcard:
            // Ohne Regex: linear, ohne Backtracking-Explosion (§26.3).
            return WildcardPattern(m.value, caseSensitive: m.caseSensitive).matches(subject)
        case .regex:
            let regex: NSRegularExpression
            do {
                regex = try RegexCache.regex(m.value, options: m.caseSensitive ? [] : [.caseInsensitive])
            } catch {
                problem = "ungültiger regulärer Ausdruck „\(m.value)“"
                return false
            }
            do {
                return try regex.firstMatch(in: subject, budget: budget) != nil
            } catch {
                problem = timeoutMessage
                return false
            }
        }
    }

    private static func equal(_ a: String, _ b: String, caseSensitive: Bool) -> Bool {
        caseSensitive ? a == b : a.compare(b, options: .caseInsensitive) == .orderedSame
    }

    private static func contains(_ subject: String, _ needle: String, options: String.CompareOptions) -> Bool {
        needle.isEmpty || subject.range(of: needle, options: options) != nil
    }

    /// Bisherige Umsetzung von `wildcard` als regulärer Ausdruck (`*` → `.*`, `?` → `.`, ganzer String).
    /// Nur noch Referenz für Äquivalenztests; der Abgleich nutzt `WildcardPattern`.
    public static func wildcardRegex(_ pattern: String, caseSensitive: Bool) throws -> NSRegularExpression {
        var regex = "^"
        var escaping = false
        for ch in pattern {
            if escaping {
                regex += NSRegularExpression.escapedPattern(for: String(ch))
                escaping = false
                continue
            }
            switch ch {
            case "\\": escaping = true
            case "*": regex += ".*"
            case "?": regex += "."
            default: regex += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        if escaping { regex += NSRegularExpression.escapedPattern(for: "\\") }
        regex += "$"
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if !caseSensitive { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: regex, options: options)
    }
}
