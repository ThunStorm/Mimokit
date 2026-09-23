# HANDOFF — MImoMeter

## 现在处于什么状态

v1.2.3：修复提示线标红误报（并行工具 / `task` 的 raw 载荷被当成权限等待）。此前 v1.2.2 已修 MiMo 更新后卡 `--%` 的生命周期竞态。已打包安装 `~/Applications/MImoMeter.app`（2026-09-23）。

| 门禁 | 结果 |
| --- | --- |
| `--run-self-tests` | 82 checks PASSED |
| `--fetch-once` | 真实周额度 percent 可用 |
| `--task-status-once` | 运行中为黄；权限/失败才红（不再把 task raw 误判红） |
| `Scripts/build-app.sh` | 产出带图标、ad-hoc 签名的 `.app`，并装到 `~/Applications` |
| 生命周期 | 跟随 MiMo 启停；更新换代不拆 meter；30s reconcile 自愈 |

## 关键路径

- 根目录：仓库根 `Mimokit/`（branch `mimo/dev`）
- 代码：`MImoMeter/Sources/MImoMeter/`
- 规格：`docs/compose/spec/mimo-meter.md`
- 协议：`MImoMeter/docs/PROTOCOL.md`
- 架构：`MImoMeter/docs/ARCHITECTURE.md`

## 实现要点 / 坑

1. SSO Phase1 的 `nonce`/`userId` 可能是 **JSON 数字**（`FlexibleString`）。
2. Phase2 的 `serviceToken` 可能在 302 的 `Set-Cookie` 上，必须跨重定向捕获。
3. Cookie DB 需先拷贝再读，避免 MiMo 进程锁。
4. `serviceToken` 内存缓存约 30 分钟，失败/401 再 SSO。
5. 本机无 XCTest；用 `--run-self-tests`。
6. `SMAppService` 需要真正的 `.app` + 稳定路径（`~/Applications`）。
7. `desktop-api.json` 的 `api` 可能是 **数字**（版本）而非 URL，必须用 `FlexibleString` 解析；`baseURL` 回退 `127.0.0.1:port`。
8. 权限确认时 probe 工具（bash/edit/write/read）可能 `running` + `raw` 无 `metadata`；真正执行才有 `metadata`。**不要**据此一刀切判红——见第 11 条。SSE 有 `permission` 事件但不补发历史。
9. `NSStatusItem` 对 custom subview **不会**随文字变短自动收窄；示数/短线必须按字宽布局，并显式设置 `statusItem.length`。
10. **MiMo 原地更新会新旧进程交叠**（新进程先 launch，旧进程后 terminate）。绝不能只凭 terminate 就拆 meter；`MeterLifecycle` 延迟 0.6s 后按进程表 reconcile，每 30s 自愈。
11. **`raw` 无 `metadata` ≠ 权限等待**。`task` 等工具运行态就是 raw；并行启动也会短暂 raw-only。只有 bash/edit/write/read 等 probe 工具，同批无 metadata 且 start>3s，才判红。见 DECISIONS #16。

## 提示线任务状态（v1.2.3）

- 设置勾选「展示提示线」后生效；15s 轮询本地桥 sessions/messages
- 颜色：黄=运行中，绿=**10min** 内成功，红=需要处理（权限/失败），灰=未知，橙=空闲
- 判红收紧：pending、真权限等待（probe 工具 raw-only>3s 且同批无 metadata）、error/aborted/interrupted；**不再**把并行启动的 raw sibling 或 `task` raw 判红
- 多会话优先级：红 > 黄 > 绿 > 灰 > 橙
- 短线与示数等宽居中；`100%`→`99%` 等位数变化时保持对齐

## 可选后续

- 通知「额度将尽」
- SSE 订阅以降低权限态延迟
- 若桥提供 `/v1/user/usage`，适配器已就位（空/无效 body 会回落平台）

## 恢复

```sh
cd /Volumes/D/Projects/Codework/XiaomiMiMoProjects/Mimokit/MImoMeter
swift run MImoMeter --run-self-tests
swift run MImoMeter --fetch-once
swift run MImoMeter --task-status-once
./Scripts/build-app.sh
open ~/Applications/MImoMeter.app
```
