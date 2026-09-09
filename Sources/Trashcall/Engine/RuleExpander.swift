import Foundation

/// Errors that can occur during rule expansion.
public enum RuleExpansionError: Error, LocalizedError {
    case patternTooBroad(estimatedCount: Int64, maximumAllowed: Int64)
    case invalidWildcardPattern(String)
    case invalidRange(start: Int64, end: Int64)

    public var errorDescription: String? {
        switch self {
        case .patternTooBroad(let count, let max):
            return "号段规则过于宽泛（预计产生 \(count) 个号码，系统单条规则上限为 \(max)），请缩小通配符范围以防超出 iOS 扩展容量。"
        case .invalidWildcardPattern(let pattern):
            return "无效的通配符号码格式: \(pattern)"
        case .invalidRange(let start, let end):
            return "无效的起始与终止号码区间: [\(start), \(end)]"
        }
    }
}

/// Expands high-level user patterns (such as wildcards `9521****` or ranges)
/// into concrete discrete E.164 phone numbers for CallKit ingestion.
public struct RuleExpander: Sendable {
    public let maxAllowedNumbersPerRule: Int64

    public init(maxAllowedNumbersPerRule: Int64 = 50_000) {
        self.maxAllowedNumbersPerRule = maxAllowedNumbersPerRule
    }

    /// Expands a wildcard string (e.g. "+86 9521****", "0108888****") into an array of normalized PhoneNumber.
    /// Digit-only prefixes such as `9521` are first resolved to `9521****`.
    public func expandWildcard(_ pattern: String, defaultCountryCode: Int = 86) throws -> [PhoneNumber] {
        switch try expansionPlan(pattern, defaultCountryCode: defaultCountryCode) {
        case .exact(let entries):
            return entries
        case .closedRange(let start, let end):
            var results: [PhoneNumber] = []
            results.reserveCapacity(Int(end - start + 1))
            for num in start...end {
                results.append(PhoneNumber(rawValue: num))
            }
            return results
        }
    }

    /// Count only — used by the add-number preview so typing a prefix does not allocate tens of thousands of numbers.
    public func estimateCount(_ pattern: String, defaultCountryCode: Int = 86) throws -> Int {
        switch try expansionPlan(pattern, defaultCountryCode: defaultCountryCode) {
        case .exact(let entries):
            return entries.count
        case .closedRange(let start, let end):
            return Int(end - start + 1)
        }
    }

    private enum ExpansionPlan {
        case exact([PhoneNumber])
        case closedRange(start: Int64, end: Int64)
    }

    private func expansionPlan(_ pattern: String, defaultCountryCode: Int) throws -> ExpansionPlan {
        let trimmed = PatternInput.resolved(pattern)
        guard !trimmed.isEmpty else {
            throw RuleExpansionError.invalidWildcardPattern(pattern)
        }

        let wildcardCount = trimmed.filter { $0 == "*" || $0 == "?" }.count
        guard wildcardCount > 0 else {
            let entries = PhoneNumber.callKitEntries(trimmed, defaultCountryCode: defaultCountryCode)
            if entries.isEmpty {
                throw RuleExpansionError.invalidWildcardPattern(pattern)
            }
            return .exact(entries)
        }

        var totalVariations: Int64 = 1
        for _ in 0..<wildcardCount {
            totalVariations *= 10
            if totalVariations > maxAllowedNumbersPerRule {
                throw RuleExpansionError.patternTooBroad(
                    estimatedCount: totalVariations,
                    maximumAllowed: maxAllowedNumbersPerRule
                )
            }
        }

        let startPattern = trimmed.replacingOccurrences(of: "*", with: "0").replacingOccurrences(of: "?", with: "0")
        let endPattern = trimmed.replacingOccurrences(of: "*", with: "9").replacingOccurrences(of: "?", with: "9")

        guard let startNum = PhoneNumber.normalize(startPattern, defaultCountryCode: defaultCountryCode),
              let endNum = PhoneNumber.normalize(endPattern, defaultCountryCode: defaultCountryCode) else {
            throw RuleExpansionError.invalidWildcardPattern(pattern)
        }

        guard startNum.rawValue <= endNum.rawValue else {
            throw RuleExpansionError.invalidRange(start: startNum.rawValue, end: endNum.rawValue)
        }

        let count = endNum.rawValue - startNum.rawValue + 1
        guard count <= maxAllowedNumbersPerRule else {
            throw RuleExpansionError.patternTooBroad(
                estimatedCount: count,
                maximumAllowed: maxAllowedNumbersPerRule
            )
        }

        return .closedRange(start: startNum.rawValue, end: endNum.rawValue)
    }

    /// Expands a NumberPattern into discrete numbers.
    public func expand(_ pattern: NumberPattern, defaultCountryCode: Int = 86) throws -> [PhoneNumber] {
        switch pattern {
        case .exact(let number):
            return [number]
        case .range(let start, let end):
            guard start.rawValue <= end.rawValue else {
                throw RuleExpansionError.invalidRange(start: start.rawValue, end: end.rawValue)
            }
            let count = end.rawValue - start.rawValue + 1
            guard count <= maxAllowedNumbersPerRule else {
                throw RuleExpansionError.patternTooBroad(estimatedCount: count, maximumAllowed: maxAllowedNumbersPerRule)
            }
            return (start.rawValue...end.rawValue).map { PhoneNumber(rawValue: $0) }
        case .wildcard(let template):
            return try expandWildcard(template, defaultCountryCode: defaultCountryCode)
        }
    }
}
