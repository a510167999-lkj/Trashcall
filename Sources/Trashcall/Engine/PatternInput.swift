import Foundation

/// Turns a typed prefix into a wildcard pattern so users don't have to type asterisks.
/// Complete numbers stay exact. Prefixes are padded up to their typical full length
/// (e.g. 9521 → 9521****, 192804 → 192804*****).
///
/// Padding only happens when the gap to the typical length is ≤ `maxAutoWildcardDigits`.
/// A bigger gap (e.g. "95", "13") is left unpadded so the expander rejects it with a
/// clear "too broad" error — previously such prefixes were silently padded to a
/// WRONG length (e.g. "95" → 95****, a 6-digit range that matches no real number).
public enum PatternInput: Sendable {
    public static let maxAutoWildcardDigits = 5

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
        // Pad only when the gap is small; a large gap means the prefix is too broad
        // to guess and must be rejected explicitly instead of producing a misaligned range.
        guard missing >= 1, missing <= maxAutoWildcardDigits else { return trimmed }
        return digits + String(repeating: "*", count: missing)
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
        return digits.count + 4
    }
}
