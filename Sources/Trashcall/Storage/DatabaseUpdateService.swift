import Foundation

#if canImport(CallKit)
import CallKit
#endif

/// Lightweight remote database update payload representation.
public struct RemoteDatabaseUpdate: Codable, Sendable {
    public let version: String
    public let updatedAt: String?
    public let description: String?
    public let minClientVersion: String?
    public let addedBlocking: [Int64]?
    public let removedBlocking: [Int64]?
    public let addedIdentifications: [RemoteIdentificationEntry]?
    public let removedIdentifications: [Int64]?

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt = "updated_at"
        case description
        case minClientVersion = "min_client_version"
        case addedBlocking = "added_blocking"
        case removedBlocking = "removed_blocking"
        case addedIdentifications = "added_identifications"
        case removedIdentifications = "removed_identifications"
    }

    public init(
        version: String,
        updatedAt: String? = nil,
        description: String? = nil,
        minClientVersion: String? = nil,
        addedBlocking: [Int64]? = nil,
        removedBlocking: [Int64]? = nil,
        addedIdentifications: [RemoteIdentificationEntry]? = nil,
        removedIdentifications: [Int64]? = nil
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.description = description
        self.minClientVersion = minClientVersion
        self.addedBlocking = addedBlocking
        self.removedBlocking = removedBlocking
        self.addedIdentifications = addedIdentifications
        self.removedIdentifications = removedIdentifications
    }
}

public struct RemoteIdentificationEntry: Codable, Sendable {
    public let phone: Int64
    public let label: String

    public init(phone: Int64, label: String) {
        self.phone = phone
        self.label = label
    }
}

/// The result of an update check.
public enum UpdateResult: Sendable, Equatable {
    case upToDate(version: String)
    case updated(newVersion: String, addedBlocking: Int, addedIdentification: Int)
    case failed(reason: String)

    public var isSuccess: Bool {
        switch self {
        case .upToDate, .updated: return true
        case .failed: return false
        }
    }

    public var summaryMessage: String {
        switch self {
        case .upToDate(let version):
            return "数据库已是最新版本 (\(version))"
        case .updated(let version, let blocking, let ident):
            return "已自动更新至 \(version)（新增挂断 \(blocking) 条，识别 \(ident) 条）"
        case .failed(let reason):
            return "更新检查失败: \(reason)"
        }
    }
}

/// Service that handles automatic checking, downloading, and applying rules updates from Tencent Cloud.
public final class DatabaseUpdateService: @unchecked Sendable {
    public static let shared = DatabaseUpdateService()

    public static let defaultEndpointURLString = "https://agentslee.online/trashcall/rules_latest.json"

    private init() {}

    public func getEndpointURL(from store: CallDirectoryStore? = nil) -> URL {
        if let store = store,
           let custom = try? store.getMetadata(key: "cloud_update_url"),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = URL(string: custom) {
            return url
        }
        return URL(string: Self.defaultEndpointURLString)!
    }

    public func setEndpointURL(_ urlString: String, in store: CallDirectoryStore) throws {
        try store.setMetadata(key: "cloud_update_url", value: urlString)
    }

    public func isAutoUpdateEnabled(in store: CallDirectoryStore) -> Bool {
        return (try? store.getMetadata(key: "auto_update_enabled")) != "false"
    }

    public func setAutoUpdateEnabled(_ enabled: Bool, in store: CallDirectoryStore) throws {
        try store.setMetadata(key: "auto_update_enabled", value: enabled ? "true" : "false")
    }

    public func getLastCheckTime(in store: CallDirectoryStore) -> Date? {
        guard let str = try? store.getMetadata(key: "last_update_check_at"),
              let ts = Double(str) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    public func getCloudRulesVersion(in store: CallDirectoryStore) -> String? {
        return try? store.getMetadata(key: "cloud_rules_version")
    }

    /// Fetches remote update payload over network.
    public func fetchRemoteUpdate(from url: URL) async throws -> RemoteDatabaseUpdate {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12.0
        request.setValue("Trashcall-iOS", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "DatabaseUpdateService", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的网络响应"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "DatabaseUpdateService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "服务器返回 HTTP \(httpResponse.statusCode)"])
        }

