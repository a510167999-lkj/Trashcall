import Foundation
import SQLite3

/// Storage errors.
public enum StoreError: Error, LocalizedError {
    case cannotOpenDatabase(String)
    case executeFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase(let msg): return "无法打开数据库: \(msg)"
        case .executeFailed(let msg): return "执行 SQL 失败: \(msg)"
        case .prepareFailed(let msg): return "预编译 SQL 失败: \(msg)"
        case .stepFailed(let msg): return "步进读取数据失败: \(msg)"
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

        CREATE INDEX IF NOT EXISTS idx_blocking_phone ON blocking_numbers(phone_number ASC);
        CREATE INDEX IF NOT EXISTS idx_identification_phone ON identification_numbers(phone_number ASC);
        CREATE INDEX IF NOT EXISTS idx_user_blocking_phone ON user_blocking_numbers(phone_number ASC);
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
        let sql = "SELECT id, pattern, action, label, count, created_at FROM user_rules ORDER BY created_at DESC;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }

        var rules: [ActiveRuleItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
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

            let action = RuleActionType(rawValue: actionRaw) ?? .block
            let uuid = UUID(uuidString: idStr) ?? UUID()
            let rule = ActiveRuleItem(
                id: uuid,
                pattern: pattern,
                action: action,
                label: label,
                count: count,
                createdAt: Date(timeIntervalSince1970: createdAtInterval)
            )
            rules.append(rule)
        }
        return rules
    }

    public func addUserRule(_ rule: ActiveRuleItem, numbers: [Int64]) throws {
        guard let database = db else {
            throw StoreError.cannotOpenDatabase("数据库未连接")
        }
        try execute(sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO user_rules (id, pattern, action, label, count, created_at) VALUES (?, ?, ?, ?, ?, ?);"
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
            }
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = rule.id.uuidString.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            _ = rule.pattern.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            _ = rule.action.rawValue.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
            if let label = rule.label {
                _ = label.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int64(stmt, 5, Int64(rule.count))
            sqlite3_bind_double(stmt, 6, rule.createdAt.timeIntervalSince1970)

            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw StoreError.stepFailed("插入规则记录失败")
            }
            sqlite3_finalize(stmt)

            var staleStmt: OpaquePointer?
            let staleSql = "DELETE FROM user_rules WHERE pattern = ? AND id != ?;"
            guard sqlite3_prepare_v2(database, staleSql, -1, &staleStmt, nil) == SQLITE_OK else {
                throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
            }
            _ = rule.pattern.withCString { sqlite3_bind_text(staleStmt, 1, $0, -1, SQLITE_TRANSIENT) }
            _ = rule.id.uuidString.withCString { sqlite3_bind_text(staleStmt, 2, $0, -1, SQLITE_TRANSIENT) }
            if sqlite3_step(staleStmt) != SQLITE_DONE {
                sqlite3_finalize(staleStmt)
                throw StoreError.stepFailed("清理同号段旧规则失败")
            }
            sqlite3_finalize(staleStmt)

            if rule.action == .block {
                try insertBlockingBatch(numbers)
                try insertUserBlockingBatch(numbers)
                try deleteIdentificationBatch(numbers)
            } else {
                let label = rule.label ?? "自定义标记"
                let entries = numbers.map { IdentificationEntry(phoneNumber: $0, label: label) }
                try insertIdentificationBatch(entries)
                try deleteBlockingBatch(numbers)
                try deleteUserBlockingBatch(numbers)
            }

            try execute(sql: "COMMIT TRANSACTION;")
            checkpoint()
        } catch {
            try? execute(sql: "ROLLBACK TRANSACTION;")
            throw error
        }
    }

    public func deleteUserRule(id: UUID, pattern: String, action: RuleActionType, numbers: [Int64]) throws {
        guard let database = db else {
            throw StoreError.cannotOpenDatabase("数据库未连接")
        }
        try execute(sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            var stmt: OpaquePointer?
            let sql = "DELETE FROM user_rules WHERE id = ?;"
            guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
            }
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            _ = id.uuidString.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)

            if action == .block {
                try deleteBlockingBatch(numbers)
                try deleteUserBlockingBatch(numbers)
            } else {
                try deleteIdentificationBatch(numbers)
            }

            try execute(sql: "COMMIT TRANSACTION;")
            checkpoint()
        } catch {
            try? execute(sql: "ROLLBACK TRANSACTION;")
            throw error
        }
    }

    // MARK: - High Risk Telemarketing Strategy

    public func isHighRiskAutoBlockEnabled() -> Bool {
        guard let database = db else { return true }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM metadata WHERE key = 'auto_block_high_risk' LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return true }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                return String(cString: cStr) == "true"
            }
        }
        return true
    }

    public func setHighRiskAutoBlock(enabled: Bool) throws {
        try execute(sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            if enabled {
                // Move commercial telemarketing / fraud numbers from identification to blocking
                let moveSql = """
                INSERT OR IGNORE INTO blocking_numbers (phone_number)
                SELECT phone_number FROM identification_numbers
                WHERE (phone_number >= 8695000000 AND phone_number <= 8695099999)
                   OR (phone_number >= 8695210000 AND phone_number <= 8695219999)
                   OR (phone_number >= 864000880000 AND phone_number <= 864000884999)
                   OR (phone_number >= 8617000000000 AND phone_number <= 8617000004999)
                   OR (phone_number >= 8617100000000 AND phone_number <= 8617100004999)
                   OR label LIKE '%营销%' OR label LIKE '%推销%' OR label LIKE '%中介%';

                DELETE FROM identification_numbers
                WHERE (phone_number >= 8695000000 AND phone_number <= 8695099999)
                   OR (phone_number >= 8695210000 AND phone_number <= 8695219999)
                   OR (phone_number >= 864000880000 AND phone_number <= 864000884999)
                   OR (phone_number >= 8617000000000 AND phone_number <= 8617000004999)
                   OR (phone_number >= 8617100000000 AND phone_number <= 8617100004999)
                   OR label LIKE '%营销%' OR label LIKE '%推销%' OR label LIKE '%中介%';
                """
                try execute(sql: moveSql)
                try execute(sql: "INSERT OR REPLACE INTO metadata (key, value) VALUES ('auto_block_high_risk', 'true');")
            } else {
                // Move them back to identification
                let restoreSql = """
                INSERT OR REPLACE INTO identification_numbers (phone_number, label)
                SELECT phone_number,
                       CASE
                         WHEN phone_number >= 8695210000 AND phone_number <= 8695219999 THEN '高频营销推销 (9521号段)'
                         WHEN phone_number >= 8695000000 AND phone_number <= 8695099999 THEN '企业商业推销 (950号段)'
                         WHEN phone_number >= 864000880000 AND phone_number <= 864000884999 THEN '中介理财推销 (400号段)'
                         WHEN phone_number >= 8617000000000 AND phone_number <= 8617000004999 THEN '虚商营销外呼 (170号段)'
                         WHEN phone_number >= 8617100000000 AND phone_number <= 8617100004999 THEN '虚商营销外呼 (171号段)'
                         ELSE '商业营销/中介'
                       END
                FROM blocking_numbers
                WHERE (phone_number >= 8695000000 AND phone_number <= 8695099999)
                   OR (phone_number >= 8695210000 AND phone_number <= 8695219999)
                   OR (phone_number >= 864000880000 AND phone_number <= 864000884999)
                   OR (phone_number >= 8617000000000 AND phone_number <= 8617000004999)
                   OR (phone_number >= 8617100000000 AND phone_number <= 8617100004999);

                DELETE FROM blocking_numbers
                WHERE (phone_number >= 8695000000 AND phone_number <= 8695099999)
                   OR (phone_number >= 8695210000 AND phone_number <= 8695219999)
                   OR (phone_number >= 864000880000 AND phone_number <= 864000884999)
                   OR (phone_number >= 8617000000000 AND phone_number <= 8617000004999)
                   OR (phone_number >= 8617100000000 AND phone_number <= 8617100004999);
                """
                try execute(sql: restoreSql)
                try execute(sql: "INSERT OR REPLACE INTO metadata (key, value) VALUES ('auto_block_high_risk', 'false');")
            }
            try execute(sql: "COMMIT TRANSACTION;")
            checkpoint()
        } catch {
            try? execute(sql: "ROLLBACK TRANSACTION;")
            throw error
        }
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

        while sqlite3_step(stmt) == SQLITE_ROW {
            let phoneNumber = sqlite3_column_int64(stmt, 0)
            try handler(phoneNumber)
        }
    }

    /// Streams all identification entries in strict ASCENDING order.
    public func streamIdentificationEntries(handler: (IdentificationEntry) throws -> Void) throws {
        guard let database = db else {
            throw StoreError.cannotOpenDatabase("数据库未连接")
        }
        var stmt: OpaquePointer?
        let sql = """
        SELECT phone_number, label FROM identification_numbers
        ORDER BY phone_number ASC;
        """
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
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
        try execute(sql: """
        INSERT OR IGNORE INTO identification_numbers (phone_number, label)
        SELECT phone_number, '\(defaultLabel)' FROM blocking_numbers;
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
        return queryCount(table: "identification_numbers")
    }

    public func containsBlocking(_ number: Int64) -> Bool {
        return contains(table: "blocking_numbers", number: number)
    }

    public func containsUserBlocking(_ number: Int64) -> Bool {
        return contains(table: "user_blocking_numbers", number: number)
    }

    public func containsIdentification(_ number: Int64) -> Bool {
        return contains(table: "identification_numbers", number: number)
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
        while sqlite3_step(stmt) == SQLITE_ROW {
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
        try execute(sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            let cond = strategy.conditionSQL
            if enabled {
                // Move matching numbers from identification to blocking
                let moveSql = """
                INSERT OR IGNORE INTO blocking_numbers (phone_number)
                SELECT phone_number FROM identification_numbers
                WHERE \(cond);

                DELETE FROM identification_numbers
                WHERE \(cond);
                """
                try execute(sql: moveSql)
                let metaSql = "INSERT OR REPLACE INTO metadata (key, value) VALUES ('\(strategy.id)', 'true');"
                try execute(sql: metaSql)
            } else {
                // Move them back from blocking to identification
                let label = strategy.restoreDefaultLabel
                let restoreSql = """
                INSERT OR REPLACE INTO identification_numbers (phone_number, label)
                SELECT phone_number, '\(label)'
                FROM blocking_numbers
                WHERE \(cond);

                DELETE FROM blocking_numbers
                WHERE \(cond);
                """
                try execute(sql: restoreSql)
                let metaSql = "INSERT OR REPLACE INTO metadata (key, value) VALUES ('\(strategy.id)', 'false');"
                try execute(sql: metaSql)
            }
            try execute(sql: "COMMIT TRANSACTION;")
            checkpoint()
        } catch {
            try? execute(sql: "ROLLBACK TRANSACTION;")
            throw error
        }
    }

    public func setAllStrategies(enabled: Bool) throws {
        try execute(sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            for strategy in ProtectionStrategy.allCases {
                let cond = strategy.conditionSQL
                if enabled {
                    let moveSql = """
                    INSERT OR IGNORE INTO blocking_numbers (phone_number)
                    SELECT phone_number FROM identification_numbers
                    WHERE \(cond);

                    DELETE FROM identification_numbers
                    WHERE \(cond);
                    """
                    try execute(sql: moveSql)
                    let metaSql = "INSERT OR REPLACE INTO metadata (key, value) VALUES ('\(strategy.id)', 'true');"
                    try execute(sql: metaSql)
                } else {
                    let label = strategy.restoreDefaultLabel
                    let restoreSql = """
                    INSERT OR REPLACE INTO identification_numbers (phone_number, label)
                    SELECT phone_number, '\(label)'
                    FROM blocking_numbers
                    WHERE \(cond);

                    DELETE FROM blocking_numbers
                    WHERE \(cond);
                    """
                    try execute(sql: restoreSql)
                    let metaSql = "INSERT OR REPLACE INTO metadata (key, value) VALUES ('\(strategy.id)', 'false');"
                    try execute(sql: metaSql)
                }
            }
            try execute(sql: "COMMIT TRANSACTION;")
            checkpoint()
        } catch {
            try? execute(sql: "ROLLBACK TRANSACTION;")
            throw error
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
        for entry in entries {
            var stmt: OpaquePointer?
            let sql = "SELECT label FROM identification_numbers WHERE phone_number = ? LIMIT 1;"
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

        // 3. Check wildcard user rules
        if let userRules = try? getUserRules() {
            let expander = RuleExpander()
            for rule in userRules {
                if rule.pattern.contains("*") || rule.pattern.contains("?") {
                    if let expanded = try? expander.expandWildcard(rule.pattern) {
                        let expandedSet = Set(expanded.map(\.rawValue))
                        for entry in entries where expandedSet.contains(entry.rawValue) {
                            if rule.action == .block {
                                return .blocked(reason: "命中自定义号段挂断: \(rule.pattern)")
                            } else {
                                return .identified(label: rule.label ?? "自定义标记号段")
                            }
                        }
                    }
                }
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
            return "((phone_number >= 862131000000 AND phone_number <= 862131019999) OR (phone_number >= 862151000000 AND phone_number <= 862151009999) OR (phone_number >= 861053000000 AND phone_number <= 861053019999) OR (phone_number >= 861056000000 AND phone_number <= 861056009999) OR (phone_number >= 8675533000000 AND phone_number <= 8675533009999) OR (phone_number >= 862038000000 AND phone_number <= 862038009999) OR (phone_number >= 8657126000000 AND phone_number <= 8657128009999) OR (phone_number >= 862860000000 AND phone_number <= 862868009999) OR (phone_number >= 862787000000 AND phone_number <= 862787009999) OR (phone_number >= 862368000000 AND phone_number <= 862368009999))"
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
