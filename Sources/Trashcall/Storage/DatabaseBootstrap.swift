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
            try store.convertBlockingToIdentification()
            try store.clearAllBlocking()
            convertLegacyBlockRulesToIdentify(store: store)
            try applyBundledSeedIfNeeded(to: store)
            try store.clearAllBlocking()
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
        let needsImport = seedVersion != liveVersion || store.countIdentification() == 0
        guard needsImport else { return }

        var entries: [IdentificationEntry] = []
        try seed.streamIdentificationEntries { entry in
            entries.append(entry)
        }
        try seed.streamBlockingNumbers { number in
            entries.append(IdentificationEntry(phoneNumber: number, label: "骚扰电话"))
        }
        try store.importIdentifications(entries)
        try store.setMetadata(key: "version", value: seedVersion)
        reapplyUserIdentifyRules(store: store)
    }

    private static func convertLegacyBlockRulesToIdentify(store: CallDirectoryStore) {
        guard let rules = try? store.getUserRules() else { return }
        let expander = RuleExpander()
        for rule in rules {
            guard rule.action == .block else { continue }
            let numbers = (try? expander.expandWildcard(rule.pattern).map(\.rawValue)) ?? []
            var updated = rule
            updated.action = .identify
            updated.label = rule.label ?? "自定义标记"
            updated.count = numbers.count
            try? store.addUserRule(updated, numbers: numbers)
        }
    }

    private static func reapplyUserIdentifyRules(store: CallDirectoryStore) {
        guard let rules = try? store.getUserRules() else { return }
        let expander = RuleExpander()
        for rule in rules {
            let numbers = (try? expander.expandWildcard(rule.pattern).map(\.rawValue)) ?? []
            guard !numbers.isEmpty else { continue }
            var identify = rule
            identify.action = .identify
            identify.label = rule.label ?? "自定义标记"
            try? store.addUserRule(identify, numbers: numbers)
        }
    }

    private static func removeSidecars(for url: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: url.path + "-wal")
        try? fileManager.removeItem(atPath: url.path + "-shm")
    }
}
