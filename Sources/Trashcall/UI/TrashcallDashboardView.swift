import Foundation

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Identification-only dashboard: labels incoming calls, does not attempt hang-up.
public struct TrashcallDashboardView: View {
    @State private var extensionStatus: ExtensionStatus = .unknown
    @State private var blockingCount: Int = 0
    @State private var identificationCount: Int = 0
    @State private var seedVersion: String = "—"
    @State private var isSyncing: Bool = false
    @State private var customRulePattern: String = ""
    @State private var selectedAction: RuleActionType = .block
    @State private var identifyLabel: String = "推销骚扰"
    @State private var activeRules: [ActiveRuleItem] = []
    @State private var liveRuleIDs: Set<UUID> = []
    @State private var lastExtensionRun: ExtensionRunReport?
    @State private var appGroupReady: Bool = false
    @State private var errorMessage: String?
    @State private var successNotice: String?

    // 剪贴板智能感知状态
    @State private var detectedClipboardNumber: String?
    @State private var lastProcessedClipboard: String = ""
    @Environment(\.scenePhase) private var scenePhase

    // 预设高危策略开关状态
    @State private var strategyStates: [ProtectionStrategy: Bool] = [:]

    // 号码沙盒诊断状态
    @State private var diagnosticInput: String = ""
    @State private var diagnosticResult: NumberDiagnosticResult?

    // 折叠高级设置
    @State private var showAdvancedSettings: Bool = false

    public let extensionId: String
    private let manager: CallDirectoryManagerService

    public init(extensionId: String = TrashcallExtensionID.identification) {
        self.extensionId = extensionId
        self.manager = CallDirectoryManagerService(extensionBundleIdentifier: extensionId)
    }

