# version-ui-block-debug context

## 相关文件

| 文件 | 角色 |
| --- | --- |
| `Sources/Trashcall/UI/TrashcallDashboardView.swift` | 版本、诊断、设置入口、启动 reload |
| `Sources/Trashcall/Models/PhoneNumber.swift` | `callKitEntries` 双形式 |
| `Sources/Trashcall/Engine/RuleExpander.swift` | 精确号码走 `callKitEntries` |
| `Sources/Trashcall/CallKitBridge/CallDirectoryManagerService.swift` | `openSettings` |
| `Sources/Trashcall/CallKitBridge/TrashcallCallDirectoryProvider.swift` | 写扩展运行报告；读写打开 DB |
| `Sources/Trashcall/Storage/ExtensionRunReport.swift` | 新增：扩展上次运行结果 |
| `Sources/Trashcall/Storage/CallDirectoryStore.swift` | `open(createIfNeeded:)` |
| `Sources/Trashcall/Storage/DatabaseBootstrap.swift` | `isUsingAppGroup` |
| `Extensions/CallDirectory/Sources/CallDirectoryHandler.swift` | `@objc` 主类 |
| `Extensions/CallDirectory/Resources/Info.plist` | principal class、版本 1.0.2 (3) |
| `App/Resources/Info.plist` | 版本 1.0.2 (3) |
| `project.yml` / `project.pbxproj` | 版本与新文件 |

## 约束

- CallKit 不能在来电当下由第三方挂断；只能预注册。号码在通讯录里时系统仍会响铃。
- 真机来电无法在 CLI 验证。
