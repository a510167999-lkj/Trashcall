import Foundation

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Presents the saved rules and the activation state of both Call Directory extensions.
public struct TrashcallDashboardView: View {
    @State private var extensionStatus: ExtensionStatus = .unknown
    @State private var blockingCount: Int = 0
    @State private var identificationCount: Int = 0
    @State private var seedVersion: String = "—"
    @State private var isSyncing: Bool = false
    @State private var extensionReload: Task<[Error], Never>?
    @State private var reloadQueued = false
    @State private var customRulePattern: String = ""
    @State private var selectedAction: RuleActionType = .block
    @State private var identifyLabel: String = "推销骚扰"
    @State private var activeRules: [ActiveRuleItem] = []
    @State private var directoryRevision: String?
    @State private var acceptedRevisions: [String: String] = [:]
    @State private var reloadFailures: [String: String] = [:]
    @State private var appReady = false
    @State private var confirmOfficialRollback = false
    @State private var lastExtensionRun: ExtensionRunReport?
    @State private var lastBlockRun: ExtensionRunReport?
    @State private var blockingStatus: ExtensionStatus = .unknown
    @State private var appGroupReady: Bool = false
    @State private var errorMessage: String?
    @State private var successNotice: String?

    // 剪贴板智能感知状态
    @State private var detectedClipboardNumber: String?
    @Environment(\.scenePhase) private var scenePhase

    // 预设高危策略开关状态
    @State private var strategyStates: [ProtectionStrategy: Bool] = [:]

    // 号码沙盒诊断状态
    @State private var diagnosticInput: String = ""
    @State private var diagnosticResult: NumberDiagnosticResult?

    // 折叠高级设置
    @State private var showAdvancedSettings: Bool = false

    // 云端数据库自动更新状态
    @State private var autoUpdateEnabled: Bool = true
    @State private var cloudVersion: String = "—"
    @State private var lastUpdateCheckText: String = "—"
    @State private var isCheckingUpdate: Bool = false

    // iCloud 自定义规则云同步状态（用户专属私有库）
    @State private var iCloudAccountStatusText: String = "检测中..."
    @State private var lastICloudSyncText: String = "—"
    @State private var isSyncingICloud: Bool = false
    @State private var iCloudSyncQueued = false

    public let extensionId: String
    private let manager: CallDirectoryManagerService
    private let blockingManager: CallDirectoryManagerService

    public init(extensionId: String = TrashcallExtensionID.identification) {
        self.extensionId = extensionId
        self.manager = CallDirectoryManagerService(extensionBundleIdentifier: extensionId)
        self.blockingManager = CallDirectoryManagerService(
            extensionBundleIdentifier: TrashcallExtensionID.blocking
        )
    }

    /// Reloads every extension the user has enabled in system settings.
    /// Returns the error of each failed reload (empty = all succeeded).
    private func reloadEnabledExtensions() async -> [Error] {
        if let extensionReload {
            reloadQueued = true
            return await extensionReload.value
        }
        let request = Task {
            var errors: [Error]
            repeat {
                reloadQueued = false
                errors = await reloadExtensionsOnce()
            } while reloadQueued && !Task.isCancelled
            return errors
        }
        extensionReload = request
        let errors = await request.value
        extensionReload = nil
        return errors
    }

