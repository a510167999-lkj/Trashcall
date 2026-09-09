import Foundation

/// Turns a typed prefix into a wildcard pattern so users don't have to type asterisks.
/// Complete numbers stay exact. Prefixes are padded with at most 4 `*` (10_000 numbers).
public enum PatternInput: Sendable {
    public static let maxAutoWildcardDigits = 4

    public static func resolved(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        if trimmed.contains(where: { $0 == "*" || $0 == "?" }) {
            return trimmed
        }
        let digits = trimmed.filter { $0.isNumber && $0.isASCII }
        guard !digits.isEmpty else { return trimmed }
        if isCompleteNumber(digits) {
            return trimmed
        }
        let target = typicalLength(digits)
        let missing = max(0, target - digits.count)
        let stars = min(missing, maxAutoWildcardDigits)
        guard stars > 0 else { return trimmed }
        return digits + String(repeating: "*", count: stars)
    }

    public static func isCompleteNumber(_ digits: String) -> Bool {
        if digits.hasPrefix("86") && digits.count > 2 {
            return isCompleteNational(String(digits.dropFirst(2)))
        }
        return isCompleteNational(digits)
    }

    static func typicalLength(_ digits: String) -> Int {
        if digits.hasPrefix("86") && digits.count > 2 {
            return 2 + typicalNationalLength(String(digits.dropFirst(2)))
        }
        return typicalNationalLength(digits)
    }

    private static func isCompleteNational(_ digits: String) -> Bool {
        if digits.hasPrefix("1") { return digits.count == 11 }
        if digits.hasPrefix("400") || digits.hasPrefix("800") { return digits.count == 10 }
        if digits.hasPrefix("95") { return digits.count == 8 }
        if digits.hasPrefix("0") { return digits.count == typicalNationalLength(digits) }
        return digits.count >= 11
    }

    private static func typicalNationalLength(_ digits: String) -> Int {
        if digits.hasPrefix("1") { return 11 }
        if digits.hasPrefix("400") || digits.hasPrefix("800") { return 10 }
        if digits.hasPrefix("95") { return 8 }
        if digits.hasPrefix("0") {
            if digits.hasPrefix("010") || digits.hasPrefix("02") { return 11 }
            return 12
        }
        return digits.count + maxAutoWildcardDigits
    }
}
