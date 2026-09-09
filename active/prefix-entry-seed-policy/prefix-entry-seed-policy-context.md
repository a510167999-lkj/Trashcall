# prefix-entry-seed-policy context

## 相关文件

| 路径 | 作用 |
| --- | --- |
| `Sources/Trashcall/Models/ExcludedPhoneNumbers.swift` | 删除。不再在运行时禁止任何号码。 |
| `Sources/Trashcall/Engine/PatternInput.swift` | 新增。前缀 → 通配符。 |
| `Sources/Trashcall/Engine/RuleExpander.swift` | 先 `PatternInput.resolved`，并提供 `estimateCount`。 |
| `Sources/Trashcall/UI/TrashcallDashboardView.swift` | 去掉 189 拒绝；号段预览；成功提示不拼接上万号码。 |
| `Sources/Trashcall/Storage/CallDirectoryStore.swift` | `addUserRule` / `importIdentifications` 不再过滤；删除 `purgeExcludedNumbers`。 |
| `Sources/Trashcall/Storage/DatabaseBootstrap.swift` | 启动不再清洗 189；seed import 原样写入。 |
| `scripts/fetch_and_build_database.py` | 默认种子省略名单，仅构建期。 |
| `.github/workflows/update_database.yml` | 断言默认种子不自动写入省略号码。 |
| `Sources/TrashcallTestRunner/main.swift` | 用户可存 189；前缀补星；seed import 不再丢 189。 |

## 约束

- 识别-only，不恢复挂断。
- 自动补星最多 4 位，避免 `189` 一次展开成百万级。
- 默认种子现有 35417 条、0 blocking，无需仅为政策重编（已不含 189）。

## 风险

- 旧逻辑每次启动 `purgeExcludedNumbers`，若不删，用户加上的 189 会被洗掉。
- 号段成功提示若仍 `joined` 全量号码，会再次卡 UI。
