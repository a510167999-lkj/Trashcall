import Foundation
import SQLite3

/// Storage errors.
public enum StoreError: Error, LocalizedError {
    case cannotOpenDatabase(String)
    case executeFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case invalidRule(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase(let msg): return "无法打开数据库: \(msg)"
        case .executeFailed(let msg): return "执行 SQL 失败: \(msg)"
        case .prepareFailed(let msg): return "预编译 SQL 失败: \(msg)"
        case .stepFailed(let msg): return "步进读取数据失败: \(msg)"
        case .invalidRule(let msg): return msg
        }
    }
}

/// A high-performance, low-memory SQLite store shared between the Main App and the CallKit Extension via App Groups.
/// Designed specifically to stay well within CallKit's 15MB memory ceiling by providing streaming cursor access.
public final class CallDirectoryStore: @unchecked Sendable {
    private let dbURL: URL
    private var db: OpaquePointer?

    public init(databaseURL: URL) {
        self.dbURL = databaseURL
    }

    deinit {
        close()
    }

    public func open(readOnly: Bool = false, createIfNeeded: Bool = true) throws {
        var flags = SQLITE_OPEN_FULLMUTEX
        if readOnly {
            flags |= SQLITE_OPEN_READONLY
        } else {
            flags |= SQLITE_OPEN_READWRITE
            if createIfNeeded {
                flags |= SQLITE_OPEN_CREATE
            }
        }

        let status = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        guard status == SQLITE_OK else {
            let errorMsg = String(cString: sqlite3_errmsg(db))
            close()
            throw StoreError.cannotOpenDatabase(errorMsg)
        }

        // The main app and the CallKit extension share this database across process
        // boundaries. Without a busy handler, BEGIN EXCLUSIVE fails immediately with
        // SQLITE_BUSY under contention (e.g. toggling a strategy while the extension
        // streams the catalogue). Wait up to 3s instead of failing instantly.
        if let database = db {
            sqlite3_busy_timeout(database, 3000)
        }

        // Enable Write-Ahead Logging (WAL) for better concurrency between Main App and Extension
        if !readOnly {
            try execute(sql: "PRAGMA journal_mode = WAL;")
            try execute(sql: "PRAGMA synchronous = NORMAL;")
        }
    }

    public func close() {
        if let database = db {
            sqlite3_close_v2(database)
            db = nil
        }
    }

    public func initializeSchema() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS blocking_numbers (
            phone_number INTEGER PRIMARY KEY
        );

