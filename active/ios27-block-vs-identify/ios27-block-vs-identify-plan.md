# ios27-block-vs-identify

## 结论（先看这个）

识别能打标、自动挂断不行，**不是注入失败**。识别成功说明：扩展在跑、App Group 通、号码格式能被 iOS 匹配。

本机 Xcode-beta 的 **iPhoneOS 27.0 SDK**（ProductVersion 27.0, 24A5422a）里，Call Directory 公开 API 与 iOS 10/11 相同：只有 `addBlockingEntry` / `addIdentificationEntry`。**没有**第三方「来电当下挂断 / 给对方忙音」的新接口。LiveCommunicationKit 只管 VoIP 会话，不管蜂窝来电拦截。

iOS 26 起（延续到 27）系统对 **blocking** 加了更高优先级的例外，**identification 不受影响**：

1. 号码在通讯录里 → 不拦，显示联系人。
2. 本机对这个号有过**去电记录**（Recents outgoing）→ 不拦。Apple DTS（Kevin Elliott）明确说这是配合 Live Caller ID 的层级变化，删掉该条最近通话后才会拦。论坛：https://developer.apple.com/forums/thread/800415
3. 识别打标成功只证明匹配，不证明 blocking 条目被采用。
4. iOS 26 起被拦的来电仍会出现在未接来电，并标明哪个 App 拦的。这不是失败。
5. 第三方永远不能向运营商发拒接；「对方听忙音」是错的。

用 `18964046784` 自测时，只要本机打过这个号或存过通讯录，就会出现「识别行、挂断不行」。

## 代码要改的

- 界面去掉「对方听忙音」，写清 iOS 26/27 例外和正确测法。
- 同一 pattern 不允许同时存在识别+拦截（后写覆盖，并从另一张表删掉）。
- 版本升到 **1.0.3 (4)**。

## 验收

- 界面第一屏版本 `1.0.3 (4)`，能看到去电记录/通讯录例外说明。
- 先识别再拦截同一号码，只留在 blocking。
- `swift run TrashcallTestRunner` 全绿。
