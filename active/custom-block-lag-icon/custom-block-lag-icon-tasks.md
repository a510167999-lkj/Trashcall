# custom-block-lag-icon tasks

- [x] 增量请求先 removeAll 再全量注入；Mock 覆盖重复 add 失败 / removeAll 后成功
- [x] 写事务后 WAL checkpoint；只读重开能读到新号码
- [x] `addRule` / `deleteRules` 不再 `try?` 吞 reload 错误；`currentlyLoading` 重试一次
- [x] seed 仅在库不存在时拷贝；去掉每次启动的 `setHighRiskAutoBlock`；seed 离开主线程
- [x] 扩展编译 AppIcon、显示名改为 Trashcall、版本 1.0.1 (2)
- [x] 测试：`18964046784` → `8618964046784` 进入 blocking；`swift run TrashcallTestRunner` 全绿（9 passed, 0 failed）
- [x] 勾选本清单并回写 plan 验收状态
