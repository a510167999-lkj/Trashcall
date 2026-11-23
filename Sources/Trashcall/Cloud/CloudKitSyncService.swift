import Foundation

#if canImport(CloudKit)
import CloudKit
#endif

/// iCloud 账户当前状态
public enum CloudAccountStatus: String, Sendable, CustomStringConvertible {
    case available = "已连接"
    case noAccount = "未登录 iCloud"
    case restricted = "iCloud 受限"
    case temporarilyUnavailable = "网络暂时不可用"
    case notConfigured = "当前签名未配置 CloudKit"
    case notSupported = "当前系统不支持"
    case couldNotDetermine = "未知状态"

    public var description: String { rawValue }

    public var isAvailable: Bool {
        self == .available
    }
}

/// 云同步执行结果
public enum CloudSyncResult: Sendable, Equatable {
    case success(pulled: Int, deleted: Int, pushed: Int)
    case upToDate
    case skipped(reason: String)
    case failed(reason: String)

    public var isSuccess: Bool {
        switch self {
        case .success, .upToDate: return true
        case .skipped, .failed: return false
        }
    }

    public var summaryMessage: String {
        switch self {
        case .success(let pulled, let deleted, let pushed):
            var parts: [String] = []
            if pulled > 0 { parts.append("拉取 \(pulled) 条") }
            if deleted > 0 { parts.append("移除 \(deleted) 条") }
            if pushed > 0 { parts.append("上传 \(pushed) 条") }
            return parts.isEmpty ? "iCloud 同步完成（无变更）" : "iCloud 同步完成（\(parts.joined(separator: "，") )）"
        case .upToDate:
            return "iCloud 数据已是最新"
        case .skipped(let reason):
            return "跳过同步: \(reason)"
        case .failed(let reason):
            return "同步失败: \(reason)"
        }
    }
}

/// 负责将用户自定义规则安全同步到 Apple iCloud Private Database 的服务引擎
public final class CloudKitSyncService: @unchecked Sendable {
    public static let shared = CloudKitSyncService()

    public static let containerIdentifier = "iCloud.com.trashcall.app"
    public static let recordType = "UserCustomRule"

    private let syncQueue = DispatchQueue(label: "com.trashcall.cloudkit.sync", qos: .utility)
    private var isSyncing: Bool = false

    private init() {}

    /// Validates the entitlement values required by this app's CloudKit container.
    /// Keeping this pure makes the signing boundary testable without initializing CKContainer.
    public static func hasRequiredCloudKitEntitlements(
        containerIdentifiers: [String],
        services: [String]
    ) -> Bool {
        containerIdentifiers.contains(containerIdentifier)
            && (services.contains("CloudKit") || services.contains("*"))
    }

    // MARK: - Account Status