        CREATE TABLE IF NOT EXISTS identification_numbers (
            phone_number INTEGER PRIMARY KEY,
            label TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS supplemental_identifications (
            phone_number INTEGER PRIMARY KEY,
            label TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS user_rules (
            id TEXT PRIMARY KEY,
            pattern TEXT NOT NULL,
            action TEXT NOT NULL,
            label TEXT,
            count INTEGER NOT NULL,
            created_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT
        );

        CREATE TABLE IF NOT EXISTS user_blocking_numbers (
            phone_number INTEGER PRIMARY KEY
        );

        CREATE TABLE IF NOT EXISTS deleted_user_rules (
            id TEXT PRIMARY KEY,
            deleted_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS base_rule_numbers (
            phone_number INTEGER PRIMARY KEY,
            label TEXT
        );
        CREATE TABLE IF NOT EXISTS official_rule_numbers (
            slot INTEGER NOT NULL,
            phone_number INTEGER NOT NULL,
            label TEXT,
            PRIMARY KEY (slot, phone_number)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS user_rule_entries (
            rule_id TEXT NOT NULL,
            phone_number INTEGER NOT NULL,
            PRIMARY KEY (rule_id, phone_number)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS idx_rule_entries_phone ON user_rule_entries(phone_number);
        CREATE TABLE IF NOT EXISTS user_rule_revisions (
            id TEXT PRIMARY KEY,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_blocking_phone ON blocking_numbers(phone_number ASC);
        CREATE INDEX IF NOT EXISTS idx_identification_phone ON identification_numbers(phone_number ASC);
        CREATE INDEX IF NOT EXISTS idx_user_blocking_phone ON user_blocking_numbers(phone_number ASC);
        CREATE INDEX IF NOT EXISTS idx_deleted_user_rules_id ON deleted_user_rules(id ASC);
        """
        try execute(sql: schema)
    }

    public func execute(sql: String) throws {
        guard let database = db else {
            throw StoreError.cannotOpenDatabase("数据库未连接")
        }
        var errmsg: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errmsg)
        if status != SQLITE_OK {
            let msg = errmsg != nil ? String(cString: errmsg!) : "未知错误"
            sqlite3_free(errmsg)
            throw StoreError.executeFailed(msg)
        }
    }

    // MARK: - Batch Ingestion (Main App)

    public func replaceAll(
        blocking: [Int64],
        identifications: [IdentificationEntry],
        version: String
    ) throws {
        try execute(sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            try execute(sql: "DELETE FROM blocking_numbers;")
            try execute(sql: "DELETE FROM identification_numbers;")

            try insertBlockingBatch(blocking)
            try insertIdentificationBatch(identifications)

            let versionSql = "INSERT OR REPLACE INTO metadata (key, value) VALUES ('version', '\(version)');"
            try execute(sql: versionSql)

            try execute(sql: "COMMIT TRANSACTION;")
            checkpoint()
        } catch {
            try? execute(sql: "ROLLBACK TRANSACTION;")
            throw error
        }
    }

    public func insertBlockingBatch(_ numbers: [Int64]) throws {
        guard let database = db, !numbers.isEmpty else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO blocking_numbers (phone_number) VALUES (?);"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }

        for num in numbers {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, num)
            let step = sqlite3_step(stmt)
            if step != SQLITE_DONE {
                throw StoreError.stepFailed("插入号码失败: \(num)")
            }
        }
    }

    public func insertIdentificationBatch(_ entries: [IdentificationEntry]) throws {
        guard let database = db, !entries.isEmpty else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO identification_numbers (phone_number, label) VALUES (?, ?);"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for entry in entries {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, entry.phoneNumber)
            _ = entry.label.withCString { ptr in
                sqlite3_bind_text(stmt, 2, ptr, -1, SQLITE_TRANSIENT)
            }
            let step = sqlite3_step(stmt)
            if step != SQLITE_DONE {
                throw StoreError.stepFailed("插入识别信息失败: \(entry.phoneNumber)")
            }
        }
    }

    public func deleteBlockingBatch(_ numbers: [Int64]) throws {
        guard let database = db, !numbers.isEmpty else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM blocking_numbers WHERE phone_number = ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }

        for num in numbers {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, num)
            let step = sqlite3_step(stmt)
            if step != SQLITE_DONE {
                throw StoreError.stepFailed("删除号码失败: \(num)")
            }
        }
    }

    public func deleteIdentificationBatch(_ numbers: [Int64]) throws {
        guard let database = db, !numbers.isEmpty else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM identification_numbers WHERE phone_number = ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }

        for num in numbers {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, num)
            let step = sqlite3_step(stmt)
            if step != SQLITE_DONE {
                throw StoreError.stepFailed("删除识别号码失败: \(num)")
            }
        }
    }

    // MARK: - User Custom Rules Management

    public func getUserRules() throws -> [ActiveRuleItem] {
        guard let database = db else {
            throw StoreError.cannotOpenDatabase("数据库未连接")
        }
        var stmt: OpaquePointer?
        let sql = """
        SELECT u.id, u.pattern, u.action, u.label, u.count, u.created_at, COALESCE(r.updated_at, u.created_at)
        FROM user_rules u LEFT JOIN user_rule_revisions r ON r.id = u.id
        ORDER BY 7 DESC, u.id DESC;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }

        var rules: [ActiveRuleItem] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw StoreError.stepFailed(String(cString: sqlite3_errmsg(database))) }
            let idStr = String(cString: sqlite3_column_text(stmt, 0))
            let pattern = String(cString: sqlite3_column_text(stmt, 1))
            let actionRaw = String(cString: sqlite3_column_text(stmt, 2))
            let label: String?
            if let labelCStr = sqlite3_column_text(stmt, 3) {
                label = String(cString: labelCStr)
            } else {
                label = nil
            }
            let count = Int(sqlite3_column_int64(stmt, 4))
            let createdAtInterval = sqlite3_column_double(stmt, 5)

            guard let action = RuleActionType(rawValue: actionRaw), let uuid = UUID(uuidString: idStr) else {
                throw StoreError.invalidRule("自定义规则含无效标识或动作。")
            }
            let rule = ActiveRuleItem(
                id: uuid,
                pattern: pattern,
                action: action,
                label: label,
                count: count,
                createdAt: Date(timeIntervalSince1970: createdAtInterval),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            )
            rules.append(rule)
        }
        return rules
    }

    @discardableResult
    public func addUserRule(_ rule: ActiveRuleItem, numbers: [Int64]? = nil) throws -> ActiveRuleItem {
        let pattern = PatternInput.resolved(rule.pattern)
        let entries = try ruleNumbers(pattern: pattern, action: rule.action)
        return try rulesTransaction {
            let rebuilding = try prepareRuleSources()
            try startAffectedNumbers()
            let rules = try getUserRules()
            let key = ruleKey(pattern)
            let matching = rules.filter { ruleKey($0.pattern) == key }
            let existing = matching.first
            let saved = ActiveRuleItem(
                id: existing?.id ?? rule.id, pattern: pattern, action: rule.action,
                label: rule.label, count: entries.count, createdAt: existing?.createdAt ?? rule.createdAt,
                updatedAt: Date()
            )
            for duplicate in matching.dropFirst() {
                try removeUserRule(duplicate.id, deletedAt: saved.updatedAt)
            }
            try writeUserRule(saved, numbers: entries)
            try execute(sql: "DELETE FROM deleted_user_rules WHERE id = '\(saved.id.uuidString)';")
            try materializeRules(full: rebuilding)
            return saved
        }
    }

    public func deleteUserRule(id: UUID, pattern: String, action: RuleActionType, numbers: [Int64]) throws {
        try deleteUserRules(ids: [id])
    }

    public func deleteUserRules(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try rulesTransaction {
            let rebuilding = try prepareRuleSources()
            try startAffectedNumbers()
            let revision = Date()
            for id in ids { try removeUserRule(id, deletedAt: revision) }
            try materializeRules(full: rebuilding)
        }
    }

    public func getDeletedUserRuleIDs() throws -> [UUID] {
        Array(try getDeletedUserRuleRevisions().keys)
    }

    public func getDeletedUserRuleRevisions() throws -> [UUID: Date] {
        guard let database = db else { throw StoreError.cannotOpenDatabase("数据库未连接") }
        var deleted: [UUID: Date] = [:]
        try withStatement("SELECT id, deleted_at FROM deleted_user_rules;") { stmt in
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw StoreError.stepFailed(String(cString: sqlite3_errmsg(database))) }
                guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else {
                    throw StoreError.invalidRule("同步删除记录含无效标识。")
                }
                deleted[id] = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            }
        }
        return deleted
    }

