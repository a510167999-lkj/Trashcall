import Foundation

/// Copies the bundled identification seed and applies versioned updates without wiping user rules.
public enum DatabaseBootstrap: Sendable {
    public static let appGroupId = "group.com.trashcall.shared"
    public static let databaseFileName = "trashcall.sqlite"

    public static func run() {
        setupDatabase(at: databaseURL())
    }

    public static var isUsingAppGroup: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) != nil
    }

    public static func supportDirectory() -> URL {
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) {
            let support = groupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            return support
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public static func databaseURL() -> URL {
        let url = supportDirectory().appendingPathComponent(databaseFileName)
        migrateLegacyRootDatabaseIfNeeded(to: url)
        return url
    }

    public static func bundledSeedURL() -> URL? {
        Bundle.main.url(forResource: "seed_database", withExtension: "sqlite")
    }

    private static func migrateLegacyRootDatabaseIfNeeded(to newURL: URL) {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return }
        let fm = FileManager.default
        let oldURL = groupURL.appendingPathComponent(databaseFileName)
        guard fm.fileExists(atPath: oldURL.path) else { return }
        if !fm.fileExists(atPath: newURL.path) {
            try? fm.moveItem(at: oldURL, to: newURL)
        }
        for suffix in ["-wal", "-shm"] {
            let oldSide = URL(fileURLWithPath: oldURL.path + suffix)
            let newSide = URL(fileURLWithPath: newURL.path + suffix)
            if fm.fileExists(atPath: oldSide.path), !fm.fileExists(atPath: newSide.path) {
                try? fm.moveItem(at: oldSide, to: newSide)
            } else {
                try? fm.removeItem(at: oldSide)
            }
        }
        if fm.fileExists(atPath: newURL.path) {
            try? fm.removeItem(at: oldURL)
        }
    }

    private static func setupDatabase(at url: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            removeSidecars(for: url)
            if let seedURL = bundledSeedURL() {
                try? fileManager.copyItem(at: seedURL, to: url)
            }
        }

        let store = CallDirectoryStore(databaseURL: url)
        do {
            try store.open()
            try store.initializeSchema()
            try applyBundledSeedIfNeeded(to: store)
            reapplyUserRules(store: store)
        } catch {
            print("Failed to initialize database: \(error.localizedDescription)")
        }
    }

    private static func applyBundledSeedIfNeeded(to store: CallDirectoryStore) throws {
        guard let seedURL = bundledSeedURL() else { return }
        let seed = CallDirectoryStore(databaseURL: seedURL)
        try seed.open(readOnly: true)
        defer { seed.close() }

        let seedVersion = (try? seed.getVersion()) ?? "unknown"
        let liveVersion = (try? store.getVersion()) ?? ""
        let seedCount = (try? seed.getMetadata(key: "identification_count")) ?? ""
        let liveCount = (try? store.getMetadata(key: "identification_count")) ?? ""
        let needsImport = seedVersion != liveVersion || seedCount != liveCount || (store.countIdentification() == 0 && store.countBlocking() == 0)
        guard needsImport else { return }

        // Clear existing seed identification entries so new categories are cleanly synced
        try store.execute(sql: "BEGIN EXCLUSIVE TRANSACTION;")
        do {
            try store.execute(sql: "DELETE FROM identification_numbers;")
            var buffer: [IdentificationEntry] = []
            buffer.reserveCapacity(5000)
            try seed.streamIdentificationEntries { entry in
                buffer.append(entry)
                if buffer.count >= 5000 {
                    try store.insertIdentificationBatch(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try store.insertIdentificationBatch(buffer)
                buffer.removeAll()
            }
            try store.execute(sql: "COMMIT TRANSACTION;")
            store.checkpoint()
        } catch {
            try? store.execute(sql: "ROLLBACK TRANSACTION;")
            throw error
        }

        try store.setMetadata(key: "version", value: seedVersion)
        if !seedCount.isEmpty {
            try store.setMetadata(key: "identification_count", value: seedCount)
        }

        // Re-apply any enabled strategies
        for strategy in ProtectionStrategy.allCases {
            if store.isStrategyEnabled(strategy) {
                try? store.setStrategy(strategy, enabled: true)
            }
        }

        // The seed import above can re-add numbers the user explicitly blocked.
        // Blocking and identification must stay mutually exclusive: a number present
        // in both tables produces a mixed duplicate entry, which iOS 26/27 handles
        // by dropping the blocking entry (call still rings). Remove the overlap.
        try? store.execute(sql: """
        DELETE FROM identification_numbers
        WHERE phone_number IN (SELECT phone_number FROM blocking_numbers);
        """)
        store.checkpoint()

        reapplyUserRules(store: store)
    }

    private static func reapplyUserRules(store: CallDirectoryStore) {
        guard let rules = try? store.getUserRules() else { return }
        let expander = RuleExpander()
        for rule in rules {
            let numbers = (try? expander.expandWildcard(rule.pattern).map(\.rawValue)) ?? []
            guard !numbers.isEmpty else { continue }
            try? store.addUserRule(rule, numbers: numbers)
        }
    }

    private static func removeSidecars(for url: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: url.path + "-wal")
        try? fileManager.removeItem(atPath: url.path + "-shm")
    }
}
