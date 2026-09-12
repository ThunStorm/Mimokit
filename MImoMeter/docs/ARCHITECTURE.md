# MImoMeter 架构

```text
Timer / 手动刷新 / 从睡眠唤醒
  → AppState.refreshNow()
  → LocalBridgeClient.probeUsage()     // desktop-api.json + Bearer GET /v1/user/usage
      payload     → RawUsagePayload
      unsupported → PlatformUsageClient（主路径）
                     → CredentialSource（只读 cookies SQLite）
                     → XiaomiSSOClient（phase1 + clientSign + phase2）
                     → GET {apiBase}/user/usage
  → Normalizer.windows(from:) → [UsageWindow]
  → UsageSelector.selectDisplayedWindow / selectMenuWindows
  → AppState.usage + quotaWindows
  → MenuBarDisplayState → StatusItemController / StatusItemView / NSMenu
```

## 模块

| 文件 | 职责 |
| --- | --- |
| `Domain.swift` | `UsageWindow` / `RawUsagePayload` / 显示状态 / 错误文案 |
| `UsageSelector.swift` | 窗口分类与选择（weekly 优先，不伪造 5h） |
| `Normalizer.swift` | 通道无关 payload → `[UsageWindow]` |
| `DesktopAPIConfig.swift` | `desktop-api.json` 解析 + MiMo 路径定位 |
| `LocalBridgeClient.swift` | 通道 A 探测 |
| `CredentialSource.swift` | 只读账号分区 cookies |
| `PlatformUsageClient.swift` | SSO + 平台用量 |
| `JSONHTTPClient.swift` | URLSession 封装（10s 超时） |
| `AppState.swift` | 双通道回落、轮询退避、stale、token 缓存 |
| `StatusItem*` / `SettingsController` / `LaunchAtLogin` | 菜单栏 UI、设置、登录项 |
| `SelfTests.swift` | 进程内自测（CLT 无 XCTest 时可用） |

## 生命周期（对齐 Menu Meter）

```text
应用启动
  → 若 MiMo 已在运行 → startMeter()
  → 否则 idle 壳（--%，等待 MiMo）
MiMo launch 通知 → startMeter()
MiMo terminate 通知 → stopMeter() → idle 壳
```

## 轮询

- 默认 60s（设置可改，最小 30s）
- 连续失败退避：60 → 120 → 240 → 300s 封顶
- 距 `lastUpdatedAt` > 5min 且无成功刷新 → `stale`，状态栏 `--%`，清空 window 缓存

## UI 约束

- UI **永不**直接发 HTTP
- 错误先入 `AppState`，再变成 `MenuBarDisplayState`
- 桥失败不展示；仅平台失败才显示中文原因