    public func getAccountStatus() async -> CloudAccountStatus {
        #if canImport(CloudKit)
        guard Self.hasRuntimeCloudKitEntitlements else {
            return .notConfigured
        }
        let container = getContainer()
        do {
            let status = try await withThrowingTaskGroup(of: CKAccountStatus.self) { group in
                group.addTask {
                    try await container.accountStatus()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    throw NSError(domain: "CloudKitSyncService", code: -1, userInfo: [NSLocalizedDescriptionKey: "iCloud 状态检查超时"])
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            switch status {
            case .available:
                return .available
            case .noAccount:
                return .noAccount
            case .restricted:
                return .restricted
            case .temporarilyUnavailable:
                return .temporarilyUnavailable
            case .couldNotDetermine:
                fallthrough
            @unknown default:
                return .couldNotDetermine
            }
        } catch {
            return .temporarilyUnavailable
        }
        #else
        return .notSupported
        #endif
    }

    // MARK: - Full Bidirectional Sync

    /// 执行双向全量对齐同步
    /// - Parameters:
    ///   - store: 共享 SQLite 数据库实例
    /// - Returns: 同步结果
    public func sync(store: CallDirectoryStore) async -> CloudSyncResult {
        #if canImport(CloudKit)
        // 防重复并发触发
        let shouldProceed = syncQueue.sync { () -> Bool in
            if self.isSyncing { return false }
            self.isSyncing = true
            return true
        }
        guard shouldProceed else {
            return .skipped(reason: "同步任务正在进行中")
        }
        defer {
            syncQueue.sync { self.isSyncing = false }
        }

        let status = await getAccountStatus()
        guard status.isAvailable else {
            return .skipped(reason: status.description)
        }

        let db = getContainer().privateCloudDatabase

        do {
            // 2. 从 CloudKit 私有库拉取所有自定义规则记录
            let predicate = NSPredicate(value: true)
            let query = CKQuery(recordType: Self.recordType, predicate: predicate)

            var remoteRecords: [CKRecord] = []
            var cursor: CKQueryOperation.Cursor? = nil

            repeat {
                let matchResults: ([(CKRecord.ID, Result<CKRecord, Error>)], CKQueryOperation.Cursor?)
                if let cur = cursor {
                    matchResults = try await db.records(continuingMatchFrom: cur)
                } else {
                    matchResults = try await db.records(matching: query)
                }

                for (_, result) in matchResults.0 {
                    remoteRecords.append(try result.get())
                }
                cursor = matchResults.1
            } while cursor != nil

            var remoteByID: [UUID: CKRecord] = [:]
            var incomingRules: [ActiveRuleItem] = []
            var remoteDeletions: [UUID: Date] = [:]
            for record in remoteRecords {
                guard let id = UUID(uuidString: record.recordID.recordName) else {
                    throw StoreError.invalidRule("iCloud 规则含无效标识。")
                }
                remoteByID[id] = record
                let updatedAt = revision(of: record)
                if isDeleted(record) {
                    remoteDeletions[id] = updatedAt
                } else {
                    guard let pattern = record["pattern"] as? String,
                          let actionName = record["action"] as? String,
                          let action = RuleActionType(rawValue: actionName) else {
                        throw StoreError.invalidRule("iCloud 规则缺少号码或动作。")
                    }
                    incomingRules.append(ActiveRuleItem(
                        id: id, pattern: pattern, action: action, label: record["label"] as? String,
                        createdAt: (record["createdAt"] as? Date) ?? updatedAt, updatedAt: updatedAt
                    ))
                }
            }

            let (pulled, deleted) = try store.applyCloudSyncChanges(
                incomingRules: incomingRules, deletedRuleIDs: [], remoteDeletions: remoteDeletions
            )

            var pending: [CKRecord] = []
            for rule in try store.getUserRules() where rule.count > 0 {
                if let existing = remoteByID[rule.id],
                   isDeleted(existing) || revision(of: existing) >= rule.updatedAt {
                    continue
                }
                let record = remoteByID[rule.id] ?? newRecord(rule.id)
                record["pattern"] = rule.pattern as CKRecordValue
                record["action"] = rule.action.rawValue as CKRecordValue
                record["label"] = rule.label.map { $0 as CKRecordValue }
                record["count"] = Int64(rule.count) as CKRecordValue
                record["createdAt"] = rule.createdAt as CKRecordValue
                record["updatedAt"] = rule.updatedAt as CKRecordValue
                record["isDeleted"] = Int64(0) as CKRecordValue
                pending.append(record)
            }

            for (id, deletedAt) in try store.getDeletedUserRuleRevisions() {
                if let existing = remoteByID[id], revision(of: existing) >= deletedAt, isDeleted(existing) {
                    continue
                }
                let record = remoteByID[id] ?? newRecord(id)
                record["isDeleted"] = Int64(1) as CKRecordValue
                record["updatedAt"] = deletedAt as CKRecordValue
                pending.append(record)
            }

            for offset in stride(from: 0, to: pending.count, by: 100) {
                let batch = Array(pending[offset..<min(offset + 100, pending.count)])
                try await save(batch, to: db)
            }
            let pushedCount = pending.count
            // Keep local tombstones so an older device or offline retry cannot reactivate an ID.
            try store.setMetadata(key: "last_icloud_sync_at", value: "\(Date().timeIntervalSince1970)")

            if pulled == 0 && deleted == 0 && pushedCount == 0 {
                return .upToDate
            } else {
                return .success(pulled: pulled, deleted: deleted, pushed: pushedCount)
            }
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        #else
        return .skipped(reason: "当前环境不支持 CloudKit")
        #endif
    }

    public func getLastSyncTime(in store: CallDirectoryStore) -> Date? {
        guard let str = try? store.getMetadata(key: "last_icloud_sync_at"),
              let ts = Double(str) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    #if canImport(CloudKit)
    private func newRecord(_ id: UUID) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: id.uuidString))
        record["id"] = id.uuidString as CKRecordValue
        return record
    }

    private func isDeleted(_ record: CKRecord) -> Bool {
        ((record["isDeleted"] as? Int64) ?? 0) != 0
    }

    private func revision(of record: CKRecord) -> Date {
        (record["updatedAt"] as? Date) ?? record.modificationDate ?? .distantPast
    }

    private func save(_ batch: [CKRecord], to database: CKDatabase) async throws {
        let operation = CKModifyRecordsOperation(recordsToSave: batch, recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { continuation.resume(with: $0) }
            database.add(operation)
        }
    }

    private static var hasRuntimeCloudKitEntitlements: Bool {
        hasRequiredCloudKitEntitlements(
            containerIdentifiers: currentEntitlementValues(
                for: "com.apple.developer.icloud-container-identifiers"
            ),
            services: currentEntitlementValues(for: "com.apple.developer.icloud-services")
        )
    }

    /// `CKContainer` fatally traps (`SIGTRAP`) when the CloudKit container is
    /// missing from the profile, so this must not fall back to initializing CloudKit.
    private static func currentEntitlementValues(for key: String) -> [String] {
        SignedEntitlements.values(for: key)
    }

    private func getContainer() -> CKContainer {
        return CKContainer(identifier: Self.containerIdentifier)
    }
    #endif
}
