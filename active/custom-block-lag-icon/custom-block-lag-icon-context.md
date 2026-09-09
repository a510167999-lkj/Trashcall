# custom-block-lag-icon context

## 相关文件

| 文件 | 角色 |
| --- | --- |
| `Sources/Trashcall/CallKitBridge/TrashcallCallDirectoryProvider.swift` | 扩展 `beginRequest`；当前增量仍全量 add |
| `Sources/Trashcall/CallKitBridge/CallDirectoryProviderWrapper.swift` | Feeder / Mock / protocol |
| `Sources/Trashcall/CallKitBridge/CallDirectoryManagerService.swift` | 主 App 触发 reload，无重试 |
| `Sources/Trashcall/Storage/CallDirectoryStore.swift` | WAL、用户规则、高危策略 |
| `Sources/Trashcall/UI/TrashcallDashboardView.swift` | 添加规则、`try?` 吞错误、主线程读库 |
| `Sources/Trashcall/Models/PhoneNumber.swift` | E.164 归一化 |
| `App/Sources/TrashcallApp.swift` | 主线程 seed + 每次启动搬迁高危号 |
| `Extensions/CallDirectory/Sources/CallDirectoryHandler.swift` | 扩展入口 |
| `Extensions/CallDirectory/Resources/Info.plist` | 显示名 `Trashcall Call Directory`，无图标键 |
| `App/Resources/Info.plist` | 版本 `1`，无 `CFBundleIconName` |
| `App/Resources/Assets.xcassets/AppIcon.appiconset/` | 新图标 1024 RGB、无 alpha |
| `project.yml` / `Trashcall.xcodeproj/project.pbxproj` | 扩展无 Resources 阶段、无 AppIcon |
| `Sources/TrashcallTestRunner/main.swift` | 核心测试套件 |
| `App/Resources/seed_database.sqlite` | ~3.4MB，blocking 40020，identification 397；不含 `18964046784` |

## 依赖与约束

- CallKit：增量模式下 add 已存在号码、remove 不存在号码都会失败整次请求。`removeAll*` 仅允许 `isIncremental == true`。
- 扩展内存上限约 15–30MB、超时 30s。当前 4 万条流式注入可接受。
- 主 App 与扩展靠 App Group `group.com.trashcall.shared` 共享 `trashcall.sqlite`。
- 扩展 bundle id：`com.trashcall.app.CallDirectoryExtension`（与 Dashboard 默认 `extensionId` 一致）。
- 无 git 仓库，不建分支。

## 风险

- 真机「自动挂断」无法在本机 CLI 闭环，只能用 Mock + SQLite 不变量证明注入路径。用户需重装后：设置里重新打开 Trashcall 开关，再用 `18964046784` 打入验证。
- iOS 设置图标有缓存；升 `CFBundleVersion` 后仍可能要关掉再打开扩展开关。
- 增量改成 removeAll + 全量，reload 会比「只加 1 个号」慢，但 4 万条应在秒级。若以后号码上百万再做 delta 表。