    public var body: some View {
        NavigationStack {
            List {
                // 1. 剪贴板智能感知提示横幅
                if let clipNum = detectedClipboardNumber {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: "doc.on.clipboard.fill")
                                    .foregroundColor(.blue)
                                Text("检测到刚复制的号码")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button {
                                    withAnimation {
                                        lastProcessedClipboard = clipNum
                                        detectedClipboardNumber = nil
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(clipNum)
                                .font(.title3.weight(.bold).monospaced())
                            HStack(spacing: 12) {
                                Button {
                                    Task { await addQuickClipboardRule(clipNum, action: .block) }
                                } label: {
                                    Label("一键自动挂断", systemImage: "nosign")
                                        .font(.footnote.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)

                                Button {
                                    Task { await addQuickClipboardRule(clipNum, action: .identify) }
                                } label: {
                                    Label("一键打标", systemImage: "tag.fill")
                                        .font(.footnote.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // 2. 状态看板 Hero Card
                Section {
                    VStack(spacing: 12) {
                        HStack(spacing: 16) {
                            Image(systemName: statusIcon)
                                .font(.system(size: 44))
                                .foregroundColor(statusColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(extensionStatus == .enabled ? "系统全能防护中" : "未开启系统授权")
                                    .font(.headline.weight(.bold))
                                Text(extensionStatus == .enabled ? "已成功接入 iOS CallKit 系统底层" : "请在系统设置中启用 Trashcall")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("全库已布防")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(blockingCount + identificationCount)")
                                    .font(.title3.weight(.bold).monospaced())
                            }
                            Spacer()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("🚫 自动挂断")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                Text("\(blockingCount)")
                                    .font(.title3.weight(.bold).monospaced())
                                    .foregroundColor(.red)
                            }
                            Spacer()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("🏷️ 来电打标")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                                Text("\(identificationCount)")
                                    .font(.title3.weight(.bold).monospaced())
                                    .foregroundColor(.blue)
                            }
                        }

                        Divider()

                        HStack(spacing: 6) {
                            if blockingCount == 0 {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)
                                Text("当前状态：全部【来电识别打标】（会响铃并显示标记）。若需零响铃静默挂断，可在下方开启策略开关。")
                            } else if identificationCount <= 300 {
                                Image(systemName: "shield.fill")
                                    .foregroundColor(.green)
                                Text("当前状态：高危号段已【全量自动挂断】（呼入静默掐断不响铃）。仅保留官方政企客服打标。")
                            } else {
                                Image(systemName: "bolt.shield.fill")
                                    .foregroundColor(.orange)
                                Text("当前状态：混合防御（\(blockingCount) 条静默挂断，\(identificationCount) 条来电打标）。")
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if extensionStatus != .enabled {
                            Button {
                                Task { await manager.openCallDirectorySettings() }
                            } label: {
                                Label("前往开启「通话阻止与身份识别」", systemImage: "gearshape.fill")
                                    .font(.footnote.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // 3. 一键预设防御策略
                Section {
                    ForEach(ProtectionStrategy.allCases) { strategy in
                        let isBlocked = strategyStates[strategy] ?? false
                        Toggle(isOn: Binding(
                            get: { isBlocked },
                            set: { newVal in
                                Task { await toggleStrategy(strategy, enabled: newVal) }
                            }
                        )) {
                            HStack(spacing: 12) {
                                Image(systemName: strategy.icon)
                                    .foregroundColor(isBlocked ? .red : .orange)
                                    .font(.title3)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(strategy.title)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(isBlocked ? "🚫 自动挂断" : "🏷️ 来电打标")
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(isBlocked ? Color.red.opacity(0.12) : Color.blue.opacity(0.12))
                                            .foregroundColor(isBlocked ? .red : .blue)
                                            .cornerRadius(4)
                                    }
                                    Text(strategy.subtitle)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("一键防御策略（高频场景自动挂断）")
                        Spacer()
                        Menu {
                            Button("全部设为自动挂断") {
                                Task { await toggleAllStrategies(enabled: true) }
                            }
                            Button("全部恢复为来电打标") {
                                Task { await toggleAllStrategies(enabled: false) }
                            }
                        } label: {
                            Text("批量切换")
                                .font(.caption2)
                        }
                    }
                } footer: {
                    Text("开启后将从打标库直接划入自动挂断黑名单，享受零响铃静默阻断；关闭后保留来电识别打标。")
                        .font(.caption2)
                }

                // 4. 号码沙盒诊断与模拟查询
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("输入手机号或座机模拟来电诊断...", text: $diagnosticInput)
                                #if canImport(UIKit)
                                .keyboardType(.numbersAndPunctuation)
                                #endif
                                .onChange(of: diagnosticInput) {
                                    runDiagnosis()
                                }
                            if !diagnosticInput.isEmpty {
                                Button {
                                    diagnosticInput = ""
                                    diagnosticResult = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)

                        if let result = diagnosticResult {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(result.title)
                                        .font(.subheadline.weight(.bold))
                                }
                                Text(result.message)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if case .notFound(let num) = result {
                                    HStack(spacing: 10) {
                                        Button("添加自动挂断") {
                                            customRulePattern = num
                                            selectedAction = .block
                                            Task { await addRule() }
                                            diagnosticInput = ""
                                            diagnosticResult = nil
                                        }
                                        .font(.caption.weight(.semibold))
                                        .buttonStyle(.borderedProminent)
                                        .tint(.red)

                                        Button("添加来电识别") {
                                            customRulePattern = num
                                            selectedAction = .identify
                                            Task { await addRule() }
                                            diagnosticInput = ""
                                            diagnosticResult = nil
                                        }
                                        .font(.caption.weight(.semibold))
                                        .buttonStyle(.bordered)
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(8)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("号码沙盒诊断与测试")
                } footer: {
                    Text("输入任意号码可立即模拟其在本地离线库中的防御表现，无需真机互拨测试。")
                        .font(.caption2)
                }

                // 5. 手动添加精准规则或号段
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("号码或号段，如 9521、0213100、189xxxx", text: $customRulePattern)
                            .textFieldStyle(.roundedBorder)
                            #if canImport(UIKit)
                            .keyboardType(.numbersAndPunctuation)
                            #endif

                        Picker("响应动作", selection: $selectedAction) {
                            Text("🚫 自动挂断 (系统阻断)").tag(RuleActionType.block)
                            Text("🏷️ 来电识别 (显示标记)").tag(RuleActionType.identify)
                        }
                        .pickerStyle(.segmented)

                        if selectedAction == .identify {
                            HStack {
                                Text("标签")
                                    .foregroundColor(.secondary)
                                TextField("如: 房产中介 / 催收", text: $identifyLabel)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        if let hint = patternHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button {
                            Task { await addRule() }
                        } label: {
                            Label(
                                selectedAction == .block ? "添加为自动挂断黑名单" : "添加为来电识别",
                                systemImage: selectedAction == .block ? "nosign" : "tag.fill"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(selectedAction == .block ? .red : .blue)
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
                    Text("精准添加自定义规则")
                } footer: {
                    Text(selectedAction == .block ? "自动挂断：命中该规则时，iPhone 静默阻断来电不响铃，并在通话记录标明由 Trashcall 阻止。" : "来电识别：完整手机号精确标记，短号段自动补最多 4 位（例如 9521 → 9521****）。")
                        .font(.caption2)
                }

                // 6. 自定义规则列表
                Section("自定义规则 (\(activeRules.count))") {
                    if activeRules.isEmpty {
                        Text("还没有自定义规则。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(activeRules) { rule in
                            HStack(spacing: 12) {
                                Image(systemName: rule.action == .block ? "nosign" : "tag.fill")
                                    .foregroundColor(rule.action == .block ? .red : .blue)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(rule.pattern)
                                        .font(.headline)
                                        .monospaced()
                                    HStack(spacing: 6) {
                                        Text(rule.action == .block ? "🚫 自动挂断" : "🏷️ \(rule.label ?? "自定义标记")")
                                            .foregroundColor(rule.action == .block ? .red : .primary)
                                        Text("·")
                                        Text("\(rule.count) 个号码")
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    if liveRuleIDs.contains(rule.id) {
                                        Text("已写入系统底层库")
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

                // 7. 高级设置与系统底层诊断（折叠式收拢）
                Section {
                    DisclosureGroup("高级设置与系统底层诊断", isExpanded: $showAdvancedSettings) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("App Group 状态")
                                Spacer()
                                Text(appGroupReady ? "已接通 (group.com.trashcall.shared)" : "未接通")
                                    .font(.caption)
                                    .foregroundColor(appGroupReady ? .green : .red)
                            }

                            if let run = lastExtensionRun {
                                Divider()
                                Text("扩展上次同步统计：")
                                    .font(.caption.weight(.semibold))
                                Text("• 注入自动挂断: \(run.blockingFed) 条")
                                    .font(.caption2).foregroundColor(.secondary)
                                Text("• 注入来电识别: \(run.identificationFed) 条")
                                    .font(.caption2).foregroundColor(.secondary)
                                Text("• 同步时间: \(runTimeText(run.at))")
                                    .font(.caption2).foregroundColor(.secondary)
                                if let err = run.error, !err.isEmpty {
                                    Text("• 扩展错误: \(err)")
                                        .font(.caption2).foregroundColor(.red)
                                }
                            }

                            Divider()
                            HStack {
                                Text("种子版本")
                                Spacer()
                                Text(seedVersion)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("软件版本")
                                Spacer()
                                Text(installedVersion)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }

                            Divider()
                            Button {
                                Task { await triggerSync() }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isSyncing {
                                        ProgressView().padding(.trailing, 8)
                                        Text("正在同步底层数据库...")
                                    } else {
                                        Label("重新同步全量数据库", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(isSyncing)
                            .padding(.top, 4)

                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("真机拦截生效避坑指南：")
                                    .font(.caption.weight(.bold))
                                Text("1. 本机去电记录豁免：若手机曾主动呼叫过测试号，iOS 永久豁免拦截！测试前请在「最近通话」中左滑删除去电记录。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("2. 通讯录优先：通讯录中的号码享有最高优先级，绝不执行拦截。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Trashcall")
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    checkClipboard()
                }
            }
            .task {
                isSyncing = true
                await Task.detached(priority: .userInitiated) {
                    DatabaseBootstrap.run()
                }.value
                await refreshStatus()
                checkClipboard()
                if extensionStatus == .enabled {
                    do {
                        try await Task.sleep(for: .milliseconds(300))
                        try await manager.reloadExtension()
                        await refreshStatus()
                    } catch {
                        if manager.isCurrentlyLoading(error) {
                            await refreshStatus()
                        } else {
                            let nsErr = error as NSError
                            errorMessage = "启动时系统重载失败 [错误码 \(nsErr.code)]：\(error.localizedDescription)"
                        }
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
        lastExtensionRun = ExtensionRunReport.load(fileName: ExtensionRunReport.defaultFileName)
            ?? ExtensionRunReport.load(fileName: ExtensionRunReport.identifyFileName)
            ?? ExtensionRunReport.load()

        if let store = getStore(readOnly: true) {
            blockingCount = store.countBlocking()
            identificationCount = store.countIdentification()
            seedVersion = (try? store.getVersion()) ?? "—"

            var strategies: [ProtectionStrategy: Bool] = [:]
            for strategy in ProtectionStrategy.allCases {
                strategies[strategy] = store.isStrategyEnabled(strategy)
            }
            strategyStates = strategies

            if let persistedRules = try? store.getUserRules() {
                activeRules = persistedRules
                var live: Set<UUID> = []
                for rule in persistedRules {
                    if rule.pattern.contains("*") || rule.pattern.contains("?") { continue }
                    let entries = PhoneNumber.callKitEntries(rule.pattern)
                    if rule.action == .block {
                        if entries.contains(where: { store.containsBlocking($0.rawValue) }) {
                            live.insert(rule.id)
                        }
                    } else {
                        if entries.contains(where: { store.containsIdentification($0.rawValue) }) {
                            live.insert(rule.id)
                        }
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
            successNotice = "数据库已同步，CallKit 扩展已成功重载。"
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
                action: selectedAction,
                label: selectedAction == .block ? nil : identifyLabel,
                count: phoneNumbers.count
            )
            try store.addUserRule(newRule, numbers: phoneNumbers)
            withAnimation {
                activeRules.insert(newRule, at: 0)
            }
            customRulePattern = ""
            try await manager.reloadExtension()
            await refreshStatus()
            let actionText = selectedAction == .block ? "自动挂断黑名单" : "来电识别"
            if phoneNumbers.count <= 4 {
                let preview = phoneNumbers.map { "+\($0)" }.joined(separator: " / ")
                successNotice = "已将 \(preview) 写入\(actionText)。"
            } else {
                successNotice = "已将号段 \(resolved)（\(phoneNumbers.count) 个号码）写入\(actionText)。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        let rulesToDelete = offsets.compactMap { index in
            index < activeRules.count ? activeRules[index] : nil
        }
        guard !rulesToDelete.isEmpty else { return }

        // 立即乐观更新 UI 数组，让 SwiftUI 滑动删除动画瞬间完成无任何粘滞感
        withAnimation(.easeOut(duration: 0.2)) {
            activeRules.remove(atOffsets: offsets)
        }

        Task {
            guard let store = getStore(readOnly: false) else {
                errorMessage = "无法连接离线数据库"
                await refreshStatus()
                return
            }
            let expander = RuleExpander()
            for rule in rulesToDelete {
                let numbers = (try? expander.expandWildcard(rule.pattern).map(\.rawValue)) ?? []
                do {
                    try store.deleteUserRule(id: rule.id, pattern: rule.pattern, action: rule.action, numbers: numbers)
                } catch {
                    errorMessage = "删除规则失败: \(error.localizedDescription)"
                    await refreshStatus()
                    return
                }
            }
            do {
                try await manager.reloadExtension()
            } catch {
                if !manager.isCurrentlyLoading(error) {
                    errorMessage = "已从本地删除，但系统重载失败：\(error.localizedDescription)"
                }
            }
            await refreshStatus()
            successNotice = "规则已删除。"
        }
    }

    private func toggleAllStrategies(enabled: Bool) async {
        errorMessage = nil
        successNotice = nil
        isSyncing = true
        defer { isSyncing = false }
        guard let store = getStore(readOnly: false) else {
            errorMessage = "无法连接离线数据库"
            return
        }
        do {
            try store.setAllStrategies(enabled: enabled)
            for strategy in ProtectionStrategy.allCases {
                strategyStates[strategy] = enabled
            }
            try await manager.reloadExtension()
            await refreshStatus()
            successNotice = enabled ? "所有高危号段已切换为「自动挂断」。" : "所有高危号段已恢复为「来电打标」。"
        } catch {
            errorMessage = "批量策略设置失败: \(error.localizedDescription)"
            await refreshStatus()
        }
    }

    // MARK: - 剪贴板感知与处理

    private func checkClipboard() {
        #if canImport(UIKit)
        guard UIPasteboard.general.hasStrings else { return }
        guard let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return }
        guard raw != lastProcessedClipboard else { return }

        // 过滤非数字与+符号
        let digitsOnly = raw.filter { $0.isNumber || $0 == "+" }
        guard digitsOnly.count >= 3 && digitsOnly.count <= 18 else { return }

        // 确保不包含字母（避免复制大段文字误触发）
        let totalLetters = raw.filter { $0.isLetter }.count
        guard totalLetters == 0 else { return }

        withAnimation {
            detectedClipboardNumber = raw
        }
        #endif
    }

    private func addQuickClipboardRule(_ number: String, action: RuleActionType) async {
        customRulePattern = number
        selectedAction = action
        if action == .identify {
            identifyLabel = "剪贴板快速标记"
        }
        await addRule()
        withAnimation {
            lastProcessedClipboard = number
            detectedClipboardNumber = nil
        }
    }

    // MARK: - 预设防御策略切换

    private func toggleStrategy(_ strategy: ProtectionStrategy, enabled: Bool) async {
        errorMessage = nil
        successNotice = nil
        isSyncing = true
        defer { isSyncing = false }
        guard let store = getStore(readOnly: false) else {
            errorMessage = "无法连接离线数据库"
            return
        }
        do {
            try store.setStrategy(strategy, enabled: enabled)
            strategyStates[strategy] = enabled
            try await manager.reloadExtension()
            await refreshStatus()
            successNotice = "\(strategy.title) 已\(enabled ? "开启自动挂断" : "恢复为来电识别")。"
        } catch {
            errorMessage = "策略设置失败: \(error.localizedDescription)"
            await refreshStatus()
        }
    }

    // MARK: - 号码沙盒诊断

    private func runDiagnosis() {
        let input = diagnosticInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            diagnosticResult = nil
            return
        }
        if let store = getStore(readOnly: true) {
            diagnosticResult = store.diagnose(input: input)
        }
    }
}
#endif
