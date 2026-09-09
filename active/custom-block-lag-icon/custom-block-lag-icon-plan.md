# custom-block-lag-icon

## 目标

修三个用户可见问题：

1. 自定义号码 `18964046784` 加入自动挂断后，来电仍不挂断。
2. App 启动/切回前台感觉卡。
3. 主 App 图标已换，但「设置 → 电话 → 通话阻止与身份识别」里看不到新图标对应的 Trashcall。

## 根因（已对照代码，不是猜测）

### 1. 自定义号码无法挂断

三处叠加，任意一处都会让「写入 SQLite 成功、系统电话索引没更新」：

- `TrashcallCallDirectoryProvider.beginRequest` 在 `context.isIncremental == true` 时仍走 `feedFullData` / `addBlockingEntry`。CallKit 规定增量请求里**重复添加已存在号码即整次失败**。首次开启扩展会全量注入 seed（约 4 万条），之后再添加自定义号码触发的 reload 几乎一定是增量请求，于是整次被系统丢掉。
- `addRule()` 使用 `try? await manager.reloadExtension()`，重载失败被吞掉，UI 仍提示「成功添加并重载系统」。
- App Group 库开了 WAL，写入可能停在 `-wal`；扩展以 `SQLITE_OPEN_READONLY` 打开，跨进程读不到未 checkpoint 的新行。

号码归一化本身没问题：`18964046784` → `8618964046784`。seed 里也没有这个号。

### 2. App 卡

`TrashcallApp.init()` 在主线程做：

- 可能按文件大小覆盖 App Group 库（会误伤用户规则）。
- 每次启动都跑 `setHighRiskAutoBlock(enabled: true)`，对 identification 表做 `LIKE '%营销%'` 全表搬迁。

这是启动卡顿的主因。40k 的 `COUNT(*)` 不是主因。

### 3. 电话设置里看不到新图标

- 扩展 **没有 Resources 构建阶段**，未编译 `AppIcon`。
- 扩展显示名是 `Trashcall Call Directory`，和主 App `Trashcall` 不一致。
- `CFBundleVersion` 一直是 `1`，系统设置会缓存旧图标。
- 主 App / 扩展 Info.plist 都没有 `CFBundleIconName`。

系统「通话阻止与身份识别」列表用的是宿主 App + 扩展的名称/图标。扩展没图标 + 版本号不涨，换图后列表仍是旧外观，或看起来像另一个 App。

## 决策

- 增量请求：先 `removeAllBlockingEntries` / `removeAllIdentificationEntries`，再流式全量注入。4 万条远低于 CallKit 上限，不在这次做 pending-delta 表。
- 写事务提交后 `wal_checkpoint(TRUNCATE)`，保证扩展只读也能读到新号码。
- 重载错误必须暴露；`currentlyLoading` 重试一次。
- seed **仅在库文件不存在时拷贝**；高危策略只在首次 seed 时应用。
- 启动 seed 挪出 `App.init()`，放到 Dashboard `.task` 的后台线程。
- 扩展编译同一套 `AppIcon`，显示名改成 `Trashcall`，版本升到 `1.0.1` / `2`。

不把「同时写入带/不带国家码」当作修复。CallKit 要求 E.164；本次失败路径是 reload 被拒绝，不是匹配格式。

## 验收

- [x] `18964046784` 归一化为 `8618964046784`，写入 `blocking_numbers`，增量 reload 不再因重复条目失败。
- [x] 添加规则时若系统重载失败，界面必须显示错误，不得报成功。
- [x] 二次启动不再跑高危号段全表搬迁，也不按文件大小覆盖用户库。
- [x] 扩展 bundle 含 AppIcon，显示名为 Trashcall，`CFBundleVersion >= 2`。
- [x] `swift run TrashcallTestRunner` 全绿（9 passed），覆盖上述号码与增量替换。

真机来电挂断与「设置 → 电话」图标需用户装 1.0.1 (2) 后按下面步骤确认；本机无 Xcode，未跑 iOS 真机/模拟器编译。
