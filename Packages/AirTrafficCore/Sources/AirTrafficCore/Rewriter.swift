import Foundation

/// Wendet `Rewrite`s per `NSRegularExpression` an.
public enum Rewriter {
    public struct Output: Sendable, Equatable {
        public var url: URL
        public var warnings: [String]
        /// Hinweise ohne Fehler, z. B. ein erlaubter Schemawechsel (nur Regel-Test, §26.2).
        public var notes: [String] = []
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidPattern(String, message: String)
        case timeout
    }

    /// Wendet die Rewrites nacheinander an. Ungültiger Regex, Zeitlimit, ein Ergebnis, das keine
    /// gültige URL ist, oder ein nicht erlaubtes Schema (§26.2) → Original-URL plus Warnung.
    public static func apply(_ rewrites: [Rewrite], to url: URL, budget: MatchBudget? = nil) -> Output {
        guard !rewrites.isEmpty else { return Output(url: url, warnings: []) }
        let budget = budget ?? MatchBudget()
        var current = url.absoluteString
        for (index, rewrite) in rewrites.enumerated() {
            do {
                current = try apply(rewrite, to: current, budget: budget)
            } catch let Failure.invalidPattern(pattern, message) {
                return Output(url: url, warnings: [
                    "Umschreibung \(index + 1): ungültiger regulärer Ausdruck „\(pattern)“ (\(message)); Original-URL verwendet",
                ])
            } catch Failure.timeout {
                return Output(url: url, warnings: [
                    "Umschreibung \(index + 1): \(TextMatcher.timeoutMessage); Original-URL verwendet",
                ])
            } catch {
                return Output(url: url, warnings: ["Umschreibung \(index + 1): \(error); Original-URL verwendet"])
            }
        }
        guard let result = validURL(current) else {
            return Output(url: url, warnings: [
                "Umschreibung ergibt keine gültige URL („\(current)“); Original-URL verwendet",
            ])
        }
        let original = url.scheme?.lowercased() ?? ""
        let scheme = result.scheme?.lowercased() ?? ""
        guard isAllowedScheme(scheme, original: original, templates: rewrites.map(\.template)) else {
            return Output(url: url, warnings: [
                "Umschreibung ergibt Schema „\(scheme):“ – erlaubt sind http/https, das Schema der Original-URL oder ein Schema, das literal am Anfang der Vorlage steht; Original-URL verwendet",
            ])
        }
        var notes: [String] = []
        if scheme != original {
            notes.append("Schemawechsel „\(original):“ → „\(scheme):“")
        }
        return Output(url: result, warnings: [], notes: notes)
    }

    /// Eine einzelne Umschreibung auf einen String; unverändert, wenn das Muster nicht trifft.
    public static func apply(_ rewrite: Rewrite, to string: String) throws -> String {
        try apply(rewrite, to: string, budget: MatchBudget())
    }

    static func apply(_ rewrite: Rewrite, to string: String, budget: MatchBudget?) throws -> String {
        let regex = try regex(for: rewrite)
        do {
            guard try regex.firstMatch(in: string, budget: budget) != nil else { return string }
            return try regex.replacingMatches(in: string, template: rewrite.template, budget: budget)
        } catch is MatchTimeout {
            throw Failure.timeout
        }
    }

    /// Fehlermeldung für ein ungültiges Muster, sonst `nil` (für die Live-Validierung im Editor).
    public static func validationError(for rewrite: Rewrite) -> String? {
        do {
            _ = try regex(for: rewrite)
            return nil
        } catch let Failure.invalidPattern(_, message) {
            return message
        } catch {
            return "\(error)"
        }
    }

    /// Gültig = strikt parsbar (ohne automatisches Kodieren ungültiger Zeichen) und mit Schema.
    public static func validURL(_ string: String) -> URL? {
        guard let url = URL(string: string, encodingInvalidCharacters: false),
              let scheme = url.scheme, !scheme.isEmpty
        else { return nil }
        return url
    }

    // MARK: Schema (§26.2)

    /// Erlaubt: http/https, das Schema der Original-URL oder ein Schema, das literal am Anfang einer
    /// Vorlage steht (vom Regel-Autor gesetzt, nicht aus der URL übernommen).
    public static func isAllowedScheme(_ scheme: String, original: String, templates: [String]) -> Bool {
        let scheme = scheme.lowercased()
        if scheme == "http" || scheme == "https" || scheme == original.lowercased() { return true }
        return templates.contains { literalScheme(of: $0) == scheme }
    }

    /// Literaler Anfang der Vorlage bis zum ersten `$` (Gruppe) bzw. `\` (Maskierung).
    public static func literalPrefix(of template: String) -> String {
        String(template.prefix { $0 != "$" && $0 != "\\" })
    }

    /// Schema, das literal am Anfang der Vorlage steht, z. B. `linear` für `linear://…`; sonst nil.
    public static func literalScheme(of template: String) -> String? {
        let literal = literalPrefix(of: template)
        guard let colon = literal.firstIndex(of: ":") else { return nil }
        let scheme = literal[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        return scheme.lowercased()
    }

    static func regex(for rewrite: Rewrite) throws -> NSRegularExpression {
        do {
            return try RegexCache.regex(rewrite.pattern, options: rewrite.caseSensitive ? [] : [.caseInsensitive])
        } catch {
            throw Failure.invalidPattern(rewrite.pattern, message: (error as NSError).localizedDescription)
        }
    }
}
