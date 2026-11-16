import Foundation

/// Removes secrets from text before it is logged, shown, or copied.
/// It knows the exact values resolved for a run and the common token shapes.
/// It cannot promise that arbitrary program output holds nothing sensitive.
public struct Redactor: Sendable {
    public static let mask = "••••••"
    public var knownValues: [String]

    public init(knownValues: [String] = []) {
        // Longest first, so a value that contains another is replaced whole.
        self.knownValues = knownValues.filter { $0.count >= 4 }.sorted { $0.count > $1.count }
    }

    public static let tokenPatterns: [String] = [
        #"gh[pousr]_[A-Za-z0-9]{20,}"#,
        #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}"#,
        #"whsec_[A-Za-z0-9]{10,}"#,
        #"xox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{6,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        #"(?i)(?<=bearer )[A-Za-z0-9._~+/=-]{12,}"#,
        #"(?i)(?<=://)[^/\s:@]+:[^/\s@]+(?=@)"#,
        #"(?i)(?<=(?:password|passwd|secret|token|api[_-]?key)[=:] ?)[^\s&"']{6,}"#,
    ]

    private static let compiled: [NSRegularExpression] = tokenPatterns.compactMap { try? NSRegularExpression(pattern: $0) }

    public func redact(_ text: String) -> String {
        var out = text
        for value in knownValues { out = out.replacingOccurrences(of: value, with: Self.mask) }
        for regex in Self.compiled {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: Self.mask)
        }
        return out
    }

    public static func looksLikeSecret(_ text: String) -> Bool {
        compiled.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
    }
}

public enum Masking {
    /// "j***@e***.com". Never the full address.
    public static func email(_ text: String) -> String {
        let parts = text.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, let first = parts[0].first else { return generic(text) }
        let domain = parts[1].split(separator: ".")
        let host = domain.first?.first.map { "\($0)***" } ?? "***"
        let tld = domain.count > 1 ? "." + (domain.last.map(String.init) ?? "") : ""
        return "\(first)***@\(host)\(tld)"
    }

    public static func generic(_ text: String) -> String {
        guard let first = text.first else { return "" }
        return "\(first)" + String(repeating: "•", count: min(8, max(3, text.count - 1)))
    }
}
