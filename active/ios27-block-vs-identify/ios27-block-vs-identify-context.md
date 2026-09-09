# ios27-block-vs-identify context

## SDK 证据

- 路径：`/Applications/Xcode-beta.app/.../iPhoneOS27.0.sdk`
- `CXCallDirectoryExtensionContext.h`：blocking/identification API 无新增。
- `CXCallDirectoryManager.h`：仍是 reload / enabledStatus / openSettings。
- `CXError.h`：Call Directory 错误码停在 incrementalRemoval=8，无新 blocking 错误。
- IdentityLookup：Live Caller ID Lookup 要自建 PIR 服务，不是本机名单。
- LiveCommunicationKit：VoIP，不能拦蜂窝来电。

## 系统层级（Apple DTS）

用户通讯录 > 本机去电 Recents（iOS 26 新）> 用户系统黑名单 > Call Directory blocking。Identification 只影响展示。

## 相关文件

- `Sources/Trashcall/UI/TrashcallDashboardView.swift`
- `Sources/Trashcall/Storage/CallDirectoryStore.swift`
- `App/Resources/Info.plist` / 扩展 Info.plist / project.yml / pbxproj
- `Sources/TrashcallTestRunner/main.swift`