    public func clearDeletedUserRule(id: UUID) throws {
        try execute(sql: "DELETE FROM deleted_user_rules WHERE id = '\(id.uuidString)';")
    }

    public func clearDeletedUserRules(olderThan: Date) throws {
        try execute(sql: "DELETE FROM deleted_user_rules WHERE deleted_at < \(olderThan.timeIntervalSince1970);")
    }

    @discardableResult
    public func applyCloudSyncChanges(
        incomingRules: [ActiveRuleItem],
        deletedRuleIDs: [UUID],
        remoteDeletions: [UUID: Date] = [:]
    ) throws -> (addedOrUpdated: Int, deleted: Int) {
        try rulesTransaction {
            let rebuilding = try prepareRuleSources()
            try startAffectedNumbers()
            var current = Dictionary(uniqueKeysWithValues: try getUserRules().map { ($0.id, $0) })
            var deleted = try getDeletedUserRuleRevisions()
            var changes = (addedOrUpdated: 0, deleted: 0)
            let deletions = remoteDeletions.merging(
                Dictionary(deletedRuleIDs.map { ($0, Date()) }, uniquingKeysWith: max), uniquingKeysWith: max
            )
            for (id, revision) in deletions {
                if let previous = deleted[id], previous >= revision { continue }
                try removeUserRule(id, deletedAt: revision)
                deleted[id] = revision
                if current.removeValue(forKey: id) != nil { changes.deleted += 1 }
            }

            let ordered = incomingRules.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
            for rule in ordered {
                // IDs retired by deletion or collision are never reused.
                if deleted[rule.id] != nil { continue }
                if let previous = current[rule.id], previous.updatedAt >= rule.updatedAt { continue }
                let numbers = try ruleNumbers(pattern: rule.pattern, action: rule.action)
                let key = ruleKey(rule.pattern)
                let duplicates = current.values.filter { $0.id != rule.id && ruleKey($0.pattern) == key }
                if let winner = duplicates.first(where: { ($0.updatedAt, $0.id.uuidString) > (rule.updatedAt, rule.id.uuidString) }) {
                    try removeUserRule(rule.id, deletedAt: winner.updatedAt)
                    deleted[rule.id] = winner.updatedAt
                    if current.removeValue(forKey: rule.id) != nil { changes.deleted += 1 }
                    continue
                }
                for duplicate in duplicates {
                    try removeUserRule(duplicate.id, deletedAt: rule.updatedAt)
                    deleted[duplicate.id] = rule.updatedAt
                    current.removeValue(forKey: duplicate.id)
                    changes.deleted += 1
                }
                try writeUserRule(rule, numbers: numbers)
                current[rule.id] = rule
                changes.addedOrUpdated += 1
            }

            if rebuilding || changes.addedOrUpdated > 0 || changes.deleted > 0 {
                try materializeRules(full: rebuilding)
            }
            return changes
        }
    }

    func applyOfficialRules(_ update: RemoteDatabaseUpdate) throws {
        try rulesTransaction {
            _ = try prepareRuleSources()
            let current = try getMetadata(key: "cloud_rules_version")
            if !update.isSnapshot, update.baseVersion == nil || update.baseVersion != current {
                throw StoreError.invalidRule("增量规则的基准版本不匹配，请等待完整规则库。")
            }
            if current != update.version {
                try execute(sql: """
                    DELETE FROM official_rule_numbers WHERE slot = 1;
                    INSERT INTO official_rule_numbers SELECT 1, phone_number, label FROM official_rule_numbers WHERE slot = 0;
                    """)
                try setMetadata(key: "previous_cloud_rules_version", value: current ?? "")
            }
            if update.isSnapshot {
                try execute(sql: "DELETE FROM official_rule_numbers WHERE slot = 0;")
            }

            for (numbers, predicate) in [(update.removedBlocking, "(label IS NULL OR label = '待核验外呼号段')"), (update.removedIdentifications, "label IS NOT NULL")] {
                try withStatement("DELETE FROM official_rule_numbers WHERE slot = 0 AND phone_number = ? AND \(predicate);") { stmt in
                    for number in numbers ?? [] {
                        sqlite3_bind_int64(stmt, 1, number)
                        try stepWrite(stmt)
                    }
                }
            }
            try withStatement("INSERT OR REPLACE INTO official_rule_numbers VALUES (0, ?, ?);") { stmt in
                for entry in update.addedIdentifications ?? [] {
                    sqlite3_bind_int64(stmt, 1, entry.phone)
                    bind(entry.label, to: 2, in: stmt)
                    try stepWrite(stmt)
                }
                for number in update.addedBlocking ?? [] {
                    sqlite3_bind_int64(stmt, 1, number)
                    bind(update.permitsBlocking ? nil : "待核验外呼号段", to: 2, in: stmt)
                    try stepWrite(stmt)
                }
            }
            try setMetadata(key: "cloud_rules_version", value: update.version)
            try setMetadata(key: "cloud_rule_sources_confirmed", value: "1")
            try setMetadata(key: "withdrawn_cloud_rules_version", value: "")
            try setMetadata(key: "last_update_check_at", value: "\(Date().timeIntervalSince1970)")
            try materializeRules(full: true)
        }
    }

