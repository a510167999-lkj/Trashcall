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

    func testAsync(_ name: String, block: () async throws -> Void) async {
        do {
            try await block()
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

        let custom = PhoneNumber.normalize("18912345678")
        assert(custom?.rawValue == 8618912345678, "Expected 8618912345678, got \(String(describing: custom?.rawValue))")
        let customPlus = PhoneNumber.normalize("+86 189 1234 5678")
        assert(customPlus?.rawValue == 8618912345678)

        let callKitForms = PhoneNumber.callKitEntries("18912345678")
        let formSet = Set(callKitForms.map(\.rawValue))
        assert(
            formSet == [18912345678, 8618912345678],
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

    test("User can store 18912345678; prefix 9521 expands without typed stars") {
        assert(PatternInput.resolved("9521") == "9521****", "WHY: prefix entry must not require manual asterisks")
        assert(PatternInput.resolved("18912345678") == "18912345678", "WHY: a complete mobile stays exact")
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
        let exactForms = try expander.expandWildcard("18912345678").map(\.rawValue)
        assert(Set(exactForms) == [18912345678, 8618912345678])

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
            ActiveRuleItem(pattern: "18912345678", action: .identify, label: "测试", count: 2),
            numbers: exactForms
        )
        assert(store.containsIdentification(18912345678), "WHY: user-added 189 must persist in the live DB")
        assert(store.containsIdentification(8618912345678))
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
        try live.insertBlockingBatch([8695210001, 18912345678])
        try live.convertBlockingToIdentification(defaultLabel: "骚扰电话")
        assert(live.countBlocking() == 0)
        assert(live.containsIdentification(8695210001))
        assert(live.containsIdentification(18912345678), "WHY: 189 may exist in a live DB after conversion")

        let seed = CallDirectoryStore(databaseURL: seedFile)
        try seed.open()
        try seed.initializeSchema()
        try seed.replaceAll(
            blocking: [],
            identifications: [
                IdentificationEntry(phoneNumber: 8613800138000, label: "银行"),
                IdentificationEntry(phoneNumber: 18912345678, label: "explicit-seed")
            ],
            version: "seed-test"
        )
        var imported: [IdentificationEntry] = []
        try seed.streamIdentificationEntries { imported.append($0) }
        try live.importIdentifications(imported)
        assert(live.containsIdentification(8613800138000))
        assert(live.containsIdentification(18912345678), "WHY: seed may include 189 if explicitly sourced; default builder just omits it")
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
        try store.insertBlockingBatch([8618912345678, 18912345678])

        let blockMock = MockCallDirectoryContext()
        try CallDirectoryFeeder().feed(kind: .blockingOnly, from: store, into: blockMock)
        assert(blockMock.addedBlocking == [18912345678, 8618912345678], "block feed must carry every blocking number, ascending")
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
        let blockForms = PhoneNumber.callKitEntries("18912345678").map(\.rawValue)
        let blockRule = ActiveRuleItem(
            pattern: "18912345678",
            action: .block,
            count: blockForms.count
        )
        try store.addUserRule(blockRule, numbers: blockForms)

        assert(store.countBlocking() == 2)
        assert(store.containsBlocking(18912345678))
        assert(store.containsBlocking(8618912345678))
        assert(!store.containsIdentification(18912345678), "Must be mutually exclusive")

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
            pattern: "18912345678",
            action: .identify,
            label: "重新标记为好友",
            count: blockForms.count
        )
        try store.addUserRule(identifyRule, numbers: blockForms)
        assert(store.countBlocking() == 0, "Blocking should be cleared after switching to identify")
        assert(store.containsIdentification(18912345678))
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
        let forms = PhoneNumber.callKitEntries("18912345678").map(\.rawValue)
        let blockRule = ActiveRuleItem(pattern: "18912345678", action: .block, count: forms.count)
        try store.addUserRule(blockRule, numbers: forms)

        // Diagnosis 1: Blocked number
        let diag1 = store.diagnose(input: "18912345678")
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

    // 15. DatabaseUpdateService Delta Merge & User Rules Preservation
    test("DatabaseUpdateService Delta Merge & User Rules Preservation") {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_update_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = CallDirectoryStore(databaseURL: tempURL)
        try store.open()
        try store.initializeSchema()

        // Setup user custom rule
        let userRule = ActiveRuleItem(
            pattern: "13912345678",
            action: .block,
            label: nil,
            count: 1
        )
        try store.addUserRule(userRule, numbers: [8613912345678])

        let payload = RemoteDatabaseUpdate(
            version: "2026.09.10.v1",
            addedBlocking: [8613800000000],
            removedBlocking: [],
            addedIdentifications: [
                RemoteIdentificationEntry(phone: 8695219999, label: "高频金融营销")
            ],
            removedIdentifications: []
        )

        let (addedBlock, addedIdent) = try DatabaseUpdateService.shared.applyUpdate(payload, to: store)
        assert(addedBlock == 1, "Expected 1 added blocking number")
        assert(addedIdent == 1, "Expected 1 added identification entry")

        // Verify cloud rules exist
        assert(store.containsBlocking(8613800000000) == true)
        assert(store.containsIdentification(8695219999) == true)

        // Verify user rule was preserved and NOT overridden
        assert(store.containsBlocking(8613912345678) == true)
        let rules = try store.getUserRules()
        assert(rules.count == 1 && rules.first?.pattern == "13912345678")

        // Verify version updated
        let cloudVer = DatabaseUpdateService.shared.getCloudRulesVersion(in: store)
        assert(cloudVer == "2026.09.10.v1")
    }

    test("Published official catalogue decodes using the snapshot contract") {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try Data(contentsOf: root.appendingPathComponent("Server/static/rules_latest.json"))
        let update = try JSONDecoder().decode(RemoteDatabaseUpdate.self, from: fixture)
        assert(!update.version.isEmpty && update.isSnapshot)
        assert((update.addedBlocking?.count ?? 0) + (update.addedIdentifications?.count ?? 0) > 0)
    }

    if ProcessInfo.processInfo.environment["TRASHCALL_TEST_LIVE_RULES"] == "1" {
        await testAsync("Fetch and decode the live official catalogue") {
            let endpoint = DatabaseUpdateService.shared.getEndpointURL()
            let update = try await DatabaseUpdateService.shared.fetchRemoteUpdate(from: endpoint)
            assert(!update.version.isEmpty)
        }
    }

    // 17. PatternInput & RuleExpander for 7-digit vs 8-digit Landline Cities (0571 vs 0552)
    test("PatternInput & RuleExpander for 7-digit vs 8-digit Landlines (0571 vs 0552)") {
        // Hangzhou 0571: 4-digit area code + 8-digit local number = 12 digits
        let hzPrefix = PatternInput.resolved("05712801")
        assert(hzPrefix == "05712801****", "05712801 must auto-pad 4 stars for 8-digit local number (12 digits total), got \(hzPrefix)")

        // Bengbu 0552: 4-digit area code + 7-digit local number = 11 digits
        let bbPrefix = PatternInput.resolved("0552607")
        assert(bbPrefix == "0552607****", "0552607 must auto-pad 4 stars for 7-digit local number (11 digits total), got \(bbPrefix)")

        // User typed excess 5 stars on 7-digit city: auto-sanitize to 4 stars
        let bbExcess = PatternInput.resolved("0552607*****")
        assert(bbExcess == "0552607****", "Excess wildcard must be sanitized to 11 digits, got \(bbExcess)")

        let expander = RuleExpander()
        let bbNumbers = try expander.expandWildcard(bbPrefix)
        let bbSet = Set(bbNumbers.map(\.rawValue))
        // Incoming call 05526071234 -> E.164 is 865526071234 (12 digits) or domestic 5526071234 (10 digits)
        assert(bbSet.contains(865526071234), "Bengbu expansion must contain E.164 form 865526071234")
        assert(bbSet.contains(5526071234), "Bengbu expansion must contain domestic form 5526071234")

        let hzNumbers = try expander.expandWildcard(hzPrefix)
        let hzSet = Set(hzNumbers.map(\.rawValue))
        // Incoming call 057128011234 -> E.164 is 8657128011234 (13 digits) or domestic 57128011234 (11 digits)
        assert(hzSet.contains(8657128011234), "Hangzhou expansion must contain E.164 form 8657128011234")
        assert(hzSet.contains(57128011234), "Hangzhou expansion must contain domestic form 57128011234")
    }

    // 18. deleted_user_rules Tombstone Tracking
    test("User Rule Deletion Tombstone Tracking & Cleanup") {
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("test_tombstone_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let store = CallDirectoryStore(databaseURL: dbURL)
        try store.open(readOnly: false)
        try store.initializeSchema()
        defer { store.close() }

        let rule1 = ActiveRuleItem(pattern: "13800138000", action: .block, count: 2)
        try store.addUserRule(rule1, numbers: [13800138000, 8613800138000])

        let initialRules = try store.getUserRules()
        assert(initialRules.count == 1)
        let initialDeleted = try store.getDeletedUserRuleIDs()
        assert(initialDeleted.isEmpty)

        // Delete rule -> must write tombstone
        try store.deleteUserRule(id: rule1.id, pattern: rule1.pattern, action: rule1.action, numbers: [13800138000, 8613800138000])
        let rulesAfterDelete = try store.getUserRules()
        assert(rulesAfterDelete.isEmpty)
        let deletedIDs = try store.getDeletedUserRuleIDs()
        assert(deletedIDs == [rule1.id], "Tombstone must contain deleted rule id")

        // Re-add rule -> tombstone must be cleared
        try store.addUserRule(rule1, numbers: [13800138000, 8613800138000])
        let rulesAfterReadd = try store.getUserRules()
        assert(rulesAfterReadd.count == 1)
        let deletedAfterReadd = try store.getDeletedUserRuleIDs()
        assert(deletedAfterReadd.isEmpty, "Re-adding rule must clear tombstone")
    }

    // 19. applyCloudSyncChanges Reconciliation
    test("applyCloudSyncChanges Two-Way Merge & Conflict Resolution") {
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("test_cloud_merge_\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let store = CallDirectoryStore(databaseURL: dbURL)
        try store.open(readOnly: false)
        try store.initializeSchema()
        defer { store.close() }

        // Local has ruleA
        let ruleA = ActiveRuleItem(pattern: "05712801****", action: .block, count: 2000)
        let expander = RuleExpander()
        let numbersA = try expander.expandWildcard(ruleA.pattern).map(\.rawValue)
        try store.addUserRule(ruleA, numbers: numbersA)

        // Incoming from cloud: ruleB (new) and ruleA (cloud requested deletion)
        let ruleB = ActiveRuleItem(pattern: "0213470****", action: .identify, label: "上海骚扰", count: 2000)
        let (added, deleted) = try store.applyCloudSyncChanges(
            incomingRules: [ruleB],
            deletedRuleIDs: [ruleA.id]
        )

        assert(added == 1, "Expected 1 added rule, got \(added)")
        assert(deleted == 1, "Expected 1 deleted rule, got \(deleted)")

        let currentRules = try store.getUserRules()
        assert(currentRules.count == 1, "Should have 1 rule remaining")
        assert(currentRules.first?.id == ruleB.id, "Remaining rule must be ruleB")
        assert(store.containsIdentification(862134700000), "ruleB identification must be inserted")
        assert(!store.containsBlocking(8657128010000), "ruleA blocking numbers must be cleared")
    }

    // 20. CloudKitSyncService Invariants
    await testAsync("CloudKitSyncService Invariants & Status") {
        assert(CloudKitSyncService.containerIdentifier == "iCloud.com.trashcall.app")
        assert(CloudKitSyncService.recordType == "UserCustomRule")

        assert(
            CloudKitSyncService.hasRequiredCloudKitEntitlements(
                containerIdentifiers: ["iCloud.com.trashcall.app"],
                services: ["CloudKit"]
            )
        )
        assert(
            CloudKitSyncService.hasRequiredCloudKitEntitlements(
                containerIdentifiers: ["iCloud.com.trashcall.app"],
                services: ["*"]
            )
        )
        assert(
            !CloudKitSyncService.hasRequiredCloudKitEntitlements(
                containerIdentifiers: [],
                services: ["CloudKit"]
            )
        )
        assert(
            !CloudKitSyncService.hasRequiredCloudKitEntitlements(
                containerIdentifiers: ["iCloud.com.trashcall.app"],
                services: []
            )
        )

        #if os(iOS)
        let status = await CloudKitSyncService.shared.getAccountStatus()
        assert(!status.description.isEmpty)
        #endif
    }

    test("App Group prefers configured group") {
        assert(DatabaseBootstrap.preferredAppGroupId == "group.0294e79a001ad3e1.1")
        assert(!DatabaseBootstrap.appGroupId.isEmpty)
    }

    test("Call Directory extension IDs stay prefixed fallbacks off-device") {
        assert(TrashcallExtensionID.identificationFallback == "com.trashcall.app.CallDirectoryExtension")
        assert(TrashcallExtensionID.blockingFallback == "com.trashcall.app.BlockDirectoryExtension")
        assert(TrashcallExtensionID.identification.hasPrefix("com.trashcall.app."))
        assert(TrashcallExtensionID.blocking.hasPrefix("com.trashcall.app."))
        assert(TrashcallExtensionID.identification != TrashcallExtensionID.blocking)
    }

    test("Extension Info.plist PrincipalClass and extension point invariants") {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TrashcallTestRunner
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        let appPlistURL = repoRoot.appendingPathComponent("App/Resources/Info.plist")
        let identPlistURL = repoRoot.appendingPathComponent("Extensions/CallDirectory/Resources/Info.plist")
        let blockPlistURL = repoRoot.appendingPathComponent("Extensions/BlockDirectory/Resources/Info.plist")

        guard let appData = try? Data(contentsOf: appPlistURL),
              let appPlist = try? PropertyListSerialization.propertyList(from: appData, format: nil) as? [String: Any],
              let identData = try? Data(contentsOf: identPlistURL),
              let identPlist = try? PropertyListSerialization.propertyList(from: identData, format: nil) as? [String: Any],
              let blockData = try? Data(contentsOf: blockPlistURL),
              let blockPlist = try? PropertyListSerialization.propertyList(from: blockData, format: nil) as? [String: Any] else {
            fatalError("Failed to read Info.plist files for validation")
        }

        let appVersion = appPlist["CFBundleShortVersionString"] as? String
        let appBuild = appPlist["CFBundleVersion"] as? String

        // Identification extension validation
        assert(identPlist["CFBundleShortVersionString"] as? String == appVersion, "Ident version must match app")
        assert(identPlist["CFBundleVersion"] as? String == appBuild, "Ident build must match app")
        let identExt = identPlist["NSExtension"] as? [String: Any]
        assert(identExt?["NSExtensionPointIdentifier"] as? String == "com.apple.callkit.call-directory")
        assert(identExt?["NSExtensionPrincipalClass"] as? String == "CallDirectoryHandler", "Principal class must be CallDirectoryHandler")

        // Block extension validation
        assert(blockPlist["CFBundleShortVersionString"] as? String == appVersion, "Block version must match app")
        assert(blockPlist["CFBundleVersion"] as? String == appBuild, "Block build must match app")
        let blockExt = blockPlist["NSExtension"] as? [String: Any]
        assert(blockExt?["NSExtensionPointIdentifier"] as? String == "com.apple.callkit.call-directory")
        assert(blockExt?["NSExtensionPrincipalClass"] as? String == "CallDirectoryBlockHandler", "Principal class must be CallDirectoryBlockHandler")
    }

    // 24. Sideload Fallback: Reading bundled seed database when App Group is unavailable
    test("Sideload Fallback: Bundled seed database readable and streamable without App Group") {
        guard let seedURL = DatabaseBootstrap.bundledSeedURL() else {
            fatalError("DatabaseBootstrap.bundledSeedURL() returned nil")
        }
        assert(FileManager.default.fileExists(atPath: seedURL.path), "Seed DB file must exist at \(seedURL.path)")

        let store = CallDirectoryStore(databaseURL: seedURL)
        try store.open(readOnly: true)
        defer { store.close() }

        let identCount = store.countIdentification()
        assert(identCount > 400000, "Seed database must contain > 400k numbers for fallback protection, got \(identCount)")

        let mockContext = MockCallDirectoryContext()
        var streamCount = 0
        try store.streamIdentificationEntries { entry in
            if streamCount < 100 {
                mockContext.addIdentificationEntry(withNextSequentialPhoneNumber: entry.phoneNumber, label: entry.label)
                streamCount += 1
            }
        }
        assert(mockContext.addedIdentification.count == 100, "Expected 100 streamed entries into mock context")
    }

    // 25. Build IPA Script Invariants
    test("scripts/build_ipa.sh strips stale mobileprovisions and generates DER entitlements") {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TrashcallTestRunner
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
        let scriptURL = repoRoot.appendingPathComponent("scripts/build_ipa.sh")
        guard let content = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            fatalError("Failed to read scripts/build_ipa.sh")
        }

        assert(content.contains("find \"${STAGED_APP}\" -name \"*.mobileprovision\" -delete"), "Must strip stale mobileprovision files")
        assert(content.contains("rm -f \"${DESKTOP_IPA}\" \"${ROOT_IPA}\""), "Must remove old IPA before zipping to avoid stale payload merging")
        assert(content.contains("--generate-entitlement-der"), "Must include --generate-entitlement-der for iOS 15+ codesign compatibility")
    }

    func withRulesStore(_ body: (CallDirectoryStore) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trashcall-regression-\(UUID()).sqlite")
        let store = CallDirectoryStore(databaseURL: url)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url)
        }
        try store.initializeSchema()
        try body(store)
    }

    test("Middle wildcards are rejected and country-code variants resolve equally") {
        let expander = RuleExpander()
        for bad in ["95210?00", "9521*000", "abc9521"] {
            do {
                _ = try expander.expandWildcard(bad)
                assertionFailure("Unexpected valid pattern: \(bad)")
            } catch is RuleExpansionError {}
        }
        let local = try expander.expandWildcard("95210000")
        let bare = try expander.expandWildcard("8695210000")
        let plus = try expander.expandWildcard("+86 95210000")
        assert(local == bare && bare == plus)
        let intl = try expander.expandWildcard("+852 2100 0000")
        assert(intl.map(\.rawValue) == [85221000000])
    }

    test("Deleting an overlapping rule or disabling a strategy restores underlying rules and labels") {
        try withRulesStore { store in
            let number: Int64 = 8695210000
            try store.insertIdentificationBatch([.init(phoneNumber: number, label: "原机构标签")])
            let range = try store.addUserRule(.init(pattern: "9521000*", action: .block))
            let exact = try store.addUserRule(.init(pattern: "95210000", action: .block))
            try store.setStrategy(.block95, enabled: true)
            try store.setStrategy(.block95, enabled: false)
            assert(store.containsBlocking(number))
            try store.deleteUserRules(ids: [exact.id])
            assert(store.containsBlocking(number))
            try store.deleteUserRules(ids: [range.id])
            assert(store.diagnose(input: "95210000") == .identified(label: "原机构标签"))
        }
    }

    test("Official snapshots withdraw old entries and roll back without removing local exceptions") {
        try withRulesStore { store in
            let service = DatabaseUpdateService.shared
            let old: Int64 = 8695210000
            let new: Int64 = 8695210001
            let blocked: Int64 = 8613800138000
            try store.insertIdentificationBatch([.init(phoneNumber: old, label: "原机构标签")])
            _ = try store.addUserRule(.init(pattern: "13800138000", action: .block))
            let allow = try store.addUserRule(.init(pattern: "95210001", action: .allow))
            try service.applyUpdate(.init(version: "v1", addedBlocking: [old]), to: store)
            assert(store.containsBlocking(old))
            try service.applyUpdate(.init(version: "v2", addedBlocking: [new]), to: store)
            assert(store.diagnose(input: "95210000") == .identified(label: "原机构标签"))
            assert(!store.containsBlocking(new))
            assert(store.containsBlocking(blocked))
            let previous = try store.rollbackOfficialRules()
            assert(previous == "v1" && store.containsBlocking(old))
            let suppressed = try store.getMetadata(key: "withdrawn_cloud_rules_version")
            assert(suppressed == "v2")
            try store.deleteUserRules(ids: [allow.id])
            assert(!store.containsBlocking(new))
        }
    }

    test("Legacy official blockers are labelled and an invalid delta leaves the saved snapshot intact") {
        try withRulesStore { store in
            let number: Int64 = 8695210000
            let json = Data(#"{"version":"v1","added_blocking":[8695210000]}"#.utf8)
            let legacy = try JSONDecoder().decode(RemoteDatabaseUpdate.self, from: json)
            let service = DatabaseUpdateService.shared
            try service.applyUpdate(legacy, to: store)
            assert(!store.containsBlocking(number) && store.containsIdentification(number))
            do {
                try service.applyUpdate(.init(version: "v2", addedBlocking: [number], format: .delta, baseVersion: "missing"), to: store)
                assertionFailure("Accepted a delta for the wrong version")
            } catch StoreError.invalidRule {}
            let saved = try store.getMetadata(key: "cloud_rules_version")
            assert(saved == "v1" && store.containsIdentification(number))

            try service.applyUpdate(.init(version: "v2", addedBlocking: [number], format: .delta, baseVersion: "v1"), to: store)
            assert(store.containsBlocking(number))
            let prior = try store.rollbackOfficialRules()
            assert(prior == "v1" && !store.containsBlocking(number) && store.containsIdentification(number))
        }
    }

    test("Existing installations rebuild from the bundled catalogue and stop loading unsafe legacy ranges") {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trashcall-migration-\(UUID()).sqlite")
        let store = CallDirectoryStore(databaseURL: url)
        try store.open()
        defer {
            store.close()
            try? FileManager.default.removeItem(at: url)
        }
        try store.initializeSchema()
        let legacyID = UUID().uuidString
        try store.execute(sql: """
            INSERT INTO user_rules VALUES ('\(legacyID)', '95210?00', '\(RuleActionType.block.rawValue)', NULL, 1802, 1);
            INSERT INTO blocking_numbers VALUES (8695210001), (8613800138000);
            INSERT INTO user_blocking_numbers VALUES (8695210001);
            INSERT INTO identification_numbers VALUES (8613800138123, '旧官方标签');
            """)
        try store.setMetadata(key: "cloud_rules_version", value: "legacy")
        try store.setMetadata(key: "last_update_check_at", value: "123")
        try DatabaseBootstrap.prepareDatabase(at: url)
        assert(!store.containsBlocking(8695210001))
        assert(!store.containsBlocking(8613800138000) && store.containsIdentification(8613800138000))
        assert(store.diagnose(input: "13800138123") == .identified(label: "旧官方标签"))
        let checkedAt = try store.getMetadata(key: "last_update_check_at")
        assert(checkedAt == nil)
        let migrated = try store.getUserRules()
        assert(migrated.count == 1 && migrated[0].count == 0)
        let initialRevision = try store.getMetadata(key: "directory_revision")
        try DatabaseBootstrap.prepareDatabase(at: url)
        let nextRevision = try store.getMetadata(key: "directory_revision")
        assert(initialRevision != nil && initialRevision == nextRevision)
        try DatabaseUpdateService.shared.applyUpdate(.init(version: "legacy", addedBlocking: []), to: store)
        assert(!store.containsIdentification(8613800138123))
    }

    test("Revisions settle same-pattern CloudKit edits, invalid updates and offline deletes") {
        try withRulesStore { store in
            let number: Int64 = 8695210000
            let original = try store.addUserRule(.init(pattern: "95210000", action: .block))
            let replacement = try store.addUserRule(.init(pattern: "+86 95210000", action: .identify, label: "用户标签"))
            assert(original.id == replacement.id)
            try store.applyCloudSyncChanges(incomingRules: [original], deletedRuleIDs: [])
            assert(store.diagnose(input: "95210000") == .identified(label: "用户标签"))

            let remoteDuplicate = ActiveRuleItem(pattern: "8695210000", action: .block, createdAt: .distantPast)
            try store.applyCloudSyncChanges(incomingRules: [remoteDuplicate], deletedRuleIDs: [])
            let retired = try store.getDeletedUserRuleIDs()
            assert(retired.contains(remoteDuplicate.id) && !store.containsBlocking(number))

            let invalid = ActiveRuleItem(id: original.id, pattern: "95210?00", action: .block, updatedAt: .distantFuture)
            do {
                try store.applyCloudSyncChanges(incomingRules: [invalid], deletedRuleIDs: [])
                assertionFailure("Accepted an invalid cloud pattern")
            } catch is RuleExpansionError {}
            assert(store.diagnose(input: "95210000") == .identified(label: "用户标签"))

            try store.deleteUserRules(ids: [original.id])
            try store.applyCloudSyncChanges(incomingRules: [replacement], deletedRuleIDs: [])
            assert(!store.containsBlocking(number) && !store.containsIdentification(number))
        }
    }

    test("Extension report remains backward compatible and preserves the submitted directory revision") {
        let legacy = Data(#"{"at":1,"incremental":false,"appGroupOK":true,"dbExists":true,"blockingFed":0,"identificationFed":1,"feedKind":"identificationOnly","probedNumbers":[]}"#.utf8)
        let original = try JSONDecoder().decode(ExtensionRunReport.self, from: legacy)
        assert(original.directoryRevision == nil)
        var updated = original
        updated.directoryRevision = "directory-2"
        let roundTrip = try JSONDecoder().decode(ExtensionRunReport.self, from: JSONEncoder().encode(updated))
        assert(roundTrip.directoryRevision == "directory-2")
    }

    test("Enabled extensions report loaded only after the matching revision is accepted") {
        let report = ExtensionRunReport(incremental: false, appGroupOK: true, dbExists: true,
                                        identificationFed: 10, directoryRevision: "rev2")
        func state(_ status: ExtensionStatus, _ accepted: String?, error: String? = nil) -> DirectoryActivationStatus {
            DirectoryActivationStatus.resolve(extensionStatus: status, appGroupReady: true, revision: "rev2",
                                              acceptedRevision: accepted, report: report, reloadError: error)
        }
        assert(state(.disabled, "rev2") == .settingsDisabled)
        assert(state(.enabled, nil) == .pending)
        assert(state(.enabled, "rev1") == .pending)
        assert(state(.enabled, "rev2", error: "CallKit error") == .failed("CallKit error"))
        assert(state(.enabled, "rev2") == .loaded(count: 10))
    }

    test("Supplemental caller IDs survive strategy changes and respect local rules") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trashcall-supplement-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let emptySeedURL = directory.appendingPathComponent("base.sqlite")
        let vendorSeedURL = directory.appendingPathComponent("vendor.sqlite")
        let liveURL = directory.appendingPathComponent("live.sqlite")
        let original: Int64 = 8695211111
        let vendorOnly: Int64 = 8695212222

        let base = CallDirectoryStore(databaseURL: emptySeedURL)
        try base.open()
        try base.initializeSchema()
        try base.insertIdentificationBatch([.init(phoneNumber: original, label: "现有标签")])
        try base.setMetadata(key: "version", value: "base")
        base.checkpoint()
        base.close()
        try FileManager.default.copyItem(at: emptySeedURL, to: vendorSeedURL)

        let vendor = CallDirectoryStore(databaseURL: vendorSeedURL)
        try vendor.open()
        try vendor.execute(sql: """
            INSERT INTO supplemental_identifications VALUES (\(original), '供应商标签'), (\(vendorOnly), '广告推销');
            """)
        try vendor.setMetadata(key: "supplemental_identification_version", value: "fixture")
        vendor.close()

        try DatabaseBootstrap.prepareDatabase(at: liveURL, bundledSeed: vendorSeedURL)
        let live = CallDirectoryStore(databaseURL: liveURL)
        try live.open()
        defer { live.close() }
        assert(live.countIdentification() == 2)
        assert(live.diagnose(input: "95211111") == .identified(label: "现有标签"))
        assert(live.diagnose(input: "95212222") == .identified(label: "广告推销"))
        var streamed: [Int64] = []
        try live.streamIdentificationEntries { streamed.append($0.phoneNumber) }
        assert(streamed == [original, vendorOnly])

        try live.setStrategy(.block95, enabled: true)
        assert(live.containsBlocking(original) && !live.containsIdentification(original))
        assert(!live.containsBlocking(vendorOnly) && live.containsIdentification(vendorOnly))
        let user = try live.addUserRule(ActiveRuleItem(pattern: "95212222", action: .block))
        assert(live.containsBlocking(vendorOnly) && !live.containsIdentification(vendorOnly))
        try live.deleteUserRules(ids: [user.id])
        assert(live.containsIdentification(vendorOnly))

        try DatabaseBootstrap.prepareDatabase(at: liveURL, bundledSeed: emptySeedURL)
        assert(!live.containsIdentification(vendorOnly))
        assert(live.containsBlocking(original))
    }

    print("==================================================")
    print("📊 Test Results: \(passed) passed, \(failed) failed")
    print("==================================================")

    if failed > 0 {
        exit(1)
    }
}

await runSuite()
