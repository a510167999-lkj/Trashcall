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

    public init(maxAllowedNumbersPerRule: Int64 = 100_000) {
        self.maxAllowedNumbersPerRule = maxAllowedNumbersPerRule
    }

    /// Expands a wildcard string (e.g. "+86 9521****", "0108888****") into an array of normalized PhoneNumber.
    /// Digit-only prefixes such as `9521` are first resolved to `9521****`.
    /// Mobile segment rules expand to BOTH the national form (e.g. 19280400000…19280499999)
    /// and the E.164 form (8619280400000…8619280499999) because Chinese carriers often
    /// present incoming calls without the country code prefix.
    public func expandWildcard(_ pattern: String, defaultCountryCode: Int = 86) throws -> [PhoneNumber] {
        switch try expansionPlan(pattern, defaultCountryCode: defaultCountryCode) {
        case .exact(let entries):
            return entries
        case .closedRanges(let ranges):
            var results: [PhoneNumber] = []
            for range in ranges {
                let count = Int(range.end - range.start + 1)
                results.reserveCapacity(results.count + count)
                for num in range.start...range.end {
                    results.append(PhoneNumber(rawValue: num))
                }
            }
            return results
        }
    }

    /// Count only — used by the add-number preview so typing a prefix does not allocate tens of thousands of numbers.
    public func estimateCount(_ pattern: String, defaultCountryCode: Int = 86) throws -> Int {
        switch try expansionPlan(pattern, defaultCountryCode: defaultCountryCode) {
        case .exact(let entries):
            return entries.count
        case .closedRanges(let ranges):
            return ranges.reduce(0) { $0 + Int($1.end - $1.start + 1) }
        }
    }

    private enum ExpansionPlan {
        case exact([PhoneNumber])
        case closedRanges([(start: Int64, end: Int64)])
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

        var ranges: [(start: Int64, end: Int64)] = [(startNum.rawValue, endNum.rawValue)]

        // Dual-form registration for segment rules: also cover the national (no country
        // code) presentation, mirroring `PhoneNumber.callKitEntries` for exact numbers.
        // Without this, a segment rule only matches when the carrier sends the full
        // E.164 form — Chinese mobiles are frequently presented as 11 national digits.
        let cc = String(defaultCountryCode)
        let startDigits = String(startNum.rawValue)
        let endDigits = String(endNum.rawValue)
        if startDigits.hasPrefix(cc), endDigits.hasPrefix(cc) {
            let nationalStart = String(startDigits.dropFirst(cc.count))
            let nationalEnd = String(endDigits.dropFirst(cc.count))
            if nationalStart.count >= 7, nationalStart.count == nationalEnd.count,
               let ns = Int64(nationalStart), let ne = Int64(nationalEnd), ns > 0, ns <= ne {
                ranges.append((ns, ne))
            }
        }

        for range in ranges {
            let count = range.end - range.start + 1
            guard count <= maxAllowedNumbersPerRule else {
                throw RuleExpansionError.patternTooBroad(
                    estimatedCount: count,
                    maximumAllowed: maxAllowedNumbersPerRule
                )
            }
        }

        return .closedRanges(ranges.sorted { $0.start < $1.start })
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