    public func rollbackOfficialRules() throws -> String {
        try rulesTransaction {
            _ = try prepareRuleSources()
            guard let current = try getMetadata(key: "cloud_rules_version"), !current.isEmpty else {
                throw StoreError.invalidRule("没有可回滚的官方规则版本。")
            }
            let previous = try getMetadata(key: "previous_cloud_rules_version") ?? ""
            try execute(sql: """
                DELETE FROM official_rule_numbers WHERE slot = 0;
                UPDATE official_rule_numbers SET slot = 0 WHERE slot = 1;
                """)
            try setMetadata(key: "cloud_rules_version", value: previous)
            try setMetadata(key: "previous_cloud_rules_version", value: "")
            try setMetadata(key: "withdrawn_cloud_rules_version", value: current)
            try materializeRules(full: true)
            return previous
        }
    }

    func installBundledSeed(_ seed: CallDirectoryStore, version: String, count: String) throws {
        try rulesTransaction {
            let rebuilding = try prepareRuleSources()
            let current = try getVersion()
            let currentCount = try getMetadata(key: "identification_count")
            let installed = try getMetadata(key: "bundled_source_ready") == "1"
            let currentSupplement = try getMetadata(key: "supplemental_identification_version") ?? ""
            let nextSupplement = try seed.getMetadata(key: "supplemental_identification_version") ?? ""
            if currentSupplement != nextSupplement {
                try execute(sql: "DELETE FROM supplemental_identifications;")
                if !nextSupplement.isEmpty {
                    try importBundledIdentifications(from: seed, table: "supplemental_identifications",
                                                     into: "supplemental_identifications")
                }
                try setMetadata(key: "supplemental_identification_version", value: nextSupplement)
            }
            if !installed || current != version || currentCount != count {
                // Retain legacy labels outside the bundled catalogue while offline. A server snapshot owns their removal.
                let legacyVersion = try getMetadata(key: "cloud_rules_version") ?? ""
                let preserveLegacyCloudLabels = !installed && !legacyVersion.isEmpty
                if preserveLegacyCloudLabels {
                    try execute(sql: """
                        CREATE TEMP TABLE legacy_cloud_labels AS
                        SELECT phone_number, label FROM base_rule_numbers WHERE label IS NOT NULL;
                        """)
                }
                try execute(sql: "DELETE FROM base_rule_numbers WHERE label IS NOT NULL;")
                try importBundledIdentifications(from: seed, table: "identification_numbers",
                                                 into: "base_rule_numbers")
                if preserveLegacyCloudLabels {
                    try execute(sql: """
                        INSERT OR IGNORE INTO official_rule_numbers
                        SELECT 0, phone_number, label FROM legacy_cloud_labels
                        WHERE phone_number NOT IN (SELECT phone_number FROM base_rule_numbers);
                        DROP TABLE legacy_cloud_labels;
                        DELETE FROM metadata WHERE key = 'last_update_check_at';
                        """)
                }
                try setMetadata(key: "version", value: version)
                try setMetadata(key: "identification_count", value: count)
                try setMetadata(key: "bundled_source_ready", value: "1")
                try materializeRules(full: true)
            } else if rebuilding {
                try materializeRules(full: true)
            } else if currentSupplement != nextSupplement {
                try setMetadata(key: "directory_revision", value: UUID().uuidString)
            }
        }
    }

    private func importBundledIdentifications(from seed: CallDirectoryStore, table: String, into target: String) throws {
        try withStatement("INSERT OR REPLACE INTO \(target) VALUES (?, ?);") { stmt in
            try seed.streamIdentificationRows(from: table) { entry in
                sqlite3_bind_int64(stmt, 1, entry.phoneNumber)
                bind(entry.label, to: 2, in: stmt)
                try stepWrite(stmt)
            }
        }
    }

    public func isHighRiskAutoBlockEnabled() -> Bool {
        (try? getMetadata(key: "auto_block_high_risk")) == "true"
    }

    public func setHighRiskAutoBlock(enabled: Bool) throws {
        try rulesTransaction {
            _ = try prepareRuleSources()
            try setMetadata(key: "auto_block_high_risk", value: enabled ? "true" : "false")
            try materializeRules(full: true)
        }
    }

    private func rulesTransaction<T>(_ operation: () throws -> T) throws -> T {
        try execute(sql: "BEGIN IMMEDIATE;")
        do {
            let value = try operation()
            try execute(sql: "COMMIT;")
            return value
        } catch {
            try? execute(sql: "ROLLBACK;")
            throw error
        }
    }

    private func prepareRuleSources() throws -> Bool {
        guard try getMetadata(key: "rule_sources_ready") != "1" else { return false }
        let rules = try getUserRules()
        try startAffectedNumbers()
        for rule in rules {
            let numbers = (try? ruleNumbers(pattern: rule.pattern, action: rule.action)) ?? []
            try writeUserRule(rule, numbers: numbers)
        }
        let migratedBlocks = (try getMetadata(key: "cloud_rules_version") ?? "").isEmpty
            ? "INSERT OR IGNORE INTO base_rule_numbers SELECT phone_number, NULL" :
              "INSERT OR IGNORE INTO official_rule_numbers SELECT 0, phone_number, '待核验外呼号段'"
        try execute(sql: """
            INSERT OR IGNORE INTO base_rule_numbers SELECT phone_number, label FROM identification_numbers
            WHERE phone_number NOT IN (SELECT phone_number FROM user_rule_entries);
            \(migratedBlocks) FROM blocking_numbers
            WHERE phone_number NOT IN (SELECT phone_number FROM user_blocking_numbers)
              AND phone_number NOT IN (SELECT phone_number FROM user_rule_entries);
            """)
        try setMetadata(key: "rule_sources_ready", value: "1")
        return true
    }

