# identify-only-db tasks

- [x] 删除自动挂断 UI、系统拉黑引导、第二个拦截扩展
- [x] 种子库改为纯识别，原阻断号段改为打标
- [x] 排除 18964046784 / 8618964046784
- [x] 启动时按种子版本 upsert 黄页，并清洗旧阻断/测试号
- [x] `swift run TrashcallTestRunner` 9 passed
