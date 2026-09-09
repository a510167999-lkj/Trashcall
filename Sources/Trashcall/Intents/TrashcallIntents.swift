import Foundation

#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
public struct AddBlockNumberIntent: AppIntent {
    public static let title: LocalizedStringResource = "添加号码到 Trashcall 黑名单"
    public static let description = IntentDescription("将指定的电话号码或号段添加到 Trashcall 自动挂断黑名单，并重载系统拦截。")

    @Parameter(title: "电话号码或号段", description: "例如 18964046784、9521 或 0213100")
    public var phoneNumber: String

    public init() {
        self.phoneNumber = ""
    }

    public init(phoneNumber: String) {
        self.phoneNumber = phoneNumber
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result(dialog: "请输入有效的电话号码")
        }

        let store = CallDirectoryStore(databaseURL: DatabaseBootstrap.databaseURL())
        try store.open(readOnly: false)
        try store.initializeSchema()

        let expander = RuleExpander()
        let resolved = PatternInput.resolved(trimmed)
        let numbers = try expander.expandWildcard(resolved).map(\.rawValue)
        guard !numbers.isEmpty else {
            return .result(dialog: "未能解析到有效号码")
        }

        let rule = ActiveRuleItem(
            pattern: resolved,
            action: .block,
            count: numbers.count
        )
        try store.addUserRule(rule, numbers: numbers)

        // 挂断条目由专用挂断扩展注入：两个扩展都需要重载
        for identifier in TrashcallExtensionID.all {
            let manager = CallDirectoryManagerService(extensionBundleIdentifier: identifier)
            try? await manager.reloadExtension()
        }

        return .result(dialog: "已成功将 \(resolved)（\(numbers.count) 个号码）添加至 Trashcall 自动挂断黑名单！")
    }
}

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
public struct DiagnoseNumberIntent: AppIntent {
    public static let title: LocalizedStringResource = "查询号码防骚扰状态"
    public static let description = IntentDescription("在 Trashcall 本地离线库中沙盒诊断号码的拦截或打标状态。")

    @Parameter(title: "电话号码", description: "需要查询的电话号码")
    public var phoneNumber: String

    public init() {
        self.phoneNumber = ""
    }

    public init(phoneNumber: String) {
        self.phoneNumber = phoneNumber
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = CallDirectoryStore(databaseURL: DatabaseBootstrap.databaseURL())
        try store.open(readOnly: true)
        let result = store.diagnose(input: phoneNumber)
        return .result(dialog: "\(result.title)：\(result.message)")
    }
}

@available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *)
public struct TrashcallShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddBlockNumberIntent(),
            phrases: [
                "在 \(.applicationName) 中添加黑名单",
                "用 \(.applicationName) 拦截电话"
            ],
            shortTitle: "添加黑名单",
            systemImageName: "nosign"
        )
        AppShortcut(
            intent: DiagnoseNumberIntent(),
            phrases: [
                "用 \(.applicationName) 查号码",
                "在 \(.applicationName) 识别号码"
            ],
            shortTitle: "查询防骚扰状态",
            systemImageName: "magnifyingglass"
        )
    }
}
#endif
