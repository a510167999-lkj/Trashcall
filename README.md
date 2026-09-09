# Trashcall - iOS 垃圾电话与骚扰拦截系统核心架构

面向现代化 iOS（支持当前最新 iOS 17/18 及未来版本演进）的高性能、隐私零泄露、超低内存开销的电话拦截与号码标记识别核心架构。

---

## 🌟 核心设计理念与技术选型

### 1. 开发语言：Swift 6+（Strict Concurrency）
- **为何不使用跨平台框架（Flutter / React Native）**：
  iOS 拦截扩展（`CXCallDirectoryProvider`）运行于独立沙盒进程中，系统对其施加了极其严苛的物理内存限制（**通常上限仅 15MB ~ 30MB**，超时 30 秒）。跨平台引擎启动时的基础开销即会直接触发系统 `SIGKILL` 强退。
- **为何选择 Swift 6**：
  - Apple 系统级一等公民，零 FFI 开销直调 CallKit / IdentityLookup。
  - 基于 ARC 的无 GC 确定性内存分配，内存可精确控制在 1MB 以内。
  - Swift 6 编译期线程安全模型（Strict Concurrency / Actors），杜绝跨进程与多线程数据竞争。

### 2. iOS 隐私与“盲拦截”机制
在 iOS 中，**主叫号码绝对不会暴露给第三方 App 或 Extension**。
1. App 必须通过 `App Group` 将号码预先存储为升序索引。
2. 通过 `CXCallDirectoryProvider` 将号码批量流式注册进 iOS 系统底层索引库。
3. 来电时，由 iOS 系统电话进程（`In-Call Service`）自行完成拦截与打标展示，保障用户隐私绝对安全。

---

## 📁 模块分层与工程结构

```text
Trashcall/
├── Package.swift
├── Sources/
│   ├── Trashcall/
│   │   ├── Models/
│   │   │   ├── PhoneNumber.swift           # E.164 号码清洗、校验与 Int64 映射
│   │   │   ├── CallRule.swift              # 黑名单、标记规则、号段模式定义
│   │   │   └── DeltaPackage.swift          # 增量差分补丁数据模型
│   │   ├── Engine/
│   │   │   ├── RuleExpander.swift          # 通配符 (如 9521****) 安全受控展开器
│   │   │   ├── SortedSequenceValidator.swift # CallKit 严格单调升序检查与排重
│   │   │   └── IncrementalEngine.swift     # 增量变更 (Add/Remove) 计算引擎
│   │   ├── Storage/
│   │   │   └── CallDirectoryStore.swift    # 极低内存 SQLite 步进游标流式读写器
│   │   ├── CallKitBridge/
│   │   │   ├── CallDirectoryProviderWrapper.swift # 流式注入流水线与测试 Mock
│   │   │   ├── TrashcallCallDirectoryProvider.swift # CXCallDirectoryProvider 生产子类
│   │   │   └── CallDirectoryManagerService.swift   # 主 App 扩展状态与重载触发器
│   │   └── UI/
│   │       └── TrashcallDashboardView.swift # SwiftUI 状态面板与规则界面
│   └── TrashcallTestRunner/
│       └── main.swift                      # 核心算法与端到端流式验证测试套件
```

---

## 🛠️ 如何在 Xcode 中接入与配置

### 步骤 1：创建两个 Call Directory Extension Target
1. 打开 Xcode，在项目中选择 `File` -> `New` -> `Target...`。
2. 选择 **Call Directory Extension**，分别创建两个扩展：
   - `CallDirectoryExtension`（识别扩展，`feedKind = .identificationOnly`，只提交来电打标条目）。
   - `BlockDirectoryExtension`（挂断扩展，`feedKind = .blockingOnly`，只提交自动挂断条目）。
3. 将项目依赖指向本 `Trashcall` Swift Package。

> ⚠️ **为什么必须拆成两个扩展**：iOS 26/27 会丢弃同一请求中与打标条目混提的 `addBlockingEntry`，
> 表现为"加入自动挂断的号码来电仍然正常打入，而打标一切正常"。两个扩展各自提交同质请求即可规避，
> 且挂断索引体积小、重载快，不受 41 万条打标库影响。

### 步骤 2：配置 App Groups 共享容器
由于主 App 与 Extension 位于不同沙盒中，必须开启 App Group 实现数据共享：
1. 在主 App Target 的 `Signing & Capabilities` 中添加 **App Groups**，例如 `group.com.yourcompany.trashcall`。
2. 在 `CallDirectoryExtension` 与 `BlockDirectoryExtension` 两个 Target 的 `Signing & Capabilities` 中添加完全相同的 App Group 标识符。

### 步骤 3：实现 CallDirectoryHandler
在 Extension Target 中，直接继承 `TrashcallCallDirectoryProvider`：

```swift
import Trashcall

final class CallDirectoryHandler: TrashcallCallDirectoryProvider {
    override var appGroupIdentifier: String {
        return "group.com.yourcompany.trashcall"
    }

    override var databaseFileName: String {
        return "trashcall.sqlite"
    }
}
```

### 步骤 4：主 App 写入号码并触发重载
在主 App 中，使用 `CallDirectoryStore` 写入号码，并通知系统更新：

```swift
import Trashcall

guard let groupURL = FileManager.default.containerURL(
    forSecurityApplicationGroupIdentifier: "group.com.yourcompany.trashcall"
) else { return }

let dbURL = groupURL.appendingPathComponent("trashcall.sqlite")
let store = CallDirectoryStore(databaseURL: dbURL)
try store.open()
try store.initializeSchema()

// 批量写入全量或增量号码（百万级别写入仅需数百毫秒）
try store.replaceAll(
    blocking: [8613800000001, 8613800000002],
    identifications: [IdentificationEntry(phoneNumber: 8695210000, label: "推销电话")],
    version: "2026.09.09"
)

// 通知 CallKit 在后台唤醒扩展并完成注册（识别与挂断两个扩展都需要重载）
let manager = CallDirectoryManagerService(extensionBundleIdentifier: "com.yourcompany.trashcall.CallDirectoryExtension")
try await manager.reloadExtension()
let blockManager = CallDirectoryManagerService(extensionBundleIdentifier: "com.yourcompany.trashcall.BlockDirectoryExtension")
try await blockManager.reloadExtension()
```

---

## 🧪 运行核心验证测试

本地已集成自研验证套件，覆盖 E.164 格式清洗、通配符防溢出保护、单调递增不变量检查、增量差分及 SQLite 游标流式喂入：

```bash
swift run TrashcallTestRunner
```

### 输出示例：
```text
==================================================
🚀 Running Trashcall Core Verification Test Suite
==================================================
  ✅ PASS: PhoneNumber Normalization (Chinese Mobile & Landline)
  ✅ PASS: RuleExpander Wildcard & Bound Protection
  ✅ PASS: SortedSequenceValidator Monotonic Invariants
  ✅ PASS: IncrementalEngine Diff Calculation
  ✅ PASS: SQLite Store Batch Writing and Streaming Feeder
==================================================
📊 Test Results: 5 passed, 0 failed
==================================================
```
