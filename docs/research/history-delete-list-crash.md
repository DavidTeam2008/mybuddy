# 历史删除导致 List 无效更新崩溃（fix）

> 2026-11-25。现场：iPhone 13（iOS 27.2.1），Xcode Debug 运行。用户在历史页把筛选切到「面对面」，在列表里滑动删除任务后崩溃。本机已用同一路径在真机复现并修复。

## 症状

用户两次提供的 Xcode 控制台关键行（节选）：

```text
*** Assertion failure in -[SwiftUI.UpdateCoalescingCollectionView _Bug_Detected_In_Client_Of_UICollectionView_Invalid_Number_Of_Items_In_Section:], UICollectionView.m:10954
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
reason: 'Invalid update: invalid number of items in section 0. The number of items contained in an existing section after the update (2) must be equal to the number of items contained in that section before the update (2), plus or minus ... (0 inserted, 1 deleted) ...'
```

- 第一次：`before 3 / after 3 / 1 deleted`（修复前）。
- 第二次：`before 2 / after 2 / 1 deleted`（第一次修复上线后）。

两次都是历史页 List（全 App 唯一使用 `List` 的界面）。关键算术是 **`before == after` 且更新计划删除 1 行**：集合视图在提交删除差量时，数据源仍报告删除前的行数。App 没有死锁；是调试器在未捕获异常处暂停，用户看到“卡住”。

## 复现

用户澄清操作是「在面对面列表里删除」，即：历史页 → 点「面对面」筛选 → 列表只剩 2 条 → 左滑删除 1 条 → 确认删除。用自动化在真机上重建了该路径：

1. DEBUG 启动参数种入 4 条已结束任务（2 条面对面），每条 40 条转写；
2. 打开历史 → 切到「面对面」→ 确认 2 行；
3. 第一行左滑 → 点删除 → 确认删除。

**关掉修复时，App 在 iPhone 13（iOS 27.2.1）上崩溃**，系统崩溃报告（`EXC_CRASH` / `SIGABRT`）的主线程栈：

```text
-[NSAssertionHandler handleFailureInMethod:object:file:lineNumber:description:]
-[UICollectionView _Bug_Detected_In_Client_Of_UICollectionView_Invalid_Number_Of_Items_In_Section:]
-[UICollectionView _performBatchUpdates:...]
UpdateCoalescingCollectionView.performBatchUpdates(_:completion:)
UICollectionViewListCoordinatorBase.performUpdates(collectionView:shouldSetEditing:)
closure #2 in UICollectionViewListCoordinatorBase.update(_:to:transaction:performDiff:)
UpdateGroup.dispatchActions()
ViewGraphHostUpdate.dispatchImmediately(_:)
```

恢复修复后，同一用例通过。

## 根因

- 删除确认后，`HistoryViewModel.confirmDelete` 在同一个 view-graph 更新里做了两件事：把 `pendingDeletion` 置空（确认弹窗开始消失），以及 `removeDeletedTask(_:)` 把行集从 2 改成 1。
- SwiftUI 通过 `UpdateGroup.dispatchActions` 立即把这批变更分发给 `UICollectionViewListCoordinatorBase`，后者对 List 的底层 `UpdateCoalescingCollectionView` 执行 `performBatchUpdates`（删除 1 行）。
- 同一次更新中，集合视图的数据源仍返回旧行数（`before == after`），`UICollectionView` 的无效更新校验失败并抛出 `NSInternalInconsistencyException`。
- 第一次修复（`returnToHistory` 单次路径写入、`reload()` generation 守卫、删除只做一次变更、详情 `onDeleted`）去掉了几条竞态路径，但没有消除“行集变化的行级差量”本身；这次把崩溃缩小到筛选列表的滑动删除，并确认了同一条 List diff 机制。

## 修复

- 历史 `List` 以行集合作为视图身份：

  ```swift
  .id(viewModel.tasks.map(\.id))
  ```

  行集合变化时 SwiftUI 重建整个 `List`（销毁旧 collection view），不再向旧集合视图提交行级插入/删除差量；确认弹窗消失与行集变化同事务也不会触发 invalid update。删除、筛选、刷新导致的行集变化都走重建。
- 代价：行集变化时列表重新挂载，滚动位置回到顶部，删除行没有逐行动画。删除与筛选场景可接受。
- 为删除入口补 `accessibilityIdentifier`，测试不再依赖中文文案：
  - 历史滑动操作：`history-swipe-delete`
  - 历史删除确认：`history-delete-confirm`
  - 详情删除确认：`detail-delete-confirm`
  - 空列表：`history-empty`

## 验证

- `DuiyiUITests/HistoryDeleteTests`（XCTest）：
  1. `testFilteredSwipeDeleteKeepsHistoryListConsistent`：面对面筛选、2 行、40 条转写、滑动删除；**真机禁用 `.id` 时崩溃，恢复后通过**。
  2. `testRepeatedDetailDeletesKeepHistoryListConsistent`：40 条转写的任务连续从详情页删除 4 次（含空列表分支）。
  3. `testDeletingFaceToFaceTaskFromDetailKeepsHistoryListConsistent`：详情页删除单行。
- 真机（iPhone 13，iOS 27.2.1）：三条用例全通过。
- 模拟器：iOS 26.4 全量 UI 通过（13 logical / 12 expanded，仅已知语音 skip）；iOS 27.0 定向删除用例通过；单元 380 logical / 406 expanded，静态检查通过。
- 最终确认由用户在设备上用真实历史数据复测删除路径。

## 测试夹具（仅 DEBUG）

- `-duiyi.seedHistory`：清空已结束任务后固定种 4 条（2 条面对面、1 条同传、1 条会议）。
- `-duiyi.seedEntryCount <n>`：每条种子任务的转写条数，用来模拟真实任务长度。
- `-duiyi.storeFile <name>`：把 App 重定向到 `Application Support/UITestStores/<name>.store` 的隔离 SwiftData 库，真机 UI 测试不会碰用户真实历史。
- 三个参数都只在 `#if DEBUG` 生效，Release 构建不存在。

## 边界与说明

- 未改删除语义、store API、持久化 schema；删除失败仍保留行并报错。
- `.id` 只作用于历史 `List`；其他页面没有 `List`。
- 崩溃依赖真实任务长度（级联删除耗时）与确认弹窗消失的更新合并时序；40 条转写的夹具已在真机复现（禁用修复时），但复现率未统计。
