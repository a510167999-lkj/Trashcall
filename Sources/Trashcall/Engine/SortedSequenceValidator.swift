import Foundation

/// Verifies and ensures that phone numbers emitted to CallKit adhere to Apple's strict requirement:
/// "Each number must be greater than the previous number."
public struct SortedSequenceValidator: Sendable {
    public init() {}

    /// Validates whether a given array of phone numbers is strictly monotonically ascending.
    /// - Parameter numbers: Array of raw phone numbers.
    /// - Returns: True if sorted strictly ascending without duplicates, false otherwise.
    public static func isStrictlyAscending(_ numbers: [Int64]) -> Bool {
        guard numbers.count > 1 else { return true }
        for i in 1..<numbers.count {
            if numbers[i] <= numbers[i - 1] {
                return false
            }
        }
        return true
    }

    /// Sorts and removes duplicate entries, guaranteeing a strictly ascending sequence suitable for CallKit.
    /// - Parameter numbers: Any collection of phone numbers.
    /// - Returns: Deduplicated, strictly sorted Int64 array.
    public static func sanitizeAndSort(_ numbers: [Int64]) -> [Int64] {
        guard !numbers.isEmpty else { return [] }
        let sorted = numbers.sorted()
        var result: [Int64] = []
        result.reserveCapacity(sorted.count)

        var last: Int64? = nil
        for num in sorted {
            if let prev = last {
                if num > prev {
                    result.append(num)
                    last = num
                }
                // If num == prev, skip duplicate. If num < prev (impossible after sort), ignore.
            } else {
                result.append(num)
                last = num
            }
        }
        return result
    }

    /// Sorts and deduplicates identification entries by phone number.
    /// If duplicate phone numbers exist, the latter entry's label takes precedence.
    public static func sanitizeAndSortIdentifications(_ entries: [IdentificationEntry]) -> [IdentificationEntry] {
        guard !entries.isEmpty else { return [] }
        // Sort by phoneNumber
        let sorted = entries.sorted { $0.phoneNumber < $1.phoneNumber }
        var result: [IdentificationEntry] = []
        result.reserveCapacity(sorted.count)

        var lastPhone: Int64? = nil
        for entry in sorted {
            if let prev = lastPhone {
                if entry.phoneNumber == prev {
                    // Update the last entry's label
                    _ = result.popLast()
                    result.append(entry)
                } else if entry.phoneNumber > prev {
                    result.append(entry)
                    lastPhone = entry.phoneNumber
                }
            } else {
                result.append(entry)
                lastPhone = entry.phoneNumber
            }
        }
        return result
    }
}