    private func ruleNumbers(pattern: String, action: RuleActionType) throws -> [Int64] {
        let resolved = PatternInput.resolved(pattern)
        if action == .allow, resolved.contains(where: { $0 == "*" || $0 == "?" }) {
            throw StoreError.invalidRule("允许来电需要输入完整号码。")
        }
        return try RuleExpander().expandWildcard(resolved).map(\.rawValue)
    }

    private func ruleKey(_ pattern: String) -> String {
        let canonical = PatternInput.resolved(pattern)
        if canonical.contains(where: { $0 == "*" || $0 == "?" }) {
            let zero = canonical.replacingOccurrences(of: "?", with: "*")
            let suffix = zero.filter { $0 == "*" }.count
            let start = zero.replacingOccurrences(of: "*", with: "0")
            return PhoneNumber.normalize(start).map { "\($0.rawValue)/\(suffix)" } ?? canonical
        }
        return PhoneNumber.normalize(canonical).map { String($0.rawValue) } ?? canonical
    }

    private func startAffectedNumbers() throws {
        try execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS affected_rule_numbers (phone_number INTEGER PRIMARY KEY);
            DELETE FROM affected_rule_numbers;
            """)
    }

    private func removeUserRule(_ id: UUID, deletedAt: Date) throws {
        try affectRuleEntries(id)
        try execute(sql: """
            DELETE FROM user_rule_entries WHERE rule_id = '\(id.uuidString)';
            DELETE FROM user_rule_revisions WHERE id = '\(id.uuidString)';
            DELETE FROM user_rules WHERE id = '\(id.uuidString)';
            INSERT INTO deleted_user_rules VALUES ('\(id.uuidString)', \(deletedAt.timeIntervalSince1970))
            ON CONFLICT(id) DO UPDATE SET deleted_at = MAX(deleted_at, excluded.deleted_at);
            """)
    }

    private func affectRuleEntries(_ id: UUID) throws {
        try execute(sql: """
            INSERT OR IGNORE INTO affected_rule_numbers
            SELECT phone_number FROM user_rule_entries WHERE rule_id = '\(id.uuidString)';
            """)
    }

    private func writeUserRule(_ rule: ActiveRuleItem, numbers: [Int64]) throws {
        try affectRuleEntries(rule.id)
        try withStatement("INSERT OR REPLACE INTO user_rules VALUES (?, ?, ?, ?, ?, ?);") { stmt in
            bind(rule.id.uuidString, to: 1, in: stmt)
            bind(rule.pattern, to: 2, in: stmt)
            bind(rule.action.rawValue, to: 3, in: stmt)
            bind(rule.label, to: 4, in: stmt)
            sqlite3_bind_int64(stmt, 5, Int64(numbers.count))
            sqlite3_bind_double(stmt, 6, rule.createdAt.timeIntervalSince1970)
            try stepWrite(stmt)
        }
        try execute(sql: """
            INSERT OR REPLACE INTO user_rule_revisions VALUES ('\(rule.id.uuidString)', \(rule.updatedAt.timeIntervalSince1970));
            DELETE FROM user_rule_entries WHERE rule_id = '\(rule.id.uuidString)';
            """)
        try withStatement("INSERT OR IGNORE INTO user_rule_entries VALUES (?, ?);") { stmt in
            bind(rule.id.uuidString, to: 1, in: stmt)
            for number in numbers {
                sqlite3_bind_int64(stmt, 2, number)
                try stepWrite(stmt)
            }
        }
        try affectRuleEntries(rule.id)
    }

    private func materializeRules(full: Bool) throws {
        if full {
            try startAffectedNumbers()
            try execute(sql: """
                INSERT OR IGNORE INTO affected_rule_numbers SELECT phone_number FROM base_rule_numbers;
                INSERT OR IGNORE INTO affected_rule_numbers SELECT phone_number FROM official_rule_numbers WHERE slot = 0;
                INSERT OR IGNORE INTO affected_rule_numbers SELECT phone_number FROM user_rule_entries;
                DELETE FROM blocking_numbers;
                DELETE FROM identification_numbers;
                DELETE FROM user_blocking_numbers;
                """)
        } else {
            try execute(sql: """
                DELETE FROM blocking_numbers WHERE phone_number IN affected_rule_numbers;
                DELETE FROM identification_numbers WHERE phone_number IN affected_rule_numbers;
                DELETE FROM user_blocking_numbers WHERE phone_number IN affected_rule_numbers;
                """)
        }
        let block = RuleActionType.block.rawValue
        let identify = RuleActionType.identify.rawValue
        let allow = RuleActionType.allow.rawValue
        var strategyConditions = ProtectionStrategy.allCases.filter(isStrategyEnabled).map(\.conditionSQL)
        if isHighRiskAutoBlockEnabled() {
            strategyConditions.append("(phone_number BETWEEN 8695000000 AND 8695099999 OR phone_number BETWEEN 8695210000 AND 8695219999 OR phone_number BETWEEN 864000880000 AND 864000884999 OR phone_number BETWEEN 8617000000000 AND 8617000004999 OR phone_number BETWEEN 8617100000000 AND 8617100004999 OR label LIKE '%营销%' OR label LIKE '%推销%' OR label LIKE '%中介%')")
        }
        let strategyPredicate = strategyConditions.isEmpty ? "0" : strategyConditions.joined(separator: " OR ")
        try execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS resolved_rule_numbers (
                phone_number INTEGER PRIMARY KEY, label TEXT, is_blocked INTEGER NOT NULL, user_block INTEGER NOT NULL
            );
            DELETE FROM resolved_rule_numbers;
            WITH user_choices AS (
                SELECT e.phone_number, u.action, u.label,
                    ROW_NUMBER() OVER (
                        PARTITION BY e.phone_number
                        ORDER BY (u.action = '\(allow)') DESC, COALESCE(r.updated_at, u.created_at) DESC, u.id DESC
                    ) AS rank
                FROM affected_rule_numbers a JOIN user_rule_entries e USING (phone_number)
                JOIN user_rules u ON u.id = e.rule_id LEFT JOIN user_rule_revisions r ON r.id = u.id
            ), catalogue AS (
                SELECT a.phone_number, COALESCE(NULLIF(o.label, '待核验外呼号段'), b.label, o.label) AS label,
                    (o.phone_number IS NOT NULL AND o.label IS NULL)
                        OR (b.phone_number IS NOT NULL AND b.label IS NULL) AS catalogue_block
                FROM affected_rule_numbers a LEFT JOIN base_rule_numbers b USING (phone_number)
                LEFT JOIN official_rule_numbers o ON o.slot = 0 AND o.phone_number = a.phone_number
            ), defaults AS (
                SELECT phone_number, label, catalogue_block OR COALESCE((\(strategyPredicate)), 0) AND label IS NOT NULL AS blocked
                FROM catalogue
            )
            INSERT INTO resolved_rule_numbers
            SELECT d.phone_number,
                   CASE WHEN u.action = '\(identify)' THEN COALESCE(u.label, '自定义标记') ELSE d.label END,
                   CASE WHEN u.action IS NULL THEN d.blocked WHEN u.action = '\(block)' THEN 1 ELSE 0 END,
                   CASE WHEN u.action = '\(block)' THEN 1 ELSE 0 END
            FROM defaults d LEFT JOIN user_choices u ON u.phone_number = d.phone_number AND u.rank = 1;
            INSERT INTO blocking_numbers SELECT phone_number FROM resolved_rule_numbers WHERE is_blocked = 1;
            INSERT INTO identification_numbers SELECT phone_number, label FROM resolved_rule_numbers WHERE is_blocked = 0 AND label IS NOT NULL;
            INSERT INTO user_blocking_numbers SELECT phone_number FROM resolved_rule_numbers WHERE user_block = 1;
            """)
        try setMetadata(key: "directory_revision", value: UUID().uuidString)
    }

    private func withStatement(_ sql: String, _ operation: (OpaquePointer) throws -> Void) throws {
        guard let database = db else { throw StoreError.cannotOpenDatabase("数据库未连接") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try operation(statement)
    }

    private func bind(_ value: String?, to position: Int32, in stmt: OpaquePointer) {
        if let value {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = value.withCString { sqlite3_bind_text(stmt, position, $0, -1, transient) }
        } else {
            sqlite3_bind_null(stmt, position)
        }
    }

    private func stepWrite(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_reset(stmt)
    }

    // MARK: - Streaming Cursors for Extension (Constant O(1) Memory Usage)

    /// Streams all blocking numbers in strict ASCENDING order.
    /// This keeps memory consumption under 1MB even with millions of numbers.
    public func streamBlockingNumbers(batchSize: Int = 1000, handler: (Int64) throws -> Void) throws {
        guard let database = db else {
            throw StoreError.cannotOpenDatabase("数据库未连接")
        }
        var stmt: OpaquePointer?
        let sql = "SELECT phone_number FROM blocking_numbers ORDER BY phone_number ASC;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }

        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw StoreError.stepFailed(String(cString: sqlite3_errmsg(database))) }
            let phoneNumber = sqlite3_column_int64(stmt, 0)
            try handler(phoneNumber)
        }
    }

    /// Streams all identification entries in strict ASCENDING order.
    public func streamIdentificationEntries(handler: (IdentificationEntry) throws -> Void) throws {
        try streamIdentificationRows(from: identificationSource, handler: handler)
    }

    private var identificationSource: String {
        let supplemental = (try? getMetadata(key: "supplemental_identification_version")) ?? ""
        guard !supplemental.isEmpty else { return "identification_numbers" }
        return """
            (SELECT phone_number, label FROM identification_numbers
             UNION ALL
             SELECT s.phone_number, s.label FROM supplemental_identifications s
             WHERE NOT EXISTS (SELECT 1 FROM identification_numbers i WHERE i.phone_number = s.phone_number)
               AND NOT EXISTS (SELECT 1 FROM blocking_numbers b WHERE b.phone_number = s.phone_number))
            """
    }

    private func streamIdentificationRows(
        from table: String, handler: (IdentificationEntry) throws -> Void
    ) throws {
        guard let database = db else {
            throw StoreError.cannotOpenDatabase("数据库未连接")
        }
        var stmt: OpaquePointer?
        let sql = """
        SELECT phone_number, label FROM \(table)
        ORDER BY phone_number ASC;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }

        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw StoreError.stepFailed(String(cString: sqlite3_errmsg(database))) }
            let phoneNumber = sqlite3_column_int64(stmt, 0)
            let labelText: String
            if let cStr = sqlite3_column_text(stmt, 1) {
                labelText = String(cString: cStr)
            } else {
                labelText = "未知骚扰"
            }
            try handler(IdentificationEntry(phoneNumber: phoneNumber, label: labelText))
        }
    }

    public func getMetadata(key: String) throws -> String? {
        guard let database = db else { return nil }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM metadata WHERE key = ? LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                return String(cString: cStr)
            }
        }
        return nil
    }

    public func getVersion() throws -> String? {
        return try getMetadata(key: "version")
    }

    public func setMetadata(key: String, value: String) throws {
        guard let database = db else {
            throw StoreError.cannotOpenDatabase("数据库未连接")
        }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?);"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        _ = value.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw StoreError.stepFailed("写入 metadata 失败")
        }
    }

    public func convertBlockingToIdentification(defaultLabel: String = "骚扰电话") throws {
        // Escape single quotes so a label containing ' cannot break the SQL statement.
        let safeLabel = defaultLabel.replacingOccurrences(of: "'", with: "''")
        try execute(sql: """
        INSERT OR IGNORE INTO identification_numbers (phone_number, label)
        SELECT phone_number, '\(safeLabel)' FROM blocking_numbers;
        DELETE FROM blocking_numbers;
        DELETE FROM user_blocking_numbers;
        """)
        checkpoint()
    }

    public func importIdentifications(_ entries: [IdentificationEntry]) throws {
        let filtered = entries.filter { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        try insertIdentificationBatch(filtered)
        checkpoint()
    }

    public func clearAllBlocking() throws {
        try execute(sql: "DELETE FROM blocking_numbers; DELETE FROM user_blocking_numbers;")
        checkpoint()
    }

    public func countBlocking() -> Int {
        return queryCount(table: "blocking_numbers")
    }

    public func countIdentification() -> Int {
        return queryCount(table: identificationSource)
    }

    public func containsBlocking(_ number: Int64) -> Bool {
        return contains(table: "blocking_numbers", number: number)
    }

    public func containsUserBlocking(_ number: Int64) -> Bool {
        return contains(table: "user_blocking_numbers", number: number)
    }

    public func containsIdentification(_ number: Int64) -> Bool {
        return contains(table: identificationSource, number: number)
    }

    public func countUserBlocking() -> Int {
        return queryCount(table: "user_blocking_numbers")
    }

    public func insertUserBlockingBatch(_ numbers: [Int64]) throws {
        try insertPhoneNumbers(numbers, into: "user_blocking_numbers")
    }

    public func deleteUserBlockingBatch(_ numbers: [Int64]) throws {
        try deletePhoneNumbers(numbers, from: "user_blocking_numbers")
    }

    /// Streams only user-requested hang-up numbers, strictly ascending.
    public func streamUserBlockingNumbers(handler: (Int64) throws -> Void) throws {
        try streamPhoneNumbers(from: "user_blocking_numbers", handler: handler)
    }

    /// Flushes WAL into the main sqlite file so a read-only extension process can see new rows.
    public func checkpoint() {
        guard let database = db else { return }
        _ = sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    private func contains(table: String, number: Int64) -> Bool {
        guard let database = db else { return false }
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM \(table) WHERE phone_number = ? LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, number)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func queryCount(table: String) -> Int {
        guard let database = db else { return 0 }
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \(table);"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    private func insertPhoneNumbers(_ numbers: [Int64], into table: String) throws {
        guard let database = db, !numbers.isEmpty else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO \(table) (phone_number) VALUES (?);"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }
        for num in numbers {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, num)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw StoreError.stepFailed("插入号码失败: \(num)")
            }
        }
    }

    private func deletePhoneNumbers(_ numbers: [Int64], from table: String) throws {
        guard let database = db, !numbers.isEmpty else { return }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM \(table) WHERE phone_number = ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }
        for num in numbers {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, num)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw StoreError.stepFailed("删除号码失败: \(num)")
            }
        }
    }

    private func streamPhoneNumbers(from table: String, handler: (Int64) throws -> Void) throws {
        guard let database = db else {
            throw StoreError.cannotOpenDatabase("数据库未连接")
        }
        var stmt: OpaquePointer?
        let sql = "SELECT phone_number FROM \(table) ORDER BY phone_number ASC;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw StoreError.stepFailed(String(cString: sqlite3_errmsg(database))) }
            try handler(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - Preset Protection Strategies

    public func isStrategyEnabled(_ strategy: ProtectionStrategy) -> Bool {
        guard let database = db else { return false }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM metadata WHERE key = ? LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = strategy.id.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                return String(cString: cStr) == "true"
            }
        }
        return false
    }

    public func setStrategy(_ strategy: ProtectionStrategy, enabled: Bool) throws {
        try setStrategies([strategy], enabled: enabled)
    }

    public func setAllStrategies(enabled: Bool) throws {
        try setStrategies(ProtectionStrategy.allCases, enabled: enabled)
    }

    private func setStrategies(_ strategies: [ProtectionStrategy], enabled: Bool) throws {
        try rulesTransaction {
            let rebuilding = try prepareRuleSources()
            try startAffectedNumbers()
            for strategy in strategies {
                try setMetadata(key: strategy.id, value: enabled ? "true" : "false")
                try execute(sql: """
                    INSERT OR IGNORE INTO affected_rule_numbers SELECT phone_number FROM base_rule_numbers WHERE \(strategy.conditionSQL);
                    INSERT OR IGNORE INTO affected_rule_numbers SELECT phone_number FROM official_rule_numbers WHERE slot = 0 AND (\(strategy.conditionSQL));
                    """)
            }
            try materializeRules(full: rebuilding)
        }
    }

    // MARK: - Sandbox Number Diagnosis

    public func diagnose(input: String) -> NumberDiagnosticResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid(reason: "请输入电话号码或号段")
        }
        let entries = PhoneNumber.callKitEntries(trimmed)
        guard !entries.isEmpty else {
            return .invalid(reason: "无法解析为有效电话号码")
        }

        // 1. Check direct blocking
        for entry in entries {
            if containsBlocking(entry.rawValue) {
                // Check if matched by user rule
                if let userRules = try? getUserRules() {
                    for rule in userRules where rule.action == .block {
                        let forms = PhoneNumber.callKitEntries(rule.pattern).map(\.rawValue)
                        if forms.contains(entry.rawValue) || rule.pattern == trimmed {
                            return .blocked(reason: "命中自定义挂断规则: \(rule.pattern)")
                        }
                    }
                }
                return .blocked(reason: "命中系统高危自动挂断黑名单")
            }
        }

        // 2. Check direct identification
        guard let database = db else {
            return .notFound(normalized: entries.first?.description ?? trimmed)
        }
        let sql = "SELECT label FROM \(identificationSource) WHERE phone_number = ? LIMIT 1;"
        for entry in entries {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, entry.rawValue)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let label: String
                    if let cStr = sqlite3_column_text(stmt, 0) {
                        label = String(cString: cStr)
                    } else {
                        label = "已收录骚扰电话"
                    }
                    sqlite3_finalize(stmt)
                    return .identified(label: label)
                }
                sqlite3_finalize(stmt)
            }
        }

        return .notFound(normalized: entries.first?.description ?? trimmed)
    }
}

/// Represents the preset protection categories for one-touch blocking toggles.
public enum ProtectionStrategy: String, CaseIterable, Identifiable, Sendable {
    case block95 = "block_95"
    case block400 = "block_400"
    case blockMVNO = "block_mvno"
    case blockLandlines = "block_landlines"
    case blockOverseas = "block_overseas"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .block95: return "95 商业与金融号段"
        case .block400: return "400 电销推广号段"
        case .blockMVNO: return "167/170/171 虚拟运营商"
        case .blockLandlines: return "全国核心电销中介座机"
        case .blockOverseas: return "境外高危外呼 (+852/+886)"
        }
    }

    public var subtitle: String {
        switch self {
        case .block95: return "拦截 952/950/951/957 呼叫中心与金融推销"
        case .block400: return "拦截 4000 ~ 4009 全系商业推销外呼"
        case .blockMVNO: return "拦截 167/170/171/165/162 虚商电销卡"
        case .blockLandlines: return "拦截 北上广深 + 杭蓉汉渝 电销呼叫中心座机"
        case .blockOverseas: return "拦截 仿冒客服与境外 VoIP 诈骗高危来电"
        }
    }

    public var icon: String {
        switch self {
        case .block95: return "phone.down.waves.left.and.right"
        case .block400: return "shield.lefthalf.filled"
        case .blockMVNO: return "simcard.fill"
        case .blockLandlines: return "building.2.fill"
        case .blockOverseas: return "globe.asia.australia.fill"
        }
    }

    var conditionSQL: String {
        switch self {
        case .block95:
            return "(phone_number >= 8695000000 AND phone_number <= 8695999999)"
        case .block400:
            return "(phone_number >= 864000000000 AND phone_number <= 864009999999)"
        case .blockMVNO:
            return "((phone_number >= 8617000000000 AND phone_number <= 8617199999999) OR (phone_number >= 8616200000000 AND phone_number <= 8616799999999))"
        case .blockLandlines:
            return "((phone_number >= 862131000000 AND phone_number <= 862131019999) OR (phone_number >= 862151000000 AND phone_number <= 862151009999) OR (phone_number >= 862163500000 AND phone_number <= 862163509999) OR (phone_number >= 862180570000 AND phone_number <= 862180579999) OR (phone_number >= 861053000000 AND phone_number <= 861053019999) OR (phone_number >= 861056000000 AND phone_number <= 861056009999) OR (phone_number >= 8675533000000 AND phone_number <= 8675533019999) OR (phone_number >= 862038000000 AND phone_number <= 862038009999) OR (phone_number >= 8657126000000 AND phone_number <= 8657128029999) OR (phone_number >= 865526070000 AND phone_number <= 865526079999) OR (phone_number >= 862860000000 AND phone_number <= 862868009999) OR (phone_number >= 862787000000 AND phone_number <= 862787019999) OR (phone_number >= 862368000000 AND phone_number <= 862368029999))"
        case .blockOverseas:
            return "((phone_number >= 85200000000 AND phone_number <= 85299999999) OR (phone_number >= 886000000000 AND phone_number <= 886999999999))"
        }
    }

    var restoreDefaultLabel: String {
        switch self {
        case .block95: return "商业金融外呼 (95号段)"
        case .block400: return "商业推广外呼 (400号段)"
        case .blockMVNO: return "虚商高危电销卡"
        case .blockLandlines: return "推销中介座机"
        case .blockOverseas: return "境外高危外呼/可疑来电"
        }
    }
}

/// The result of diagnosing a phone number in the local CallKit database sandbox.
public enum NumberDiagnosticResult: Equatable, Sendable {
    case blocked(reason: String)
    case identified(label: String)
    case notFound(normalized: String)
    case invalid(reason: String)

    public var title: String {
        switch self {
        case .blocked: return "🚫 自动挂断拦截"
        case .identified: return "🏷️ 来电身份识别"
        case .notFound: return "⚪ 暂未收录号码"
        case .invalid: return "⚠️ 无效号码"
        }
    }

    public var message: String {
        switch self {
        case .blocked(let reason): return reason
        case .identified(let label): return "来电将显示标记: \(label)"
        case .notFound(let num): return "号码 \(num) 不在本地黑名单或黄页库中。建议配合开启系统「静音未知来电」。"
        case .invalid(let reason): return reason
        }
    }
}
