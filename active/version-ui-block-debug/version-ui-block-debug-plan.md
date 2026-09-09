# version-ui-block-debug

## 目标

1. App 界面显示当前安装的版本号（marketing + build），打包后不再猜装的是哪一版。
2. 若 1.0.1 代码已装上而 `18964046784` 仍不挂断，补上剩余会让「本地有号、系统不拦」的路径，并把扩展实际运行结果露到界面上。

## 前提

用户已用 Xcode-beta 打包。本机 CLI 的 `xcode-select` 仍指向 Command Line Tools，不能替他编译真机包。版本必须以 **App 自己的 Info.plist** 为准，显示在界面上。

## 仍可能导致拦不住的原因（按证据强度）

1. **界面「去设置」开错页**：`UIApplication.openSettingsURLString` 打开的是本 App 设置，不是「电话 → 通话阻止与身份识别」。扩展没开，CallKit 什么都不拦。改用 `CXCallDirectoryManager.openSettings`。
2. **启动不 reload**：seed / 已有自定义号只写 SQLite，安装新包后不点「重新同步」就不会推进系统索引。启动后自动 reload 一次。
3. **国内来电匹配**：基站常送来 `18964046784` 而不是 `8618964046784`。CallKit 是精确数字匹配。精确号码同时写入两种形式。
4. **App Group 失败却回落到 Documents**：主 App 看起来写入成功，扩展读不到。界面必须红字暴露。
5. **扩展跑失败无痕迹**：把上次 `beginRequest` 的注入条数 / 错误写到 App Group，主界面展示。

## 决策

- 版本显示读 `Bundle.main` 的 `CFBundleShortVersionString` + `CFBundleVersion`。本包升到 **1.0.2 (3)**。
- 精确号码（无通配符）注册 E.164 与国内号；通配符仍只展开 E.164，避免条数翻倍。
- 扩展 `NSExtensionPrincipalClass` 写死模块名，Handler 加 `@objc`。
- 扩展打开数据库用读写、不 CREATE，避免只读进程看不到 WAL。

## 验收

- 界面第一屏能看到 `1.0.2 (3)`。
- 添加 `18964046784` 后本地 blocking 同时有 `18964046784` 和 `8618964046784`。
- App Group 不通或扩展上次失败时，界面有红字，不报成功。
- 「前往系统设置」走 Call Directory 设置页。
- `swift run TrashcallTestRunner` 全绿。
