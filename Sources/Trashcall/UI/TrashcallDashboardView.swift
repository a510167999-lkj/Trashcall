import Foundation

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Identification-only dashboard: labels incoming calls, does not attempt hang-up.
public struct TrashcallDashboardView: View {
    @State private var extensionStatus: ExtensionStatus = .unknown
    @State private var identificationCount: Int = 0
    @State private var seedVersion: String = "—"
    @State private var isSyncing: Bool = false
    @State private var customRulePattern: String = ""
    @State private var identifyLabel: String = "推销骚扰"
    @State private var activeRules: [ActiveRuleItem] = []
    @State private var liveRuleIDs: Set<UUID> = []
    @State private var lastExtensionRun: ExtensionRunReport?
    @State private var appGroupReady: Bool = false
    @State private var errorMessage: String?
    @State private var successNotice: String?

    public let extensionId: String
    private let manager: CallDirectoryManagerService

    public init(extensionId: String = TrashcallExtensionID.identification) {
        self.extensionId = extensionId
        self.manager = CallDirectoryManagerService(extensionBundleIdentifier: extensionId)
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: statusIcon)
                            .foregroundColor(statusColor)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("来电识别")
                                .font(.headline)
                            Text(extensionStatus.rawValue)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("版本 \(installedVersion)")
                                .font(.caption.monospaced())
                        }
                    }
                    .padding(.vertical, 4)

                    HStack {
                        Text("App Group")
                        Spacer()
                        Text(appGroupReady ? "已接通" : "未接通")
                            .foregroundColor(appGroupReady ? .secondary : .red)
                    }
                    .font(.footnote)

                    if let run = lastExtensionRun {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("扩展上次注入识别 \(run.identificationFed) 条")
                            Text(runTimeText(run.at))
                                .foregroundColor(.secondary)
                            if let err = run.error, !err.isEmpty {
                                Text("扩展错误：\(err)")
                                    .foregroundColor(.red)
                            }
                        }
                        .font(.caption)
                    }

                    if !appGroupReady {
                        Text("App Group 未生效：扩展读不到黄页库。请确认 Signing 里的 group.com.trashcall.shared。")
                            .font(.footnote)
                            .foregroundColor(.red)
                    }

                    if extensionStatus != .enabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("请打开 Trashcall 的来电识别开关。")
                                .font(.footnote)
                                .foregroundColor(.orange)
                            Text("路径：设置 → App → 电话 → 通话阻止与身份识别 → Trashcall")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Button {
                                Task { await manager.openCallDirectorySettings() }
                            } label: {
                                Label("打开通话阻止与身份识别", systemImage: "gearshape.fill")
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                        }
                    }
                } header: {
                    Text("系统状态")
                } footer: {
                    Text("当前安装 \(installedVersion)。iOS 27 上第三方无法自动拒接，Trashcall 只负责来电打标。号段直接输入前缀，不用打星号。")
                        .font(.caption2)
                }

                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("号码或号段，如 9521、18964046784", text: $customRulePattern)
                            .textFieldStyle(.roundedBorder)
                            #if canImport(UIKit)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                        if let hint = patternHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack {
                            Text("标签")
                                .foregroundColor(.secondary)
                            TextField("如: 房产中介 / 催收", text: $identifyLabel)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            Task { await addRule() }
                        } label: {
                            Label("添加为来电识别", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customRulePattern.trimmingCharacters(in: .whitespaces).isEmpty || isSyncing)
                    }
                    .padding(.vertical, 4)

                    if let error = errorMessage {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                    if let notice = successNotice {
                        Text(notice).font(.caption).foregroundColor(.green)
                    }
                } header: {
                    Text("添加来电标记")
                } footer: {
                    Text("完整手机号按精确标记。短号段自动补最多 4 位（例如 9521 → 9521****，约 1 万个号码）。")
                        .font(.caption2)
                }

                Section("自定义标记 (\(activeRules.count))") {
                    if activeRules.isEmpty {
                        Text("还没有自定义标记。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(activeRules) { rule in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.pattern)
                                        .font(.headline)
                                        .monospaced()
                                    Text("\(rule.label ?? "自定义标记") · \(rule.count) 个号码")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if liveRuleIDs.contains(rule.id) {
                                        Text("已写入识别库")
                                            .font(.caption2)
                                            .foregroundColor(.green)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .onDelete(perform: deleteRules)
                    }
                }

                Section("黄页库") {
                    HStack {
                        Label("已载入识别号码", systemImage: "tag.fill")
                        Spacer()
                        Text("\(identificationCount) 条")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("种子版本")
                        Spacer()
                        Text(seedVersion)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Button {
                        Task { await triggerSync() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSyncing {
                                ProgressView().padding(.trailing, 8)
                                Text("正在更新识别库...")
                            } else {
                                Label("更新黄页并重载系统", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSyncing)
                }
            }
            .navigationTitle("Trashcall 来电识别")
            .task {
                isSyncing = true
                await Task.detached(priority: .userInitiated) {
                    DatabaseBootstrap.run()
                }.value
                await refreshStatus()
                do {
                    try await manager.reloadExtension()
                    await refreshStatus()
                } catch {
                    if extensionStatus == .enabled {
                        errorMessage = "启动时系统重载失败：\(error.localizedDescription)"
                    }
                }
                isSyncing = false
            }
        }
    }

    private var patternHint: String? {
        let raw = customRulePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let resolved = PatternInput.resolved(raw)
        do {
            let count = try RuleExpander().estimateCount(resolved)
            if resolved.contains("*") || resolved.contains("?") {
                if resolved != raw {
                    return "将按号段 \(resolved) 写入，约 \(count) 个号码"
                }
                return "号段 \(resolved)，约 \(count) 个号码"
            }
            return "精确号码，写入 \(count) 条"
        } catch {
            return error.localizedDescription
        }
    }

    private var installedVersion: String {
        let marketing = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }

    private func runTimeText(_ timestamp: TimeInterval) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
    }

    private var statusIcon: String {
        switch extensionStatus {
        case .enabled: return "checkmark.shield.fill"
        case .disabled: return "exclamationmark.shield.fill"
        case .unknown: return "questionmark.shield"
        }
    }

    private var statusColor: Color {
        switch extensionStatus {
        case .enabled: return .green
        case .disabled: return .orange
        case .unknown: return .gray
        }
    }

    private func getStore(readOnly: Bool = false) -> CallDirectoryStore? {
        let store = CallDirectoryStore(databaseURL: DatabaseBootstrap.databaseURL())
        do {
            try store.open(readOnly: readOnly)
            if !readOnly { try store.initializeSchema() }
            return store
        } catch {
            return nil
        }
    }

    private func refreshStatus() async {
        extensionStatus = await manager.checkStatus()
        appGroupReady = DatabaseBootstrap.isUsingAppGroup
        lastExtensionRun = ExtensionRunReport.load(fileName: ExtensionRunReport.identifyFileName)
            ?? ExtensionRunReport.load()

        if let store = getStore(readOnly: true) {
            identificationCount = store.countIdentification()
            seedVersion = (try? store.getVersion()) ?? "—"
            if let persistedRules = try? store.getUserRules() {
                activeRules = persistedRules
                var live: Set<UUID> = []
                for rule in persistedRules {
                    if rule.pattern.contains("*") || rule.pattern.contains("?") { continue }
                    let entries = PhoneNumber.callKitEntries(rule.pattern)
                    if entries.contains(where: { store.containsIdentification($0.rawValue) }) {
                        live.insert(rule.id)
                    }
                }
                liveRuleIDs = live
            }
        }
    }

    private func triggerSync() async {
        isSyncing = true
        errorMessage = nil
        successNotice = nil
        defer { isSyncing = false }
        await Task.detached(priority: .userInitiated) {
            DatabaseBootstrap.run()
        }.value
        do {
            try await manager.reloadExtension()
            await refreshStatus()
            successNotice = "黄页已按内置种子更新，识别扩展已重载。"
        } catch {
            errorMessage = "重载扩展失败: \(error.localizedDescription)"
            await refreshStatus()
        }
    }

    private func addRule() async {
        errorMessage = nil
        successNotice = nil
        isSyncing = true
        defer { isSyncing = false }

        let expander = RuleExpander()
        let resolved = PatternInput.resolved(customRulePattern)
        do {
            let phoneNumbers = try expander.expandWildcard(resolved).map(\.rawValue)
            guard !phoneNumbers.isEmpty else {
                errorMessage = "没有可写入的号码。"
                return
            }
            guard let store = getStore(readOnly: false) else {
                errorMessage = "无法连接离线数据库"
                return
            }
            let newRule = ActiveRuleItem(
                pattern: resolved,
                action: .identify,
                label: identifyLabel,
                count: phoneNumbers.count
            )
            try store.addUserRule(newRule, numbers: phoneNumbers)
            customRulePattern = ""
            try await manager.reloadExtension()
            await refreshStatus()
            if phoneNumbers.count <= 4 {
                let preview = phoneNumbers.map { "+\($0)" }.joined(separator: " / ")
                successNotice = "已将 \(preview) 写入来电识别。"
            } else {
                successNotice = "已将号段 \(resolved)（\(phoneNumbers.count) 个号码）写入来电识别。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        Task {
            errorMessage = nil
            successNotice = nil
            isSyncing = true
            defer { isSyncing = false }
            guard let store = getStore(readOnly: false) else {
                errorMessage = "无法连接离线数据库"
                return
            }
            let expander = RuleExpander()
            for index in offsets {
                guard index < activeRules.count else { continue }
                let rule = activeRules[index]
                let numbers = (try? expander.expandWildcard(rule.pattern).map(\.rawValue)) ?? []
                do {
                    try store.deleteUserRule(id: rule.id, pattern: rule.pattern, action: rule.action, numbers: numbers)
                } catch {
                    errorMessage = "删除规则失败: \(error.localizedDescription)"
                    return
                }
            }
            do {
                try await manager.reloadExtension()
            } catch {
                errorMessage = "已从本地删除，但系统重载失败：\(error.localizedDescription)"
                await refreshStatus()
                return
            }
            await refreshStatus()
            successNotice = "规则已删除。"
        }
    }
}
#endif
