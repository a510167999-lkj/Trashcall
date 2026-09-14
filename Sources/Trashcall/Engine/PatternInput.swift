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

    /// 4-digit area codes in China that use 8-digit local subscriber numbers (total 12 digits with leading 0).
    /// All other 4-digit area codes in China use 7-digit local subscriber numbers (total 11 digits with leading 0).
    /// Note: 3-digit area codes (010, 02x) all use 8-digit local subscriber numbers (total 11 digits with leading 0).
    public static let eightDigitFourDigitAreaCodes: Set<String> = [
        // 广东省 (Guangdong)
        "0755", "0769", "0757", "0752", "0760", "0750", "0754", "0759",
        // 浙江省 (Zhejiang)
        "0571", "0574", "0577", "0573", "0579", "0576", "0575",
        // 江苏省 (Jiangsu)
        "0512", "0510", "0519", "0513", "0514", "0511", "0516", "0515", "0517", "0518", "0523", "0527",
        // 山东省 (Shandong)
        "0531", "0532", "0535", "0536", "0533", "0537", "0539",
        // 河北省 (Hebei)
        "0311", "0315", "0312",
        // 河南省 (Henan)
        "0371", "0379",
        // 福建省 (Fujian)
        "0591", "0592", "0595",
        // 湖南省 (Hunan)
        "0731",
        // 江西省 (Jiangxi)
        "0791",
        // 安徽省 (Anhui - 仅合肥为 8 位，蚌埠 0552、芜湖 0553 等为 7 位)
        "0551",
        // 辽宁省 (Liaoning)
        "0411",
        // 黑龙江省 (Heilongjiang)
        "0451",
        // 吉林省 (Jilin)
        "0431",
        // 山西省 (Shanxi)
        "0351",
        // 云南省 (Yunnan)
        "0871",
        // 贵州省 (Guizhou)
        "0851",
        // 广西壮族自治区 (Guangxi)
        "0771",
        // 海南省 (Hainan)
        "0898",
        // 内蒙古自治区 (Inner Mongolia)
        "0471",
        // 新疆维吾尔自治区 (Xinjiang)
        "0991"
    ]

    public static func resolved(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        if trimmed.contains(where: { $0 == "*" || $0 == "?" }) {
            return sanitizeExcessWildcards(trimmed)
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

    /// Automatically corrects patterns where users mistakenly add extra trailing asterisks
    /// beyond the standard number length (e.g. "0552607*****" -> "0552607****").
    static func sanitizeExcessWildcards(_ pattern: String) -> String {
        let digits = pattern.filter { $0.isNumber && $0.isASCII }
        guard !digits.isEmpty else { return pattern }
        let target = typicalLength(digits)
        let cleaned = pattern.filter { ($0.isNumber && $0.isASCII) || $0 == "*" || $0 == "?" }
        guard cleaned.count > target else { return pattern }

        let excessCount = cleaned.count - target
        let suffix = cleaned.suffix(excessCount)
        if suffix.allSatisfy({ $0 == "*" || $0 == "?" }) {
            return String(cleaned.prefix(target))
        }
        return pattern
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
            if digits.count >= 4 {
                let areaCode = String(digits.prefix(4))
                if eightDigitFourDigitAreaCodes.contains(areaCode) {
                    return 12 // 4 area code digits + 8 local digits = 12 digits
                } else {
                    return 11 // 4 area code digits + 7 local digits = 11 digits
                }
            }
            return 12
        }
        return digits.count + 4
    }
}
