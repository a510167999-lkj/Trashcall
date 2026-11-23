import Foundation

/// Copies the bundled identification seed and applies versioned updates without wiping user rules.
public enum DatabaseBootstrap: Sendable {
    public static let preferredAppGroupId = "group.0294e79a001ad3e1.1"
    public static let databaseFileName = "trashcall.sqlite"

    /// App Group actually usable by this signed process. 全能签 often replaces
    /// `group.com.trashcall.shared`; if the resigner keeps one shared group on
    /// the app and both extensions, this still finds the live container.
    public static var appGroupId: String { resolvedAppGroupId }

    private static let resolvedAppGroupId: String = {
        let signed = SignedEntitlements.values(for: "com.apple.security.application-groups")
        var candidates: [String] = []
        for id in [preferredAppGroupId, "group.com.trashcall.shared"] + signed where !candidates.contains(id) {
            candidates.append(id)
        }
        for id in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil {
                return id
            }
        }
        return signed.first ?? preferredAppGroupId
    }()

    public static func run() {
        do { try prepareDatabase() }
        catch { print("Failed to initialize database: \(error.localizedDescription)") }
    }

    public static func prepareDatabase(
        at url: URL = databaseURL(), bundledSeed seedURL: URL? = bundledSeedURL()
    ) throws {
        let store = CallDirectoryStore(databaseURL: url)
        try store.open()
        defer { store.close() }
        try store.initializeSchema()
        if let seedURL { try applyBundledSeed(seedURL, to: store) }
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
        return migrateLegacyRootDatabaseIfNeeded(to: url)
    }

    public static func bundledSeedURL() -> URL? {
        if let url = Bundle.main.url(forResource: "seed_database", withExtension: "sqlite") {
            return url
        }
        let parentBundleURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if let parentBundle = Bundle(url: parentBundleURL),
           let url = parentBundle.url(forResource: "seed_database", withExtension: "sqlite") {
            return url
        }
        let directURL = parentBundleURL.appendingPathComponent("seed_database.sqlite")
        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }
        let repoSeed = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/seed_database.sqlite")
        if FileManager.default.fileExists(atPath: repoSeed.path) {
            return repoSeed
        }
        let cwdSeed = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("App/Resources/seed_database.sqlite")
        if FileManager.default.fileExists(atPath: cwdSeed.path) {
            return cwdSeed
        }
        return nil
    }

    private static func migrateLegacyRootDatabaseIfNeeded(to newURL: URL) -> URL {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return newURL }
        let fm = FileManager.default
        let oldURL = groupURL.appendingPathComponent(databaseFileName)
        guard fm.fileExists(atPath: oldURL.path), !fm.fileExists(atPath: newURL.path) else { return newURL }
        let temp = newURL.deletingLastPathComponent().appendingPathComponent(".legacy-\(UUID()).sqlite")
        defer { try? fm.removeItem(at: temp) }
        do {
            let legacy = CallDirectoryStore(databaseURL: oldURL)
            try legacy.open(readOnly: true)
            defer { legacy.close() }
            let path = temp.path.replacingOccurrences(of: "'", with: "''")
            try legacy.execute(sql: "VACUUM INTO '\(path)';")
            try fm.moveItem(at: temp, to: newURL)
        } catch {
            if !fm.fileExists(atPath: newURL.path) {
                print("Failed to migrate legacy database: \(error.localizedDescription)")
                return oldURL
            }
        }
        return newURL
    }

    private static func applyBundledSeed(_ seedURL: URL, to store: CallDirectoryStore) throws {
        let seed = CallDirectoryStore(databaseURL: seedURL)
        try seed.open(readOnly: true)
        defer { seed.close() }

        let version = try seed.getVersion() ?? "unknown"
        let count = try seed.getMetadata(key: "identification_count") ?? ""
        try store.installBundledSeed(seed, version: version, count: count)
    }

}