        let decoder = JSONDecoder()
        return try decoder.decode(RemoteDatabaseUpdate.self, from: data)
    }

    /// Applies a remote update to the SQLite database transactionally.
    /// Preserves existing user rules and enabled protection strategies.
    @discardableResult
    public func applyUpdate(
        _ update: RemoteDatabaseUpdate,
        to store: CallDirectoryStore
    ) throws -> (addedBlock: Int, addedIdent: Int) {
        var addedBlockCount = 0
        var addedIdentCount = 0

        try store.execute(sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            // 1. Process removals
            if let removedBlocks = update.removedBlocking, !removedBlocks.isEmpty {
                try store.deleteBlockingBatch(removedBlocks)
            }
            if let removedIdents = update.removedIdentifications, !removedIdents.isEmpty {
                try store.deleteIdentificationBatch(removedIdents)
            }

            // 2. Process additions
            if let addedBlocks = update.addedBlocking, !addedBlocks.isEmpty {
                try store.insertBlockingBatch(addedBlocks)
                try store.deleteIdentificationBatch(addedBlocks)
                addedBlockCount = addedBlocks.count
            }

            if let addedIdents = update.addedIdentifications, !addedIdents.isEmpty {
                let entries = addedIdents.map { IdentificationEntry(phoneNumber: $0.phone, label: $0.label) }
                try store.insertIdentificationBatch(entries)
                addedIdentCount = entries.count
            }

            // 3. Keep blocking and identification mutually exclusive
            try store.execute(sql: """
            DELETE FROM identification_numbers
            WHERE phone_number IN (SELECT phone_number FROM blocking_numbers);
            """)

            // 4. Update metadata
            try store.setMetadata(key: "cloud_rules_version", value: update.version)
            try store.setMetadata(key: "last_update_check_at", value: "\(Date().timeIntervalSince1970)")

            // 5. Re-apply any enabled protection strategies so user choices remain intact
            for strategy in ProtectionStrategy.allCases {
                if store.isStrategyEnabled(strategy) {
                    let cond = strategy.conditionSQL
                    let moveSql = """
                    INSERT OR IGNORE INTO blocking_numbers (phone_number)
                    SELECT phone_number FROM identification_numbers
                    WHERE \(cond);
                    DELETE FROM identification_numbers
                    WHERE \(cond);
                    """
                    try store.execute(sql: moveSql)
                }
            }

            // 6. Re-apply user custom rules so personal blacklists are never overridden
            if let userRules = try? store.getUserRules() {
                let expander = RuleExpander()
                for rule in userRules {
                    let numbers = (try? expander.expandWildcard(rule.pattern).map(\.rawValue)) ?? []
                    guard !numbers.isEmpty else { continue }
                    if rule.action == .block {
                        try store.insertBlockingBatch(numbers)
                        try store.insertUserBlockingBatch(numbers)
                        try store.deleteIdentificationBatch(numbers)
                    } else {
                        let label = rule.label ?? "自定义标记"
                        let entries = numbers.map { IdentificationEntry(phoneNumber: $0, label: label) }
                        try store.insertIdentificationBatch(entries)
                        try store.deleteBlockingBatch(numbers)
                        try store.deleteUserBlockingBatch(numbers)
                    }
                }
            }

            try store.execute(sql: "COMMIT TRANSACTION;")
            store.checkpoint()
        } catch {
            try? store.execute(sql: "ROLLBACK TRANSACTION;")
            throw error
        }

        return (addedBlockCount, addedIdentCount)
    }

    /// Check and automatically perform an update.
    /// - Parameters:
    ///   - storeURL: The SQLite database URL (defaults to `DatabaseBootstrap.databaseURL()`).
    ///   - force: If true, ignores check throttling and forces re-applying update even if version matches.
    ///   - reloadExtensions: Optional closure to trigger CallKit reload upon successful update.
    public func checkAndUpdate(
        storeURL: URL = DatabaseBootstrap.databaseURL(),
        force: Bool = false,
        reloadExtensions: (@Sendable () async -> [Error])? = nil
    ) async -> UpdateResult {
        let store = CallDirectoryStore(databaseURL: storeURL)
        do {
            try store.open(readOnly: false)
            try store.initializeSchema()
        } catch {
            return .failed(reason: "打开本地数据库失败: \(error.localizedDescription)")
        }
        defer { store.close() }

        // Check if auto-update is enabled
        if !force && !isAutoUpdateEnabled(in: store) {
            let current = getCloudRulesVersion(in: store) ?? (try? store.getVersion()) ?? "本地预置"
            return .upToDate(version: current)
        }

        // Throttle check if !force (skip if checked less than 4 hours ago)
        if !force, let lastCheck = getLastCheckTime(in: store) {
            let elapsed = Date().timeIntervalSince(lastCheck)
            if elapsed < 4 * 3600 {
                let current = getCloudRulesVersion(in: store) ?? (try? store.getVersion()) ?? "本地预置"
                return .upToDate(version: current)
            }
        }

        let endpoint = getEndpointURL(from: store)
        let remoteUpdate: RemoteDatabaseUpdate
        do {
            remoteUpdate = try await fetchRemoteUpdate(from: endpoint)
        } catch {
            return .failed(reason: error.localizedDescription)
        }

        let currentVersion = getCloudRulesVersion(in: store)
        if !force && currentVersion == remoteUpdate.version {
            try? store.setMetadata(key: "last_update_check_at", value: "\(Date().timeIntervalSince1970)")
            return .upToDate(version: remoteUpdate.version)
        }

        do {
            let (addedBlock, addedIdent) = try applyUpdate(remoteUpdate, to: store)
            // Reload CallKit extensions
            if let reload = reloadExtensions {
                _ = await reload()
            }
            return .updated(
                newVersion: remoteUpdate.version,
                addedBlocking: addedBlock,
                addedIdentification: addedIdent
            )
        } catch {
            return .failed(reason: "应用数据库更新失败: \(error.localizedDescription)")
        }
    }
}
