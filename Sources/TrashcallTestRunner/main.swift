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

        // Expand 95211*** (national 95211000-95211999 + E.164 8695211000-8695211999)
        let numbers = try expander.expandWildcard("95211***", defaultCountryCode: 86)
        assert(numbers.count == 2000, "Expected 2000 numbers (dual form), got \(numbers.count)")
        assert(numbers.first?.rawValue == 95211000, "First must be national form 95211000, got \(String(describing: numbers.first?.rawValue))")
        assert(numbers.last?.rawValue == 8695211999, "Last must be E.164 form 8695211999")

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
        assert(numbers.count == 2000, "Dual form: national + E.164, got \(numbers.count)")

        let rule = ActiveRuleItem(
            pattern: "95211***",
            action: .identify,
            label: "营销号段",
            count: numbers.count
        )

        try store.addUserRule(rule, numbers: numbers)
        assert(store.countIdentification() == 2000, "Identification numbers should have been inserted (dual form)")
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
        // Mobile prefix gap of 5 should pad to the full 11-digit national length
        assert(PatternInput.resolved("192804") == "192804*****", "WHY: mobile prefixes must reach 11 digits")
        // Too-short prefix must NOT mispad; expander should reject explicitly
        assert(PatternInput.resolved("95") == "95", "WHY: 6-digit gap on 95 would mispad to a 6-digit range that matches no real number")
        assert(PatternInput.resolved("13") == "13")

        let expander = RuleExpander()
        let fromPrefix = try expander.expandWildcard("9521")
        let fromStars = try expander.expandWildcard("9521****")
        assert(fromPrefix.count == 20_000, "WHY: dual-form 9521 covers 10k national + 10k E.164, got \(fromPrefix.count)")
        assert(fromPrefix.map(\.rawValue) == fromStars.map(\.rawValue))
        let prefixEstimate = try expander.estimateCount("9521")
        assert(prefixEstimate == 20_000)
        let exactForms = try expander.expandWildcard("18964046784").map(\.rawValue)
        assert(Set(exactForms) == [18964046784, 8618964046784])

        // Mobile segment rules must include BOTH the 11-digit national range AND
        // the 13-digit E.164 range so calls presented without the country code still match.
        let segment = try expander.expandWildcard("192804").map(\.rawValue)
        assert(segment.count == 200_000, "WHY: 192804 should cover 100k national + 100k E.164, got \(segment.count)")
        assert(segment.contains(19280412345), "WHY: a 11-digit national 192804xxxxx number must be inside the registered range")
        assert(segment.contains(8619280412345), "WHY: a 13-digit E.164 86192804xxxxx number must be inside the registered range")
        assert(segment.first == 19280400000)
        assert(segment.last == 8619280499999)

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

    test("Blocking-only and identification-only feeds are homogeneous (iOS 26/27 mixed-request suppression)") {
        // WHY: iOS 26/27 drops addBlockingEntry when the same request also carries
        // identification entries. The production split is identify-ext = .identificationOnly
        // and block-ext = .blockingOnly; neither request may ever mix the two kinds.
        let tempDir = FileManager.default.temporaryDirectory
        let dbFile = tempDir.appendingPathComponent("test_feed_split_\(UUID().uuidString).sqlite")
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
        try store.insertBlockingBatch([8618964046784, 18964046784])

        let blockMock = MockCallDirectoryContext()
        try CallDirectoryFeeder().feed(kind: .blockingOnly, from: store, into: blockMock)
        assert(blockMock.addedBlocking == [18964046784, 8618964046784], "block feed must carry every blocking number, ascending")
        assert(blockMock.addedIdentification.isEmpty, "WHY: a mixed request gets its blocking entries dropped on iOS 26/27")
        assert(blockMock.isCompleted)

        let identifyMock = MockCallDirectoryContext()
        try CallDirectoryFeeder().feed(kind: .identificationOnly, from: store, into: identifyMock)
        assert(identifyMock.addedIdentification.map(\.phoneNumber) == [8613800138000])
        assert(identifyMock.addedBlocking.isEmpty, "WHY: identify extension must never submit blocking entries")
        assert(identifyMock.isCompleted)
    }

    test("User can add blocking rule and stream via .full feed mode with strict ordering") {
        let tempDir = FileManager.default.temporaryDirectory
        let dbFile = tempDir.appendingPathComponent("test_feed_full_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbFile)
            try? FileManager.default.removeItem(atPath: dbFile.path + "-wal")
            try? FileManager.default.removeItem(atPath: dbFile.path + "-shm")
        }
        let store = CallDirectoryStore(databaseURL: dbFile)
        try store.open()
        try store.initializeSchema()

        // 1. Add an identification entry
        try store.insertIdentificationBatch([
            IdentificationEntry(phoneNumber: 8695210000, label: "推销")
        ])

        // 2. Add a user block rule
        let blockForms = PhoneNumber.callKitEntries("18964046784").map(\.rawValue)
        let blockRule = ActiveRuleItem(
            pattern: "18964046784",
            action: .block,
            count: blockForms.count
        )
        try store.addUserRule(blockRule, numbers: blockForms)

        assert(store.countBlocking() == 2)
        assert(store.containsBlocking(18964046784))
        assert(store.containsBlocking(8618964046784))
        assert(!store.containsIdentification(18964046784), "Must be mutually exclusive")

        // 3. Feed in .full mode
        let mock = MockCallDirectoryContext()
        try CallDirectoryFeeder().feed(kind: .full, from: store, into: mock)

        assert(mock.isCompleted)
        assert(mock.addedBlocking.count == 2)
        assert(mock.addedIdentification.count == 1)
        assert(SortedSequenceValidator.isStrictlyAscending(mock.addedBlocking))
        assert(SortedSequenceValidator.isStrictlyAscending(mock.addedIdentification.map(\.phoneNumber)))

        // 4. Switch from block to identify
        let identifyRule = ActiveRuleItem(
            pattern: "18964046784",
            action: .identify,
            label: "重新标记为好友",
            count: blockForms.count
        )
        try store.addUserRule(identifyRule, numbers: blockForms)
        assert(store.countBlocking() == 0, "Blocking should be cleared after switching to identify")
        assert(store.containsIdentification(18964046784))
    }

    // 11. Protection Strategy Toggling Tests
    test("Protection Strategy Toggling moves numbers between identification and blocking") {
        let tempDir = FileManager.default.temporaryDirectory
        let dbFile = tempDir.appendingPathComponent("test_strategy_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbFile)
            try? FileManager.default.removeItem(atPath: dbFile.path + "-wal")
            try? FileManager.default.removeItem(atPath: dbFile.path + "-shm")
        }
        let store = CallDirectoryStore(databaseURL: dbFile)
        try store.open()
        try store.initializeSchema()

        // Insert numbers representing 95, 400, MVNO, Landline, and Overseas into identification
        let entries: [IdentificationEntry] = [
            IdentificationEntry(phoneNumber: 8695201234, label: "95呼叫中心"),
            IdentificationEntry(phoneNumber: 864001234567, label: "400推销"),
            IdentificationEntry(phoneNumber: 8617012345678, label: "170虚商"),
            IdentificationEntry(phoneNumber: 862131001234, label: "上海中介座机"),
            IdentificationEntry(phoneNumber: 85221001234, label: "香港高危外呼")
        ]
        try store.insertIdentificationBatch(entries)
        assert(store.countIdentification() == 5)
        assert(store.countBlocking() == 0)

        // Verify initial strategy state is false
        assert(store.isStrategyEnabled(.block95) == false)
        assert(store.isStrategyEnabled(.block400) == false)
        assert(store.isStrategyEnabled(.blockMVNO) == false)
        assert(store.isStrategyEnabled(.blockLandlines) == false)
        assert(store.isStrategyEnabled(.blockOverseas) == false)

        // Enable 95 strategy
        try store.setStrategy(.block95, enabled: true)
        assert(store.isStrategyEnabled(.block95) == true)
        assert(store.countBlocking() == 1)
        assert(store.containsBlocking(8695201234))
        assert(!store.containsIdentification(8695201234))

        // Enable Overseas strategy
        try store.setStrategy(.blockOverseas, enabled: true)
        assert(store.isStrategyEnabled(.blockOverseas) == true)
        assert(store.countBlocking() == 2)
        assert(store.containsBlocking(85221001234))
        assert(!store.containsIdentification(85221001234))

        // Enable Landline strategy
        try store.setStrategy(.blockLandlines, enabled: true)
        assert(store.isStrategyEnabled(.blockLandlines) == true)
        assert(store.countBlocking() == 3)
        assert(store.containsBlocking(862131001234))

        // Disable 95 strategy -> restored to identification
        try store.setStrategy(.block95, enabled: false)
        assert(store.isStrategyEnabled(.block95) == false)
        assert(store.countBlocking() == 2)
        assert(!store.containsBlocking(8695201234))
        assert(store.containsIdentification(8695201234))
    }

    // 12. Sandbox Diagnosis Tests
    test("Sandbox Diagnosis accurately predicts CallKit behavior") {
        let tempDir = FileManager.default.temporaryDirectory
        let dbFile = tempDir.appendingPathComponent("test_diag_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbFile)
            try? FileManager.default.removeItem(atPath: dbFile.path + "-wal")
            try? FileManager.default.removeItem(atPath: dbFile.path + "-shm")
        }
        let store = CallDirectoryStore(databaseURL: dbFile)
        try store.open()
        try store.initializeSchema()

        // 1. Add identification
        try store.insertIdentificationBatch([
            IdentificationEntry(phoneNumber: 8695211000, label: "推销电话")
        ])

        // 2. Add user block rule
        let forms = PhoneNumber.callKitEntries("18964046784").map(\.rawValue)
        let blockRule = ActiveRuleItem(pattern: "18964046784", action: .block, count: forms.count)
        try store.addUserRule(blockRule, numbers: forms)

        // Diagnosis 1: Blocked number
        let diag1 = store.diagnose(input: "18964046784")
        if case .blocked = diag1 {
            // expected
        } else {
            assertionFailure("Expected blocked, got \(diag1)")
        }

        // Diagnosis 2: Identified number (with and without 86)
        let diag2 = store.diagnose(input: "95211000")
        if case .identified(let label) = diag2 {
            assert(label == "推销电话")
        } else {
            assertionFailure("Expected identified, got \(diag2)")
        }

        // Diagnosis 3: Not found number
        let diag3 = store.diagnose(input: "13912345678")
        if case .notFound = diag3 {
            // expected
        } else {
            assertionFailure("Expected notFound, got \(diag3)")
        }

        // Diagnosis 4: Invalid input
        let diag4 = store.diagnose(input: "abcdef")
        if case .invalid = diag4 {
            // expected
        } else {
            assertionFailure("Expected invalid, got \(diag4)")
        }
    }

    // 13. Batch All Strategies Toggle
    test("Batch All Strategies Toggle switches all categories in one transaction") {
        let tempDir = FileManager.default.temporaryDirectory
        let dbFile = tempDir.appendingPathComponent("test_all_strat_\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbFile)
            try? FileManager.default.removeItem(atPath: dbFile.path + "-wal")
            try? FileManager.default.removeItem(atPath: dbFile.path + "-shm")
        }
        let store = CallDirectoryStore(databaseURL: dbFile)
        try store.open()
        try store.initializeSchema()

        let entries: [IdentificationEntry] = [
            IdentificationEntry(phoneNumber: 8695201234, label: "95"),
            IdentificationEntry(phoneNumber: 864001234567, label: "400"),
            IdentificationEntry(phoneNumber: 8617012345678, label: "170"),
            IdentificationEntry(phoneNumber: 862131001234, label: "座机"),
            IdentificationEntry(phoneNumber: 85221001234, label: "境外")
        ]
        try store.insertIdentificationBatch(entries)

        // Turn all on
        try store.setAllStrategies(enabled: true)
        for s in ProtectionStrategy.allCases {
            assert(store.isStrategyEnabled(s) == true)
        }
        assert(store.countBlocking() == 5)
        assert(store.countIdentification() == 0)

        // Turn all off
        try store.setAllStrategies(enabled: false)
        for s in ProtectionStrategy.allCases {
            assert(store.isStrategyEnabled(s) == false)
        }
        assert(store.countBlocking() == 0)
        assert(store.countIdentification() == 5)
    }

    print("==================================================")
    print("📊 Test Results: \(passed) passed, \(failed) failed")
    print("==================================================")

    if failed > 0 {
        exit(1)
    }
}

await runSuite()
