import Foundation
import Synchronization

// MARK: - Laufzeit-Schutz beim Regel-Abgleich (SPEC §26.3)

/// Grenzen, damit ein einzelner Link die App nicht blockiert.
public enum MatchLimits {
    /// Längere URLs werden nicht gegen Regeln geprüft (Auswahlfenster mit Hinweis).
    public static let maxURLLength = 8192
    /// Gesamtbudget für alle regulären Ausdrücke eines Links.
    public static let regexBudget: Duration = .milliseconds(500)

    public static let tooLongWarning = "Link zu lang für Regeln"

    /// URL ist zu lang für den Regel-Abgleich.
    public static func isTooLong(_ url: URL) -> Bool {
        url.absoluteString.utf16.count > maxURLLength
    }
}

/// Zeitbudget für Regex-Abgleiche eines Links. Nicht thread-sicher: gilt für einen einzelnen,
/// synchronen Durchlauf (`decide`, `test`, `check`).
public final class MatchBudget {
    private let clock = ContinuousClock()
    private let deadline: ContinuousClock.Instant
    /// Mindestens ein Abgleich wurde wegen der Frist abgebrochen.
    public private(set) var exhausted = false

    public init(_ duration: Duration = MatchLimits.regexBudget) {
        deadline = clock.now.advanced(by: duration)
    }

    var isExpired: Bool { clock.now >= deadline }

    func markExhausted() { exhausted = true }
}

/// Abbruch eines Regex-Abgleichs nach Ablauf des Budgets.
struct MatchTimeout: Error {}

/// Kompilierte reguläre Ausdrücke, gecacht nach Muster und Optionen.
enum RegexCache {
    private struct Key: Hashable {
        var pattern: String
        var options: UInt
    }

    private static let limit = 256
    private static let storage = Mutex<[Key: NSRegularExpression]>([:])

    static func regex(_ pattern: String, options: NSRegularExpression.Options) throws -> NSRegularExpression {
        let key = Key(pattern: pattern, options: options.rawValue)
        if let cached = storage.withLock({ $0[key] }) { return cached }
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        storage.withLock { cache in
            if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
            cache[key] = regex
        }
        return regex
    }
}

extension NSRegularExpression {
    /// Erster Treffer mit Frist: `.reportProgress` ruft den Block auch während langer Abgleiche auf,
    /// so lässt sich katastrophales Backtracking abbrechen. Wirft `MatchTimeout` nach Fristablauf.
    func firstMatch(in string: String, budget: MatchBudget?) throws -> NSTextCheckingResult? {
        let range = NSRange(string.startIndex..., in: string)
        guard let budget else { return firstMatch(in: string, range: range) }
        if budget.isExpired { budget.markExhausted(); throw MatchTimeout() }
        var found: NSTextCheckingResult?
        var timedOut = false
        enumerateMatches(in: string, options: [.reportProgress], range: range) { result, _, stop in
            if let result {
                found = result
                stop.pointee = true
            } else if budget.isExpired {
                timedOut = true
                stop.pointee = true
            }
        }
        if timedOut, found == nil {
            budget.markExhausted()
            throw MatchTimeout()
        }
        return found
    }

    /// Wie `stringByReplacingMatches(in:range:withTemplate:)`, aber mit Frist.
    func replacingMatches(in string: String, template: String, budget: MatchBudget?) throws -> String {
        let range = NSRange(string.startIndex..., in: string)
        guard let budget else { return stringByReplacingMatches(in: string, range: range, withTemplate: template) }
        if budget.isExpired { budget.markExhausted(); throw MatchTimeout() }
        var matches: [NSTextCheckingResult] = []
        var timedOut = false
        enumerateMatches(in: string, options: [.reportProgress], range: range) { result, _, stop in
            if let result {
                matches.append(result)
            }
            if budget.isExpired {
                timedOut = true
                stop.pointee = true
            }
        }
        if timedOut {
            budget.markExhausted()
            throw MatchTimeout()
        }
        let source = string as NSString
        var output = ""
        var cursor = 0
        for match in matches {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += replacementString(for: match, in: string, offset: 0, template: template)
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }
}

// MARK: - Platzhalter ohne Regex

/// `*` und `?` über den ganzen Text, `\` maskiert das nächste Zeichen (wie NSPredicate `LIKE`).
///
/// Linearer Glob-Abgleich ohne Backtracking-Explosion: Bei einem Fehlschlag springt er nur zum
/// letzten `*` zurück (O(n·m) im schlechtesten Fall). Verglichen wird je Unicode-Skalar, wie `.`
/// im bisherigen regulären Ausdruck; ohne Groß/Klein über die Kleinschreibung je Skalar.
public struct WildcardPattern: Sendable {
    enum Token: Sendable, Equatable {
        case literal(Unicode.Scalar)
        case any
        case star
    }

    let tokens: [Token]
    let caseSensitive: Bool

    public init(_ pattern: String, caseSensitive: Bool) {
        var tokens: [Token] = []
        var escaping = false
        for scalar in pattern.unicodeScalars {
            if escaping {
                tokens.append(.literal(scalar))
                escaping = false
                continue
            }
            switch scalar {
            case "\\": escaping = true
            case "*":
                // Mehrere `*` hintereinander sind gleichbedeutend mit einem.
                if tokens.last != .star { tokens.append(.star) }
            case "?": tokens.append(.any)
            default: tokens.append(.literal(scalar))
            }
        }
        if escaping { tokens.append(.literal("\\")) }
        self.tokens = tokens
        self.caseSensitive = caseSensitive
    }

    public func matches(_ subject: String) -> Bool {
        let text = Array(subject.unicodeScalars)
        let folded: [Unicode.Scalar]? = caseSensitive ? nil : text.map(Self.fold)
        let pattern = caseSensitive ? tokens : tokens.map { token in
            if case .literal(let scalar) = token { return .literal(Self.fold(scalar)) }
            return token
        }
        let subject = folded ?? text

        var t = 0, p = 0
        var starP = -1, starT = 0
        while t < subject.count {
            if p < pattern.count {
                switch pattern[p] {
                case .star:
                    starP = p
                    starT = t
                    p += 1
                    continue
                case .any:
                    t += 1; p += 1
                    continue
                case .literal(let scalar) where scalar == subject[t]:
                    t += 1; p += 1
                    continue
                case .literal:
                    break
                }
            }
            guard starP >= 0 else { return false }
            // Zurück zum letzten `*`, das ein Zeichen mehr schluckt.
            p = starP + 1
            starT += 1
            t = starT
        }
        while p < pattern.count, pattern[p] == .star { p += 1 }
        return p == pattern.count
    }

    /// Kleinschreibung je Skalar; Zeichen mit mehrteiliger Kleinschreibung bleiben, wie sie sind.
    static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar.isASCII {
            let value = scalar.value
            return (65...90).contains(value) ? Unicode.Scalar(value + 32)! : scalar
        }
        let lower = scalar.properties.lowercaseMapping.unicodeScalars
        return lower.count == 1 ? lower.first! : scalar
    }
}
