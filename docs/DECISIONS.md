# DECISIONS — MImoMeter

## 2026-09-12

1. **不移植 Codex 的 5h 优先逻辑**  
   MiMo 无 5h 窗口。选择器：weekly → fiveHour → monthly → unknown。

2. **主路径：平台 API + 官方 SSO；本地桥仅探测**  
   桥 `/v1/user/usage` 404；平台 API 可拿到 `{percent,resetDate,resetAt}`。

3. **测试用 `--run-self-tests`，不用 XCTest**  
   本机仅 CommandLineTools。

4. **SSO 字段用 FlexibleString；Phase2 跨重定向抓 Set-Cookie**  
   数字 nonce/userId；serviceToken 可能挂在 302 响应头。

5. **不在本仓库使用 worktree**  
   实现从 `.worktrees/mimo-meter` 迁回主 worktree（`mimo/dev`），后续直接改主目录。

6. **安装到 `~/Applications` 而非 `/Applications`**  
   免 sudo、路径稳定、便于 SMAppService。用户确认不需要系统级 Applications。

7. **登录项勾选框在 `.notFound` 时仍可点**  
   新装 ad-hoc app 常见 notFound，应允许尝试 `register()`。

8. **图标定稿 C6**  
   白进度环 + 橙弧 + 黑色 MiMo 四图形；去掉外框。

9. **展示提示线为可选设置**  
   默认关闭；与示数等宽、静态橙色；关闭时示数仍垂直居中。

## 2026-09-14

10. **提示线着色表示「项目任务状态」，不是额度取数状态**  
    语义：红=需要处理，黄=运行中，绿=10min 内成功完成，灰=未知异常，橙=空闲。（窗口 1h → 30min → 10min，过期回落橙）

13. **提示线短线与示数宽度对齐；成功态 10 分钟回落空闲**  
    `100%`→`99%` 时 NSStatusItem 不自动收窄会导致短线偏移：label 改为按字宽居中、短线等宽，并按测量宽度重设 `statusItem.length`。`recentSuccessWindow` 定为 600s。

11. **任务态来源：本地桥 sessions + messages 推断**  
    无 session 级 status；SSE 有 permission 事件但不补发。权限等待 = tool `running` 且无 `metadata`（有 `raw`）。

12. **`desktop-api.json` 的 `api` 兼容数字与字符串**  
    本机为 `{"api":1,...}`，按 String 解码会失败导致桥配置永远不可用。

## 2026-09-23

14. **生命周期按进程表 reconcile，不单信 terminate 通知**  
    MiMo 原地更新常见「新进程先 launch、旧进程后 terminate」。若 terminate 一到就 `stopMeter`，会把已在跑的新实例打回 idle 且不再拉起（菜单栏永久 `--%`）。决策抽成 `MeterLifecycle` 纯函数：terminate 后延迟 0.6s 再对照 `isMimoRunning`；另有 30s 定时器自愈错过的启停通知。

15. **桥 200 空载荷必须回落平台**  
    `/v1/user/usage` 若返回 200 但无可用 percent/窗口，不得短路 `applySuccessfulPayload`，应继续走平台 API；否则未来桥加了空路由会再次「取不到额度」。

