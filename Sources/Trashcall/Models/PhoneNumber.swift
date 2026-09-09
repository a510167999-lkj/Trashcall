import Foundation

/// Represents a normalized E.164 phone number as an `Int64`.
/// In CallKit, phone numbers are represented as `CXCallDirectoryPhoneNumber`, which is an alias for `int64_t`.
/// All numbers passed to CXCallDirectoryExtensionContext must be positive 64-bit integers without leading '+' or prefixes.
public struct PhoneNumber: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public var description: String {
        return "+\(rawValue)"
    }

    public static func < (lhs: PhoneNumber, rhs: PhoneNumber) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    /// Normalizes an input phone number string into E.164 Int64 representation.
    /// - Parameters:
    ///   - input: The raw phone number string (e.g. "+86 138-0000-0000", "010-12345678", "95210000").
    ///   - defaultCountryCode: The default country calling code (e.g., 86 for China), applied if no international prefix is found.
    /// - Returns: A normalized `PhoneNumber` instance, or `nil` if invalid.
    public static func normalize(_ input: String, defaultCountryCode: Int = 86) -> PhoneNumber? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Determine whether user explicitly provided international format (+ or 00)
        var hasInternationalPrefix = false
        var cleanedDigits = ""

        if trimmed.hasPrefix("+") {
            hasInternationalPrefix = true
        } else if trimmed.hasPrefix("00") && trimmed.count > 2 {
            hasInternationalPrefix = true
        }

        // Filter for ASCII digits only
        for char in trimmed {
            if char.isNumber && char.isASCII {
                cleanedDigits.append(char)
            }
        }

        guard !cleanedDigits.isEmpty else { return nil }

        // Handle double leading zeros (e.g. 0086 -> 86)
        if trimmed.hasPrefix("00") && cleanedDigits.hasPrefix("00") {
            cleanedDigits.removeFirst(2)
        }

        var finalDigits = cleanedDigits

        if !hasInternationalPrefix {
            // If it starts with domestic trunk prefix '0' (e.g., Chinese landline 010, 021, 0755), strip the leading 0
            if finalDigits.hasPrefix("0") && finalDigits.count > 3 {
                finalDigits.removeFirst()
            }
            finalDigits = "\(defaultCountryCode)\(finalDigits)"
        }

        // Validate final digit length: E.164 allows max 15 digits, min ~7 digits
        guard finalDigits.count >= 7 && finalDigits.count <= 15 else {
            return nil
        }

        guard let intValue = Int64(finalDigits), intValue > 0 else {
            return nil
        }

        return PhoneNumber(rawValue: intValue)
    }

    /// CallKit matches the digit string the carrier presents, not a conceptual E.164 value.
    /// Chinese mobiles are often presented without the `86` prefix, so an exact number is
    /// registered as both E.164 (`8618964046784`) and the national form (`18964046784`).
    public static func callKitEntries(_ input: String, defaultCountryCode: Int = 86) -> [PhoneNumber] {
        guard let e164 = normalize(input, defaultCountryCode: defaultCountryCode) else { return [] }
        var values: [Int64] = [e164.rawValue]
        let cc = String(defaultCountryCode)
        let digits = String(e164.rawValue)
        if digits.hasPrefix(cc) && digits.count > cc.count + 6 {
            let national = String(digits.dropFirst(cc.count))
            if let n = Int64(national), n > 0, String(n).count >= 7 {
                values.append(n)
            }
        }
        return SortedSequenceValidator.sanitizeAndSort(values).map { PhoneNumber(rawValue: $0) }
    }
}
