import Foundation

/// Wendet `Rewrite`s per `NSRegularExpression` an.
public enum Rewriter {
    public struct Output: Sendable, Equatable {
        public var url: URL
        public var warnings: [String]
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidPattern(String, message: String)
    }

    /// Wendet die Rewrites nacheinander an. Ungültiger Regex oder ein Ergebnis, das keine
    /// gültige URL ist → Original-URL plus Warnung.
    public static func apply(_ rewrites: [Rewrite], to url: URL) -> Output {
        guard !rewrites.isEmpty else { return Output(url: url, warnings: []) }
        var current = url.absoluteString
        for (index, rewrite) in rewrites.enumerated() {
            do {
                current = try apply(rewrite, to: current)
            } catch let Failure.invalidPattern(pattern, message) {
                return Output(url: url, warnings: [
                    "Umschreibung \(index + 1): ungültiger regulärer Ausdruck „\(pattern)“ (\(message)); Original-URL verwendet",
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
        return Output(url: result, warnings: [])
    }

    /// Eine einzelne Umschreibung auf einen String; unverändert, wenn das Muster nicht trifft.
    public static func apply(_ rewrite: Rewrite, to string: String) throws -> String {
        let regex = try regex(for: rewrite)
        let range = NSRange(string.startIndex..., in: string)
        guard regex.firstMatch(in: string, range: range) != nil else { return string }
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: rewrite.template)
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

    static func regex(for rewrite: Rewrite) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(
                pattern: rewrite.pattern,
                options: rewrite.caseSensitive ? [] : [.caseInsensitive]
            )
        } catch {
            throw Failure.invalidPattern(rewrite.pattern, message: (error as NSError).localizedDescription)
        }
    }
}
