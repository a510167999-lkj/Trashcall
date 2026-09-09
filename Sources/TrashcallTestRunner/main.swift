import Foundation
import Trashcall

@MainActor
func runSuite() async {
    print("==================================================")
    print("🚀 Running Trashcall Core Verification Test Suite")
    print("==================================================")

    var passed = 0
    var failed = 0

    func test(_ name: String, block: () throws -> Void) {
        do {
            try block()
            print("  ✅ PASS: \(name)")
            passed += 1
        } catch {
            print("  ❌ FAIL: \(name) - \(error)")
            failed += 1
        }
    }

    // 1. PhoneNumber Normalization Tests
    test("PhoneNumber Normalization (Chinese Mobile & Landline)") {
        let n1 = PhoneNumber.normalize("+86 138-0013-8000")
        assert(n1?.rawValue == 8613800138000, "Expected 8613800138000, got \(String(describing: n1?.rawValue))")

        let n2 = PhoneNumber.normalize("13800138000", defaultCountryCode: 86)
        assert(n2?.rawValue == 8613800138000, "Expected 8613800138000, got \(String(describing: n2?.rawValue))")

        let n3 = PhoneNumber.normalize("0086 13800138000")
        assert(n3?.rawValue == 8613800138000, "Expected 8613800138000, got \(String(describing: n3?.rawValue))")

        let n4 = PhoneNumber.normalize("010-88889999", defaultCountryCode: 86)
        assert(n4?.rawValue == 861088889999, "Expected 861088889999, got \(String(describing: n4?.rawValue))")

        let invalid = PhoneNumber.normalize("abc")
        assert(invalid == nil, "Invalid string must return nil")

        let custom = PhoneNumber.normalize("18964046784")
        assert(custom?.rawValue == 8618964046784, "Expected 8618964046784, got \(String(describing: custom?.rawValue))")
        let customPlus = PhoneNumber.normalize("+86 189 6404 6784")
        assert(customPlus?.rawValue == 8618964046784)

        let callKitForms = PhoneNumber.callKitEntries("18964046784")
        let formSet = Set(callKitForms.map(\.rawValue))
        assert(
            formSet == [18964046784, 8618964046784],
            "WHY: CN incoming calls are often presented without 86; both forms must be indexed. Got \(formSet)"
        )
    }

    // 2. RuleExpander Tests
    test("RuleExpander Wildcard & Bound Protection") {
        let expander = RuleExpander(maxAllowedNumbersPerRule: 2_000)

        // Expand 95211*** (1,000 numbers)
        let numbers = try expander.expandWildcard("95211***", defaultCountryCode: 86)
        assert(numbers.count == 1000, "Expected 1000 numbers, got \(numbers.count)")
        assert(numbers.first?.rawValue == 8695211000, "First must be 8695211000")
        assert(numbers.last?.rawValue == 8695211999, "Last must be 8695211999")

        // Exceeding limit: 95****** (1,000,000 numbers > 2,000 limit)
        var caughtError = false
        do {
            _ = try expander.expandWildcard("95******", defaultCountryCode: 86)
        } catch RuleExpansionError.patternTooBroad {
            caughtError = true
        }
        assert(caughtError, "Must trigger patternTooBroad guard")
    }

    // 3. SortedSequenceValidator Tests
    test("SortedSequenceValidator Monotonic Invariants") {
        let validSequence: [Int64] = [100, 200, 300, 400]
        assert(SortedSequenceValidator.isStrictlyAscending(validSequence) == true)

        let invalidSequence: [Int64] = [100, 200, 200, 400] // duplicate
        assert(SortedSequenceValidator.isStrictlyAscending(invalidSequence) == false)

        let unsortedSequence: [Int64] = [300, 100, 200, 100, 400]
        let sanitized = SortedSequenceValidator.sanitizeAndSort(unsortedSequence)
        assert(sanitized == [100, 200, 300, 400], "Sanitized list must be deduplicated and strictly sorted")
    }

    // 4. IncrementalEngine Tests
    test("IncrementalEngine Diff Calculation") {
        let oldBlocking: Set<Int64> = [8613800000001, 8613800000002, 8613800000003]
        let newBlocking: Set<Int64> = [8613800000002, 8613800000003, 8613800000004]

        let (toRemove, toAdd) = IncrementalEngine.computeBlockingDiff(oldSet: oldBlocking, newSet: newBlocking)
        assert(toRemove == [8613800000001], "Expected 8613800000001 to be removed")
        assert(toAdd == [8613800000004], "Expected 8613800000004 to be added")

        let oldMap: [Int64: String] = [101: "广告", 102: "骚扰"]
        let newMap: [Int64: String] = [102: "高频诈骗", 103: "催收"]

        let (idRemove, idAdd) = IncrementalEngine.computeIdentificationDiff(oldMap: oldMap, newMap: newMap)
        // 101 removed, 102 label changed (remove old + add new), 103 added
        assert(idRemove == [101, 102], "101 and 102 must be removed")
        assert(idAdd.count == 2, "102 and 103 must be added")
        assert(idAdd.first?.phoneNumber == 102 && idAdd.first?.label == "高频诈骗")
    }

    // 5. SQLite Store & CallDirectoryFeeder Streaming Ingestion Test
    test("SQLite Store Batch Writing and Streaming Feeder") {
        let tempDir = FileManager.default.temporaryDirectory
        let dbFile = tempDir.appendingPathComponent("test_trashcall_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbFile) }

        let store = CallDirectoryStore(databaseURL: dbFile)
        try store.open()
        try store.initializeSchema()

        // Generate 2,000 numbers
        let testNumbers: [Int64] = (1...2000).map { Int64(8613800000000 + $0) }
        let testIdentifications: [IdentificationEntry] = (1...500).map {
            IdentificationEntry(phoneNumber: Int64(8695200000000 + $0), label: "骚扰标记 \($0)")
        }

        try store.replaceAll(blocking: testNumbers, identifications: testIdentifications, version: "2026.09.09.001")

        assert(store.countBlocking() == 2000, "Blocking count mismatch")
        assert(store.countIdentification() == 500, "Identification count mismatch")
        let version = try store.getVersion()
        assert(version == "2026.09.09.001", "Version mismatch")

        // Test CallDirectoryFeeder into MockCallDirectoryContext
        let mockContext = MockCallDirectoryContext()
        let feeder = CallDirectoryFeeder()
        try feeder.feedFullData(from: store, into: mockContext)

        assert(mockContext.addedBlocking.count == 2000, "MockContext should have received 2000 blocking numbers")
        assert(mockContext.addedIdentification.count == 500, "MockContext should have received 500 identification entries")
        assert(mockContext.isCompleted == true, "MockContext should have completed request")

        // Verify strictly ascending order in fed data
        assert(SortedSequenceValidator.isStrictlyAscending(mockContext.addedBlocking), "Emitted blocking numbers MUST be strictly ascending")
    }

    // 6. User Rules Persistence and Conflict Resolution Tests
    test("User Rules Persistence and Conflict Resolution") {
        let tempDir = FileManager.default.temporaryDirectory
        let dbFile = tempDir.appendingPathComponent("test_trashcall_rules_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbFile) }

        let store = CallDirectoryStore(databaseURL: dbFile)
        try store.open()
        try store.initializeSchema()

        let expander = RuleExpander()
        let numbers = try expander.expandWildcard("95211***").map { $0.rawValue }
        assert(numbers.count == 1000)

        let rule = ActiveRuleItem(
            pattern: "95211***",
            action: .identify,
            label: "营销号段",
            count: numbers.count
        )

        try store.addUserRule(rule, numbers: numbers)
        assert(store.countIdentification() == 1000, "Identification numbers should have been inserted")
        assert(store.countBlocking() == 0)

        let fetchedRules = try store.getUserRules()
        assert(fetchedRules.count == 1, "Should have 1 persisted rule")
        assert(fetchedRules.first?.pattern == "95211***")
        assert(fetchedRules.first?.action == .identify)

        try store.deleteUserRule(id: rule.id, pattern: rule.pattern, action: rule.action, numbers: numbers)
        assert(store.countIdentification() == 0, "Identification numbers should be cleaned up")
        let remainingRules = try store.getUserRules()
        assert(remainingRules.isEmpty, "User rules table should be empty")
    }

    test("User can store 18964046784; prefix 9521 expands without typed stars") {
        assert(PatternInput.resolved("9521") == "9521****", "WHY: prefix entry must not require manual asterisks")
        assert(PatternInput.resolved("18964046784") == "18964046784", "WHY: a complete mobile stays exact")
        assert(PatternInput.resolved("9521****") == "9521****")
        assert(PatternInput.resolved("400123") == "400123****")

        let expander = RuleExpander()
        let fromPrefix = try expander.expandWildcard("9521")
        let fromStars = try expander.expandWildcard("9521****")
        assert(fromPrefix.count == 10_000, "WHY: 9521 is the 9521**** 号段, got \(fromPrefix.count)")
        assert(fromPrefix.map(\.rawValue) == fromStars.map(\.rawValue))
        let prefixEstimate = try expander.estimateCount("9521")
        assert(prefixEstimate == 10_000)
        let exactForms = try expander.expandWildcard("18964046784").map(\.rawValue)
        assert(Set(exactForms) == [18964046784, 8618964046784])

        let tempDir = FileManager.default.temporaryDirectory
        let dbFile = tempDir.appendingPathComponent("test_trashcall_user_189_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbFile)
            try? FileManager.default.removeItem(atPath: dbFile.path + "-wal")
            try? FileManager.default.removeItem(atPath: dbFile.path + "-shm")
        }
        let store = CallDirectoryStore(databaseURL: dbFile)
        try store.open()
        try store.initializeSchema()
        try store.addUserRule(
            ActiveRuleItem(pattern: "18964046784", action: .identify, label: "测试", count: 2),
            numbers: exactForms
        )
        assert(store.containsIdentification(18964046784), "WHY: user-added 189 must persist in the live DB")
        assert(store.containsIdentification(8618964046784))
    }

    test("Legacy blocking converts to identification; seed import keeps explicitly sourced 189") {
        let tempDir = FileManager.default.temporaryDirectory
        let liveFile = tempDir.appendingPathComponent("test_live_\(UUID().uuidString).sqlite")
        let seedFile = tempDir.appendingPathComponent("test_seed_\(UUID().uuidString).sqlite")
        defer {
            for url in [liveFile, seedFile] {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(atPath: url.path + "-wal")
                try? FileManager.default.removeItem(atPath: url.path + "-shm")
            }
        }

        let live = CallDirectoryStore(databaseURL: liveFile)
        try live.open()
        try live.initializeSchema()
        try live.insertBlockingBatch([8695210001, 18964046784])
        try live.convertBlockingToIdentification(defaultLabel: "骚扰电话")
        assert(live.countBlocking() == 0)
        assert(live.containsIdentification(8695210001))
        assert(live.containsIdentification(18964046784), "WHY: 189 may exist in a live DB after conversion")

        let seed = CallDirectoryStore(databaseURL: seedFile)
        try seed.open()
        try seed.initializeSchema()
        try seed.replaceAll(
            blocking: [],
            identifications: [
                IdentificationEntry(phoneNumber: 8613800138000, label: "银行"),
                IdentificationEntry(phoneNumber: 18964046784, label: "explicit-seed")
            ],
            version: "seed-test"
        )
        var imported: [IdentificationEntry] = []
        try seed.streamIdentificationEntries { imported.append($0) }
        try live.importIdentifications(imported)
        assert(live.containsIdentification(8613800138000))
        assert(live.containsIdentification(18964046784), "WHY: seed may include 189 if explicitly sourced; default builder just omits it")
    }

    test("Identification-only feed clears leftover blocking") {
        let tempDir = FileManager.default.temporaryDirectory
        let dbFile = tempDir.appendingPathComponent("test_feed_id_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbFile)
            try? FileManager.default.removeItem(atPath: dbFile.path + "-wal")
            try? FileManager.default.removeItem(atPath: dbFile.path + "-shm")
        }
        let store = CallDirectoryStore(databaseURL: dbFile)
        try store.open()
        try store.initializeSchema()
        try store.insertIdentificationBatch([
            IdentificationEntry(phoneNumber: 8613800138000, label: "银行")
        ])
        let mock = MockCallDirectoryContext(isIncremental: true)
        mock.addBlockingEntry(withNextSequentialPhoneNumber: 1)
        try CallDirectoryFeeder().feed(kind: .identificationOnly, from: store, into: mock)
        assert(mock.addedBlocking.isEmpty)
        assert(mock.addedIdentification.map(\.phoneNumber) == [8613800138000])
    }

    print("==================================================")
    print("📊 Test Results: \(passed) passed, \(failed) failed")
    print("==================================================")

    if failed > 0 {
        exit(1)
    }
}

await runSuite()