    private func reloadExtensionsOnce() async -> [Error] {
        var errors: [Error] = []
        for service in [manager, blockingManager] {
            guard await service.checkStatus() == .enabled else { continue }
            do {
                try await service.reloadExtension()
                reloadFailures.removeValue(forKey: service.extensionBundleIdentifier)
            } catch {
                reloadFailures[service.extensionBundleIdentifier] = error.localizedDescription
                errors.append(error)
            }
        }
        return errors
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
                                Text("已粘贴的号码")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button {
                                    withAnimation {
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
                                Text(protectionTitle)
                                    .font(.headline.weight(.bold))
                                Text(protectionSubtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("本机规则条目")
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

                        VStack(alignment: .leading, spacing: 8) {
                            activationRow("来电识别", manager: manager, status: extensionStatus, report: lastExtensionRun)
                            activationRow("自动挂断", manager: blockingManager, status: blockingStatus, report: lastBlockRun)
                        }
                        if needsActivation || !appReady {
                            Button("重新加载系统扩展") {
                                Task { await triggerSync() }
                            }
                            .disabled(isSyncing || extensionReload != nil || isCheckingUpdate || isSyncingICloud)
                        }

                        if TrashcallExtensionID.embeddedCallDirectoryCount < 2 {
                            Text("未检测到安装包内的识别/挂断扩展。若使用全能签等工具自签，请确保：1. 未勾选「移除扩展/插件」；2. 若修改主程序 Bundle ID，两个扩展的 Bundle ID 须保持为「主程序ID.xxx」格式。")
                                .font(.caption2)
                                .foregroundColor(.red)
                        } else if extensionStatus != .enabled || blockingStatus != .enabled {
                            Button {
                                Task { await manager.openCallDirectorySettings() }
                            } label: {
                                Label("前往开启「来电阻止与身份识别」中的两个开关", systemImage: "gearshape.fill")
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
                            get: { strategyStates[strategy] ?? false },
                            set: { newVal in
                                guard !isSyncing else { return }
                                // 乐观更新，避免开关回弹；写库失败时 refreshStatus 会纠正
                                strategyStates[strategy] = newVal
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
                        .disabled(isSyncing)
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
                        .disabled(isSyncing)
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
                    Text("查看号码在本地规则库中的匹配结果。")
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

                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first { usePastedNumber(value) }
                        }
                        .accessibilityLabel("粘贴号码")

                        Picker("响应动作", selection: $selectedAction) {
                            Text("挂断").tag(RuleActionType.block)
                            Text("打标").tag(RuleActionType.identify)
                            Text("允许来电").tag(RuleActionType.allow)
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
                                "保存\(actionTitle)",
                                systemImage: selectedAction == .block ? "nosign" : (selectedAction == .allow ? "checkmark.shield" : "tag.fill")
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
                    Text(selectedAction == .allow ? "输入完整号码。允许来电会覆盖 Trashcall 的挂断规则，并保留已有识别标签。" : "短号段会补齐通配符，例如 9521 → 9521****。通配符只可放在末尾。")
                        .font(.caption2)
                }

                // 6. iCloud 自定义规则云同步（用户专属私有库）
                Section {
                    HStack {
                        Label("iCloud 账户状态", systemImage: "icloud.fill")
                            .foregroundColor(.blue)
                        Spacer()
                        Text(iCloudAccountStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("上次云端同步")
                        Spacer()
                        Text(lastICloudSyncText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        Task { await performICloudSync(showNotice: true) }
                    } label: {
                        HStack {
                            Spacer()
                            if isSyncingICloud {
                                ProgressView().padding(.trailing, 8)
                                Text("正在与 iCloud 私有库同步...")
                            } else {
                                Label("立即同步 iCloud 规则", systemImage: "arrow.triangle.2.circlepath.icloud")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSyncingICloud || isSyncing)
                } header: {
                    Text("iCloud 规则云同步（独立私有库）")
                } footer: {
                    Text("支持 CloudKit 的签名可将自定义规则同步到当前 Apple ID 的 iCloud 私有数据库。")
                        .font(.caption2)
                }

                // 7. 自定义规则列表
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
                                        Text(rule.action == .identify ? "🏷️ \(rule.label ?? "自定义标记")" : rule.action.rawValue)
                                            .foregroundColor(rule.action == .block ? .red : .primary)
                                        Text("·")
                                        Text("\(rule.count) 个号码")
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    if (try? RuleExpander().estimateCount(rule.pattern)) == nil {
                                        Text("旧号段格式无效，请删除后重新添加")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .onDelete(perform: deleteRules)
                    }
                }

                // 7. 云端数据库自动更新
                Section {
                    Toggle("启动或返回前台时检查官方规则", isOn: $autoUpdateEnabled)
                        .onChange(of: autoUpdateEnabled) { _, newValue in
                            if let store = getStore(readOnly: false) {
                                try? DatabaseUpdateService.shared.setAutoUpdateEnabled(newValue, in: store)
                            }
                        }

                    HStack {
                        Text("本机官方规则版本")
                        Spacer()
                        Text(cloudVersion)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("上次检查更新时间")
                        Spacer()
                        Text(lastUpdateCheckText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        Task { await performUpdateCheck(force: true) }
                    } label: {
                        HStack {
                            Spacer()
                            if isCheckingUpdate {
                                ProgressView().padding(.trailing, 8)
                                Text("正在检查云端规则库更新...")
                            } else {
                                Label("立即检查云端更新", systemImage: "arrow.clockwise.cloud.fill")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isCheckingUpdate || isSyncing)
                    if cloudVersion != "—" {
                        Button("回滚官方规则", role: .destructive) { confirmOfficialRollback = true }
                            .disabled(isCheckingUpdate || isSyncing)
                    }
                } header: {
                    Text("云端数据库更新")
                } footer: {
                    Text("回滚会恢复上一版官方规则。没有上一版时仅卸载当前官方规则，本地规则和预设策略仍然保留。")
                        .font(.caption2)
                }

                // 8. 高级设置与系统底层诊断（折叠式收拢）
                Section {
                    DisclosureGroup("高级设置与系统底层诊断", isExpanded: $showAdvancedSettings) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("App Group 状态")
                                Spacer()
                                Text(appGroupReady ? "已接通 (\(DatabaseBootstrap.appGroupId))" : "未接通 (已启用离线备用库)")
                                    .font(.caption)
                                    .foregroundColor(appGroupReady ? .green : .orange)
                            }

                            if !appGroupReady {
                                Text("说明：使用全能签免费个人证书签名时 App Group 未授权属正常现象。来电识别与挂断已自动回退至内置离线库保护（41万条云端号库）。若需在 App 内实时修改自定义黑名单并热同步至系统拦截，建议开通含 App Group 权限的证书。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            if let run = lastExtensionRun {
                                Divider()
                                Text("识别扩展上次同步统计：")
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

                            if let run = lastBlockRun {
                                Divider()
                                Text("挂断扩展上次同步统计：")
                                    .font(.caption.weight(.semibold))
                                Text("• 注入自动挂断: \(run.blockingFed) 条")
                                    .font(.caption2).foregroundColor(.secondary)
                                Text("• 同步时间: \(runTimeText(run.at))")
                                    .font(.caption2).foregroundColor(.secondary)
                                if let err = run.error, !err.isEmpty {
                                    Text("• 扩展错误: \(err)")
                                        .font(.caption2).foregroundColor(.red)
                                }
                            } else if blockingStatus == .enabled {
                                Divider()
                                Text("挂断扩展尚未完成过一次同步：请先在系统设置开启「Trashcall 挂断」，再点「重新同步全量数据库」。")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
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
                                    if isSyncing || extensionReload != nil {
                                        ProgressView().padding(.trailing, 8)
                                        Text("正在同步底层数据库...")
                                    } else {
                                        Label("重新同步全量数据库", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(isSyncing || extensionReload != nil)
                            .padding(.top, 4)

                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                Text("来电验收")
                                    .font(.caption.weight(.semibold))
                                Text("从另一台电话呼入，分别核对来电标记和挂断。若签名缺少共享容器，系统扩展只能读取内置识别库。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Trashcall")
            .confirmationDialog("回滚官方规则？", isPresented: $confirmOfficialRollback, titleVisibility: .visible) {
                Button("回滚官方规则", role: .destructive) { Task { await rollbackOfficialRules() } }
            } message: {
                Text("已回滚的版本可通过手动更新重新应用。")
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active, appReady {
                    Task { await refreshStatus() }
                    if autoUpdateEnabled {
                        Task { await performUpdateCheck(force: false) }
                    }
                    Task { await performICloudSync(showNotice: false) }
                }
            }
            .task {
                isSyncing = true
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try DatabaseBootstrap.prepareDatabase()
                    }.value
                } catch {
                    errorMessage = "初始化本地规则失败：\(error.localizedDescription)"
                    isSyncing = false
                    return
                }
                await refreshStatus()
                isSyncing = false
                appReady = true

                if needsActivation {
                    _ = await reloadEnabledExtensions()
                    await refreshStatus()
                }

                // 启动完成后静默检查云端更新与 iCloud 同步
                if autoUpdateEnabled {
                    await performUpdateCheck(force: false)
                }
                await performICloudSync(showNotice: false)
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
                if selectedAction == .allow { return "允许来电需要输入完整号码。" }
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

    // MARK: - 状态文案

    /// 挂断要真正生效，识别与挂断两个扩展开关都必须开启。
    private var bothExtensionsEnabled: Bool {
        extensionStatus == .enabled && blockingStatus == .enabled
    }

    private var protectionTitle: String {
        if bothExtensionsEnabled { return needsActivation ? "规则已保存，等待系统加载" : "系统已加载当前规则" }
        if extensionStatus == .enabled { return "挂断扩展未开启" }
        if blockingStatus == .enabled { return "识别扩展未开启" }
        return "未开启系统授权"
    }

    private var protectionSubtitle: String {
        if bothExtensionsEnabled { return "识别与挂断扩展均已开启" }
        if extensionStatus == .enabled {
            return "已开启识别，请在系统「设置 → 电话 → 来电阻止与身份识别」中开启「Trashcall 挂断」"
        }
        if blockingStatus == .enabled {
            return "已开启挂断，请在系统「设置 → 电话 → 来电阻止与身份识别」中开启「Trashcall 识别」"
        }
        return "请前往系统「设置 → 电话 → 来电阻止与身份识别」开启两个开关"
    }

    private var statusIcon: String {
        switch (extensionStatus, blockingStatus) {
        case (.enabled, .enabled): return needsActivation ? "exclamationmark.shield.fill" : "checkmark.shield.fill"
        case (.enabled, _), (_, .enabled): return "exclamationmark.shield.fill"
        default: return "questionmark.shield"
        }
    }

    private var statusColor: Color {
        switch (extensionStatus, blockingStatus) {
        case (.enabled, .enabled): return needsActivation ? .orange : .green
        case (.enabled, _), (_, .enabled): return .orange
        default: return .gray
        }
    }

    private var actionTitle: String {
        switch selectedAction {
        case .block: "挂断规则"
        case .identify: "识别规则"
        case .allow: "允许来电规则"
        }
    }

    private var needsActivation: Bool {
        guard appGroupReady else { return true }
        return [(manager, extensionStatus, lastExtensionRun), (blockingManager, blockingStatus, lastBlockRun)]
            .contains { service, status, report in
                status == .enabled && !activationState(service, status: status, report: report).isLoaded
            }
    }

    private func activationState(
        _ service: CallDirectoryManagerService, status: ExtensionStatus, report: ExtensionRunReport?
    ) -> DirectoryActivationStatus {
        DirectoryActivationStatus.resolve(
            extensionStatus: status, appGroupReady: appGroupReady, revision: directoryRevision,
            acceptedRevision: acceptedRevisions[service.extensionBundleIdentifier], report: report,
            reloadError: reloadFailures[service.extensionBundleIdentifier]
        )
    }

    private func activationRow(
        _ title: String, manager service: CallDirectoryManagerService,
        status: ExtensionStatus, report: ExtensionRunReport?
    ) -> some View {
        let state = activationState(service, status: status, report: report)
        let inProgress = state == .pending && extensionReload != nil
        return LabeledContent(title, value: inProgress ? "系统正在加载…" : state.message)
            .font(.caption)
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
        blockingStatus = await blockingManager.checkStatus()
        appGroupReady = DatabaseBootstrap.isUsingAppGroup
        lastExtensionRun = ExtensionRunReport.load(fileName: ExtensionRunReport.identifyFileName)
        lastBlockRun = ExtensionRunReport.load(fileName: ExtensionRunReport.blockFileName)

        if let store = getStore(readOnly: true) {
            blockingCount = store.countBlocking()
            identificationCount = store.countIdentification()
            seedVersion = (try? store.getVersion()) ?? "—"
            let officialVersion = DatabaseUpdateService.shared.getCloudRulesVersion(in: store) ?? ""
            cloudVersion = officialVersion.isEmpty ? "—" : officialVersion
            directoryRevision = try? store.getMetadata(key: "directory_revision")
            var revisions: [String: String] = [:]
            for id in [manager.extensionBundleIdentifier, blockingManager.extensionBundleIdentifier] {
                revisions[id] = try? store.getMetadata(key: CallDirectoryManagerService.acceptedRevisionKey(id))
            }
            acceptedRevisions = revisions
            autoUpdateEnabled = DatabaseUpdateService.shared.isAutoUpdateEnabled(in: store)
            if let lastCheck = DatabaseUpdateService.shared.getLastCheckTime(in: store) {
                lastUpdateCheckText = runTimeText(lastCheck.timeIntervalSince1970)
            } else {
                lastUpdateCheckText = "尚未检查"
            }
            if let lastSync = CloudKitSyncService.shared.getLastSyncTime(in: store) {
                lastICloudSyncText = runTimeText(lastSync.timeIntervalSince1970)
            } else {
                lastICloudSyncText = "尚未同步"
            }

            var strategies: [ProtectionStrategy: Bool] = [:]
            for strategy in ProtectionStrategy.allCases {
                strategies[strategy] = store.isStrategyEnabled(strategy)
            }
            strategyStates = strategies

            if let persistedRules = try? store.getUserRules() { activeRules = persistedRules }
        }
    }

    private func performUpdateCheck(force: Bool) async {
        guard !isCheckingUpdate, !isSyncing else { return }
        isCheckingUpdate = true
        if force {
            errorMessage = nil
            successNotice = nil
        }
        defer { isCheckingUpdate = false }

        let result = await DatabaseUpdateService.shared.checkAndUpdate(force: force) {
            await self.reloadEnabledExtensions()
        }

        await refreshStatus()

        switch result {
        case .upToDate(let version):
            if force {
                successNotice = "云端数据库已是最新版本 (\(version))。"
            }
        case .updated(let version, let blocking, let ident):
            successNotice = "已保存官方规则 \(version)（挂断 \(blocking) 条，识别 \(ident) 条）。"
        case .savedPendingActivation(_, _):
            errorMessage = result.summaryMessage
        case .deferred:
            if force { successNotice = result.summaryMessage }
        case .failed(let reason):
            if force {
                errorMessage = "检查更新失败: \(reason)"
            }
        }
    }

    private func triggerSync() async {
        guard !isSyncing, extensionReload == nil else { return }
        isSyncing = true
        errorMessage = nil
        successNotice = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try DatabaseBootstrap.prepareDatabase()
            }.value
            appReady = true
        } catch {
            isSyncing = false
            errorMessage = "初始化本地规则失败：\(error.localizedDescription)"
            return
        }
        isSyncing = false
        let errors = await reloadEnabledExtensions()
        await refreshStatus()
        if !errors.isEmpty {
            errorMessage = "重载扩展失败: \(errors.map(\.localizedDescription).joined(separator: "；"))"
        } else if !bothExtensionsEnabled {
            if extensionStatus != .enabled && blockingStatus != .enabled {
                successNotice = "数据库已就绪。请在系统「设置 → 电话 → 来电阻止与身份识别」中开启「Trashcall 识别」与「Trashcall 挂断」开关。"
            } else {
                successNotice = "数据库已同步并重载已开启的扩展。提示：另一个扩展开关尚未在系统设置中开启。"
            }
        } else {
            successNotice = "数据库已同步，识别与挂断扩展均已成功重载。"
        }
    }

    private func rollbackOfficialRules() async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let url = DatabaseBootstrap.databaseURL()
            let version = try await Task.detached(priority: .userInitiated) {
                let store = CallDirectoryStore(databaseURL: url)
                try store.open()
                try store.initializeSchema()
                return try store.rollbackOfficialRules()
            }.value
            let message = version.isEmpty ? "已卸载当前官方规则。" : "已恢复官方规则 \(version)。"
            finishChangeAfterStoreWrite(successMessage: message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addRule() async {
        errorMessage = nil
        successNotice = nil
        isSyncing = true
        defer { isSyncing = false }

        let pattern = PatternInput.resolved(customRulePattern)
        let action = selectedAction
        let label = action == .identify ? identifyLabel : nil
        let title = actionTitle
        let url = DatabaseBootstrap.databaseURL()
        do {
            let saved = try await Task.detached(priority: .userInitiated) {
                let store = CallDirectoryStore(databaseURL: url)
                try store.open()
                try store.initializeSchema()
                return try store.addUserRule(ActiveRuleItem(pattern: pattern, action: action, label: label))
            }.value
            customRulePattern = ""
            finishChangeAfterStoreWrite(successMessage: "已保存\(title) \(saved.pattern)（\(saved.count) 条）。")
            Task { await performICloudSync() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        let ids = offsets.map { activeRules[$0].id }
        let url = DatabaseBootstrap.databaseURL()
        Task {
            isSyncing = true
            defer { isSyncing = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let store = CallDirectoryStore(databaseURL: url)
                    try store.open()
                    try store.initializeSchema()
                    try store.deleteUserRules(ids: ids)
                }.value
                finishChangeAfterStoreWrite(successMessage: "规则已删除。")
                Task { await performICloudSync() }
            } catch {
                errorMessage = "删除规则失败：\(error.localizedDescription)"
                await refreshStatus()
            }
        }
    }

    private func toggleAllStrategies(enabled: Bool) async {
        errorMessage = nil
        successNotice = nil
        isSyncing = true
        defer { isSyncing = false }
        guard let store = getStore(readOnly: false) else {
            errorMessage = "无法连接离线数据库"
            await refreshStatus()
            return
        }
        do {
            try store.setAllStrategies(enabled: enabled)
            for strategy in ProtectionStrategy.allCases {
                strategyStates[strategy] = enabled
            }
        } catch {
            errorMessage = "批量策略设置失败: \(error.localizedDescription)"
            await refreshStatus()
            return
        }
        finishChangeAfterStoreWrite(
            successMessage: enabled ? "所有高危号段已切换为「自动挂断」。" : "所有高危号段已恢复为「来电打标」。"
        )
    }

    /// Publish the saved result immediately. System activation has its own status.
    private func finishChangeAfterStoreWrite(successMessage: String) {
        successNotice = successMessage
        Task {
            await refreshStatus()
            if needsActivation {
                _ = await reloadEnabledExtensions()
                await refreshStatus()
            }
        }
    }

    // MARK: - iCloud 云同步操作

    private func updateICloudStatus() async {
        let status = await CloudKitSyncService.shared.getAccountStatus()
        await MainActor.run {
            self.iCloudAccountStatusText = status.description
            if let store = getStore(readOnly: true),
               let lastSync = CloudKitSyncService.shared.getLastSyncTime(in: store) {
                self.lastICloudSyncText = runTimeText(lastSync.timeIntervalSince1970)
            }
        }
    }

    private func performICloudSync(showNotice: Bool = false) async {
        if isSyncingICloud {
            iCloudSyncQueued = true
            return
        }
        isSyncingICloud = true
        defer { isSyncingICloud = false }
        repeat {
            iCloudSyncQueued = false
            await syncICloudRules(showNotice: showNotice)
        } while iCloudSyncQueued && !Task.isCancelled
    }

    private func syncICloudRules(showNotice: Bool) async {
        guard let store = getStore(readOnly: false) else {
            if showNotice { errorMessage = "无法打开本地规则库。" }
            return
        }
        let before = try? store.getMetadata(key: "directory_revision")
        let result = await CloudKitSyncService.shared.sync(store: store)
        let after = try? store.getMetadata(key: "directory_revision")

        if showNotice {
            if result.isSuccess {
                successNotice = result.summaryMessage
            } else {
                errorMessage = result.summaryMessage
            }
        }

        if before != after {
            let errors = await reloadEnabledExtensions()
            if !errors.isEmpty {
                errorMessage = "iCloud 规则已保存，系统加载失败：\(errors.map(\.localizedDescription).joined(separator: "；"))"
            }
        }
        await refreshStatus()
        await updateICloudStatus()
    }

    // MARK: - 主动粘贴号码

    private func usePastedNumber(_ value: String) {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PatternInput.hasSupportedCharacters(raw), !raw.isEmpty else {
            errorMessage = "剪贴板里的内容不是有效的号码或号段。"
            return
        }
        withAnimation {
            detectedClipboardNumber = raw
            customRulePattern = raw
        }
    }

    private func addQuickClipboardRule(_ number: String, action: RuleActionType) async {
        customRulePattern = number
        selectedAction = action
        if action == .identify {
            identifyLabel = "剪贴板快速标记"
        }
        await addRule()
        withAnimation {
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
            await refreshStatus()
            return
        }
        do {
            try store.setStrategy(strategy, enabled: enabled)
            strategyStates[strategy] = enabled
        } catch {
            errorMessage = "策略设置失败: \(error.localizedDescription)"
            await refreshStatus()
            return
        }
        finishChangeAfterStoreWrite(
            successMessage: "\(strategy.title) 已\(enabled ? "开启自动挂断" : "恢复为来电识别")。"
        )
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
