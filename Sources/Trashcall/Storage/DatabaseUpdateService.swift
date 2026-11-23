import Foundation

#if canImport(CallKit)
import CallKit
#endif

public enum RemoteRulesFormat: String, Codable, Sendable {
    case snapshot
    case delta
}

/// Versioned official rule catalogue or a patch against a known version.
public struct RemoteDatabaseUpdate: Codable, Sendable {
    public let version: String
    public let format: RemoteRulesFormat?
    public let baseVersion: String?
    public let blockingVerified: Bool?
    public var permitsBlocking: Bool { blockingVerified == true }
    public var isSnapshot: Bool { format != .delta }
    public let updatedAt: String?
    public let description: String?
    public let minClientVersion: String?
    public let addedBlocking: [Int64]?
    public let removedBlocking: [Int64]?
    public let addedIdentifications: [RemoteIdentificationEntry]?
    public let removedIdentifications: [Int64]?

    enum CodingKeys: String, CodingKey {
        case version
        case format
        case baseVersion = "base_version"
        case blockingVerified = "blocking_verified"
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
        removedIdentifications: [Int64]? = nil,
        format: RemoteRulesFormat = .snapshot,
        baseVersion: String? = nil,
        blockingVerified: Bool = true
    ) {
        self.version = version
        self.format = format
        self.baseVersion = baseVersion
        self.blockingVerified = blockingVerified
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
    case deferred(reason: String)
    case savedPendingActivation(version: String, reason: String)

    public var isSuccess: Bool {
        switch self {
        case .upToDate, .updated: return true
        case .failed, .deferred, .savedPendingActivation: return false
        }
    }

    public var summaryMessage: String {
        switch self {
        case .upToDate(let version):
            return "数据库已是最新版本 (\(version))"
        case .updated(let version, let blocking, let ident):
            return "已自动更新至 \(version)（新增挂断 \(blocking) 条，识别 \(ident) 条）"
        case .failed(let reason):
            return "更新检查失败：\(reason)"
        case .deferred(let reason):
            return reason
        case .savedPendingActivation(let version, let reason):
            return "官方规则 \(version) 已保存，等待系统加载：\(reason)"
        }
    }
}

/// Service that handles automatic checking, downloading, and applying rules updates from Tencent Cloud.
public final class DatabaseUpdateService: @unchecked Sendable {
    public static let shared = DatabaseUpdateService()

    public static let defaultEndpointURLString = "https://agentslee.online/trashcall/rules_latest.json"

    private let checkGate = UpdateCheckGate()

    private init() {}

    private actor UpdateCheckGate {
        private var isRunning = false

        func enter() -> Bool {
            guard !isRunning else { return false }
            isRunning = true
            return true
        }

        func leave() { isRunning = false }
    }

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
        request.timeoutInterval = 30.0
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
        let blocked = update.addedBlocking ?? []
        let identified = update.addedIdentifications ?? []
        let allNumbers = blocked + identified.map(\.phone) + (update.removedBlocking ?? []) + (update.removedIdentifications ?? [])
        guard !update.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              allNumbers.allSatisfy({ (1_000_000...999_999_999_999_999).contains($0) }),
              identified.allSatisfy({ !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.label.contains("\0") }) else {
            throw StoreError.invalidRule("官方规则含无效的版本、号码或标签。")
        }
        if let minimum = update.minClientVersion,
           let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           installed.compare(minimum, options: .numeric) == .orderedAscending {
            throw StoreError.invalidRule("规则库要求 Trashcall \(minimum) 或更新版本。")
        }
        try store.applyOfficialRules(update)
        let blockingNumbers = Set(blocked)
        let identificationNumbers = Set(identified.map(\.phone))
        if update.permitsBlocking {
            return (blockingNumbers.count, identificationNumbers.subtracting(blockingNumbers).count)
        }
        return (0, identificationNumbers.union(blockingNumbers).count)
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
        guard await checkGate.enter() else { return .deferred(reason: "正在检查官方规则更新。") }
        let result = await runUpdateCheck(storeURL: storeURL, force: force, reloadExtensions: reloadExtensions)
        await checkGate.leave()
        return result
    }

    private func runUpdateCheck(
        storeURL: URL,
        force: Bool,
        reloadExtensions: (@Sendable () async -> [Error])?
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
        if !force, (try? store.getMetadata(key: "withdrawn_cloud_rules_version")) == remoteUpdate.version {
            try? store.setMetadata(key: "last_update_check_at", value: "\(Date().timeIntervalSince1970)")
            return .deferred(reason: "此版本已回滚。可手动检查以重新应用。")
        }
        if !force, currentVersion == remoteUpdate.version,
           (try? store.getMetadata(key: "cloud_rule_sources_confirmed")) == "1" {
            try? store.setMetadata(key: "last_update_check_at", value: "\(Date().timeIntervalSince1970)")
            return .upToDate(version: remoteUpdate.version)
        }

        do {
            let (addedBlock, addedIdent) = try applyUpdate(remoteUpdate, to: store)
            // Reload CallKit extensions
            if let reloadExtensions {
                let errors = await reloadExtensions()
                if !errors.isEmpty {
                    return .savedPendingActivation(version: remoteUpdate.version,
                                                   reason: errors.map(\.localizedDescription).joined(separator: "；"))
                }
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
