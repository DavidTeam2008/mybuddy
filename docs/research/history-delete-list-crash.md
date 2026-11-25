# 历史删除导致 List 无效更新崩溃（fix）

> 日期：2026-11-25。现场：iPhone 13（iOS 27.2.1），Xcode Debug 运行，从面对面任务详情页删除后卡死，Xcode Stop。

## 症状

Xcode 控制台关键行：

```text
*** Assertion failure in -[SwiftUI.UpdateCoalescingCollectionView _Bug_Detected_In_Client_Of_UICollectionView_Invalid_Number_Of_Items_In_Section:], UICollectionView.m:10954
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
reason: 'Invalid update: invalid number of items in section 0. The number of items contained in an existing section after the update (3) must be equal to the number of items contained in that section before the update (3), plus or minus ... (0 inserted, 1 deleted) ...'
```

即：历史 `List` 收到了“删除 1 行”的差量，但更新后数据源仍是 3 行——SwiftUI 的 diff 与集合视图快照不一致。此前还有 `Gesture: System gesture gate timed out`，说明主线程被 Debug 下 SwiftData 删除/映射阻塞约 1 秒，放大了同一事务内合并更新的窗口。

## 根因（合并自三路分析）

1. 详情页删除只改了 store，`HistoryViewModel.tasks` 仍是 3 行；返回历史时 `popToHome()` + `open(.history)` 两次路径写入，历史视图重新挂载后才由 `.task` reload 得到 2 行。若删除差量与重新挂载落在同一更新窗口，集合视图会用挂载时的 3 行快照校验 3→2 的删除差量。
2. `reload()` 无 generation 守卫：一个较早捕获 3 行的读如果在删除后的读之后落地，会把列表从 2 写回 3（3→2→3），同样触发该断言。
3. 历史页 swipe 删除路径先 `tasks.removeAll` 再 `await reload()`，一次删除产生两次列表变更，也存在同类竞态。

## 修复

- `AppCoordinator.returnToHistory()`：一次写入 `path = [.history]`，替代 pop+push 两步。
- `HistoryViewModel.removeDeletedTask(_:)`：一次变更移除行并递增 `loadGeneration`；`confirmDelete` 在 `.persisted` 时调用它，不再追加 reload。
- `reload()` 捕获 generation，落地前校验，过期结果直接丢弃。
- `TaskDetailView` 新增 `onDeleted` 回调：详情删除成功后先让历史 VM 移除该行，再 `returnToHistory()`；`RootView` 把回调接到共享的 `historyViewModel`。
- 顺带删除历史页的 `ModuleChrome`（#60 已由系统 toolbar 取代的遗留无调用组件）。

## 验证

- 新单测 `HistoryViewModelTests.staleReloadCannotResurrectDeletedRow`：门控 store 让过期读（3 行）悬停，删除第 2 行后放行；**禁用守卫时该用例失败（5 passed / 1 failed）**，恢复守卫后全绿。
- 新 UI 回归 `DuiyiUITests/HistoryDeleteTests`：`-duiyi.seedHistory`（DEBUG-only，先清空已结束任务再固定种 3 条）走“历史 → 详情 → 删除 → 确认”，断言回到一致的历史列表且进程存活；iOS 26.4 与 iOS 27.0 模拟器均通过。
- 全量：unit **380 logical / 406 expanded，0 failed / 0 skipped**；UI **11 logical / 10 expanded，0 failed**（仅已知模拟器语音 skip）；static PASS；generic iOS 真机构建 PASS。
- 设备端由用户用 Release 复测删除路径。

## 边界与说明

- 崩溃依赖更新合并时序，iOS 27.0/27.1 模拟器上简单删除流程未能重现；修复针对日志给出的精确算术（before 3 / after 3 / 1 deleted）与三条可解释路径，回归测试锁定 stale-reload 机制。
- `-duiyi.seedHistory` 仅 `#if DEBUG` 生效，供 UI 回归使用，不进入 Release。
- 未改删除语义、store API、持久化 schema；删除失败仍保留行并报错。
