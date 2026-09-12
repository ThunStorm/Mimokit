---
feature: mimo-meter
status: implemented
updated: 2026-09-12
branch: mimo/dev
commits: 06855bb..HEAD
---

# MImoMeter — MiMo Desktop 余量菜单栏

## Report

## [S1] Problem

用户需要在 macOS 菜单栏常驻看到 **Xiaomi MiMo Desktop** 的账号用量余量，而不必打开 MiMo 设置页。

参考实现 `CodexMenuMeter_MAC` 针对 Codex：通过官方 `codex app-server` 读取 5h/周双窗口额度。**MiMo 当前产品侧没有 5h 窗口**——设置页仅有「每周使用限额」，数据契约为单窗口 `{percent, resetDate}`。若照搬 Codex 的 5h 优先逻辑会误导用户。

本功能在 Mimokit 仓库内交付原生 macOS 菜单栏伴随应用 **MImoMeter**：读取并展示 MiMo 周额度余量，同时把窗口模型做成可扩展预留，以便服务端未来返回多窗口时无需重写选择器与 UI。

## [S2] Design

### S2.1 产品决策（已锁定）

| 决策 | 选择 |
| --- | --- |
| 形态 | Swift 原生菜单栏应用（NSStatusItem），对齐 CodexMenuMeter |
| 状态栏主数字 | 周额度剩余百分比；无数据时 `--%` |
| 5h 窗口 | **不造假、不优先**。模型保留 kind，服务端未返回则不渲染 |
| 取数 | **主路径：平台 API + 官方 SSO**；本地桥仅探测预留（当前无 usage） |
| 任务状态点 | v1 不做真实任务状态；默认关闭的 UI 预留可与参考一致但不阻塞交付 |
| 安全 | 只读本机 MiMo 账号分区 cookie；不外传、不落盘明文；不修改 MiMo 配置；不解析进程内存 |

### S2.2 数据源事实（本机实测 2026-09-12，实现必须遵守）

#### 调研结论摘要

| 通道 | 能否拿到用量 | 证据 |
| --- | --- | --- |
| A 本地桥 desktop-api | **不能（当前）** | Bearer 下 `GET /v1/health` → 200 `{ok,api:1,engine:"ready"}`；`GET /v1/user/usage` 等候选 → 404 not-found |
| B 平台 API | **能（已端到端验证）** | 完成 `sid=mimopc` SSO 后 `GET .../api/user/usage` → `{"code":0,"message":"success","data":{"percent":97.6,"resetDate":"2026-09-17","resetAt":1789650777}}` |
| A/B 一致性 | **无法对比** | A 无 usage 字段，谈不上一致性；A 将来接入时必须映射到同一 `RawUsagePayload` |

#### 通道 A — 本地桥（探测预留，v1 不依赖）

- 配置：`~/Library/Application Support/Xiaomi MiMo/desktop-api.json` → `{api, port, token, pid}`
- HTTP：`http://127.0.0.1:<port>`，鉴权 **仅** `Authorization: Bearer <token>`（query/header 错误会 401）
- **路由前缀必须是 `/v1`**（`fh=1`）。已验证：
  - `GET /v1/health` → 200
  - `GET /v1/sessions?limit=N` → 200
  - `GET /v1/user/usage` / `/v1/usage` / `/v1/account/usage` → 404（**无用量能力**）
- v1 行为：每次刷新可先 `GET /v1/user/usage`；404/401/连不上 → **静默回落 B**，不算错误
- 若未来 MiMo 增加 usage 路由，适配器必须产出与 B 相同的 `RawUsagePayload`（percent 语义=剩余）

#### 通道 B — 平台 API（v1 主路径，已验证）

- `apiBase`：默认 `https://mimo-server-cn.xiaomimimo.com/api`；可用 `MIMO_API_BASE_URL` 覆盖
- 响应契约（真实样本，**注意还有 `resetAt`**）：

```json
{
  "code": 0,
  "message": "success",
  "data": {
    "percent": 97.6,
    "resetDate": "2026-09-17",
    "resetAt": 1789650777
  }
}
```

- `percent`：**剩余**百分比，`Double`，有限且 `>= 0`；clamp 到 `0...100` 后 `round` 成菜单栏整数
- `resetAt`：Unix 秒（优先展示重置时间）；`resetDate` 作回退字符串
- HTTP `401` → `authExpired`；其它非 2xx → `failed`；`code != 0` / 缺 `data` → `no-data`
- 超时 10s → `failed`；stale 见 S2.5

#### 鉴权（通道 B）— 官方 SSO，已跑通

只读本机 MiMo 账号分区 cookies（本机为**明文 `value` 列**，`encrypted_value` 为空）：

`~/Library/Application Support/Xiaomi MiMo/Partitions/xiaomi-account/Cookies`  
需要：`passToken`、`userId`、`cUserId`（host：`.account.xiaomi.com` / `.xiaomi.com`）

**两阶段换 `serviceToken`（sid = `mimopc`）**：

1. **Phase 1**  
   `GET https://account.xiaomi.com/pass/serviceLogin?_locale=zh_CN&_snsNone=true&sid=mimopc&_json=true`  
   Cookie：`passToken`、`userId`、`cUserId`  
   UA 建议：`MiClaw/1.0` 或 `XiaomiMiMo/<appVersion>`  
   Body 前缀 `&&&START&&&`，剥掉后 JSON；同时读响应头 `extension-pragma`（含 `nonce`/`ssecurity`）。  
   成功：`code==0`，body 含 `location`、`nonce`、`ssecurity`、`userId`。

2. **Phase 2 clientSign**  
   ```
   sigInput  = "nonce=" + nonce + "&" + ssecurity
   clientSign = urlencode(base64(SHA1(sigInput)))   // SHA1 digest → base64
   GET location + "&clientSign=" + clientSign
   ```  
   响应 `Set-Cookie: serviceToken=...; Domain=mimo-server-cn.xiaomimimo.com`（另有 `mimopc_slh`、`mimopc_ph`）。  
   Phase 2 **不需要**再带 account cookies。

3. **调用量**  
   `GET {apiBase}/user/usage`  
   Cookie：`serviceToken=<token>; userId=<uid>`

失败映射：phase1 `code!=0` / 缺 location → `authExpired`；phase2 非 200 → `authExpired`；usage 401 → `authExpired` 并触发一次 SSO 重试。

**禁止**：注入 MiMo 进程、导出 Keychain、把 passToken/serviceToken 写入日志或用户可见文件。临时 token 只存在内存。

**不采用**

- 仅带 partition cookies 直接打 `/user/usage`（实测 401）
- 仅带 `passToken` 作 `Authorization: Bearer`（实测 401）
- 把 `platform.xiaomimimo.com` 的 HTML SPA 当 JSON
- OCR / 进程内存 / 伪造 5h 窗口

### S2.3 域模型（窗口预留核心）

```swift
enum UsageWindowKind: String, Sendable, Equatable {
  case fiveHour   // 预留；当前服务端不返回
  case weekly     // v1 唯一实际窗口
  case monthly    // 预留
  case unknown    // 时长可识别但不在已知档位
}

struct UsageWindow: Sendable, Equatable, Identifiable {
  let id: String
  let kind: UsageWindowKind
  let remainingPercent: Int   // round/clamp 后的剩余
  let usedPercent: Double?    // 若仅有 remaining 则 100-remaining
  let durationMinutes: Int?   // 当前周窗可为空
  let resetsAt: Date?
  let receivedAt: Date
}

struct RawUsagePayload: Sendable, Equatable {
  // 通道无关的原始字段；由适配器归一化
  var remainingPercent: Double?
  var usedPercent: Double?
  var resetDate: String?
  var resetAtUnix: Int?       // 优先于 resetDate
  var windows: [RawWindow]    // 服务端若返回数组则填充
}

struct RawWindow: Sendable, Equatable {
  var id: String?
  var kindHint: String?       // 服务端 kind 字面量，若有
  var windowDurationMins: Int?
  var remainingPercent: Double?
  var usedPercent: Double?
  var resetsAt: Date?
}
```

**分类规则**

1. 若 `kindHint` 可映射（`five_hour`/`5h`/`weekly`/`week`/`monthly`/`month`）→ 对应 kind
2. 否则若有 `windowDurationMins`：`240...360`→fiveHour；`9000...11000`→weekly；`38000...50000`→monthly；其它→unknown
3. 否则若为顶层单对象（当前 MiMo 形态）→ **强制 kind = weekly**（产品事实：只有周限额）
4. 无效百分比（非有限或 `<0`）→ 丢弃该窗

**选择器**

- `selectDisplayedWindow(_:)`：
  - v1：返回第一个 `weekly`；若无 weekly 则按 fiveHour → monthly → unknown 优先级返回第一个
  - **不做** Codex 的「weekly=0% 覆盖 5h」特例——MiMo 无 5h；若未来同时有双窗，再单独立项
- `selectMenuWindows(_:)`：按 `fiveHour → weekly → monthly → unknown` 稳定排序；同 kind 取第一个；**只渲染服务端真实返回的窗**

### S2.4 展示契约

状态栏：

- 可用：`"62%"`（可选设置 `showQuotaPeriod` 打开时前缀 `"W "`）
- 不可用 / 加载中 / 过期：`"--%"`
- 颜色：剩余 ≥20% 系统默认；`1...19` 可选用 warning 色（可配置，默认关闭）；`0%` 用红色
- Tooltip / a11y：`MiMo，每周额度剩余 62%，9月18日 15:00 重置`

菜单（自上而下）：

1. 标题「MiMo 额度」（disabled）
2. 分隔线
3. 对每个 `selectMenuWindows` 结果：`每周：剩余 62%` + `重置：...`；无窗口则「额度：暂不可用」
4. `更新：相对时间`
5. 分隔线
6. 「打开 MiMo」→ `NSWorkspace` open bundle id `com.xiaomi.mimo.desktop`，回退路径 `/Applications/Xiaomi MiMo.app`
7. 「刷新」
8. 分隔线
9. 「设置…」：CLI/API Base 覆盖、刷新间隔、是否显示周期前缀、是否随登录启动（`SMAppService`）
10. 「退出 MImoMeter」

### S2.5 架构与数据流

```text
Timer / 手动刷新 / 从睡眠唤醒
  → AppState.refresh()
  → LocalBridgeProbe  (desktop-api.json → Bearer GET candidates)
      ok  → RawUsagePayload
      miss→ PlatformUsageClient
                → CredentialSource
                → GET {apiBase}/user/usage
  → UsageNormalizer → [UsageWindow]
  → UsageSelector.selectDisplayedWindow / selectMenuWindows
  → AppState.usage + quotaWindows
  → MenuBarDisplayState → StatusItemView / NSMenu
```

- UI **永不**直接发 HTTP
- 所有错误先入 `AppState`，再变成 `MenuBarDisplayState`
- 轮询：默认 60s；失败退避：连续失败时最多延长到 5min；成功后恢复 60s
- Stale：距 `lastUpdatedAt` > 5min 且无成功刷新 → `usage = .stale`，状态栏 `--%`，清空 window 缓存展示

### S2.6 工程布局（worktree 内 `MImoMeter/`）

```text
MImoMeter/
  Package.swift
  Sources/MImoMeter/
    MImoMeterApp.swift
    AppState.swift
    Domain.swift
    UsageSelector.swift
    Normalizer.swift
    LocalBridgeClient.swift
    PlatformUsageClient.swift
    CredentialSource.swift
    ProcessLocator.swift          // 定位 MiMo.app / 配置目录
    DesktopAPIConfig.swift        // 解析 desktop-api.json
    JSONHTTPClient.swift
    StatusItemController.swift
    StatusItemView.swift
    SettingsController.swift
  Tests/MImoMeterTests/
    UsageSelectorTests.swift
    NormalizerTests.swift
    DesktopAPIConfigTests.swift
  Resources/
    Info.plist                    // LSUIElement = true
  Scripts/
    build-app.sh
  docs/
    ARCHITECTURE.md
    PROTOCOL.md
    compose/spec/mimo-meter.md    // 本文档（实现时同步勾选任务）
```

`Package.swift`：`platforms: [.macOS(.v14)]`，可执行 target `MImoMeter` + test target。

### S2.7 错误与状态机

```swift
enum UsageDisplayState: Sendable, Equatable {
  case loading
  case available(UsageWindow)
  case unavailable(reason: String)
  case stale
}

enum ConnectionState: Sendable, Equatable {
  case disconnected, connecting, connected
  case failed(String)
}
```

错误文案（中文）：

| 条件 | 文案 |
| --- | --- |
| 桥 404 且 API 401 | 小米登录已过期，请打开 MiMo 重新登录 |
| 桥 404 且 API 非 JSON/HTML | 用量接口无数据，请确认已登录小米账号 |
| 配置缺失且 API 失败 | 未找到正在运行的 MiMo，且平台接口不可用 |
| 解析失败 | 用量数据格式无效 |
| 超时 | 请求超时 |

### S2.8 测试边界

必须覆盖（纯逻辑，无网络）：

1. 顶层 `{percent,resetDate}` → 单个 weekly 窗
2. `percent` 缺失/负数/NaN → 丢弃
3. 多窗口数组 + duration 分类（5h/week/month/unknown）
4. `selectDisplayedWindow` 在仅有 weekly、空列表、多 kind 时的行为
5. `selectMenuWindows` 排序与去重
6. `desktop-api.json` 合法/缺字段/坏 JSON
7. 平台响应：`code=0`、`code!=0`、HTTP401、HTML body、超时

不要求 v1：真实登录 E2E、MiMo 进程拉起、UI 快照。

### S2.9 安全边界

- 仅读取本机 MiMo userData 下的配置/cookies（只读）
- 仅向 `127.0.0.1` 与已知 `*.xiaomimimo.com` apiBase 发请求
- 子进程：无（v1 不 spawn MiMo）
- 不写 MiMo 目录；设置写入本 app 的 `UserDefaults` / 自身 Application Support
- 卸载：退出 app、关登录项、删 `.app`

## [S3] Out of Scope

- 真实任务运行状态色点 / thread 订阅
- Windows / Linux
- 自动登录、代填小米账密、SSO 刷新 UI
- 修改 MiMo 源码或为其补 desktop-api 路由
- 月度/5h 产品策略与配额计算
- App Store 分发与公证流水线（本地 `build-app.sh` 即可）
- 通知中心「额度将尽」推送（可列为后续）

## Tasks

- [x] T1: 初始化 SPM 工程骨架 — acceptance: `swift build` 与 `swift test` 在空 Domain 下通过；`Package.swift` 含 macOS 14 可执行与测试 target (covers: S2.6)
- [x] T2: 实现 Domain + UsageSelector + Normalizer — acceptance: S2.8 列出的选择器/归一化测试全部通过；Normalizer 接受 `resetAtUnix` (covers: S2.3)
- [x] T3: 实现 DesktopAPIConfig + LocalBridgeClient 探测 — acceptance: 对 fixture 配置解析正确；`/v1/user/usage` 404 返回 `.unsupported` 不抛错 (covers: S2.2, S2.7)
- [x] T4: 实现 Xiaomi SSO（phase1+clientSign+phase2）+ PlatformUsageClient — acceptance: mock HTTP 下完整 SSO 与 usage 映射测试通过；本机手工 SSO 能拿到与设置页一致的 percent；日志无凭证明文 (covers: S2.2, S2.9)
- [x] T5: 实现 AppState 双通道回落 — acceptance: 单元测试证明桥 unsupported → 调用 SSO+API；失败不清成假 100%；stale>5min 显示 `--%` (covers: S2.2, S2.5, S2.7)
- [x] T6: 实现 StatusItem UI + 菜单 + 设置窗 — acceptance: `swift run MImoMeter` 在已登录 MiMo 时菜单栏显示周余量；未登录显示 `--%` 与原因；「打开 MiMo」能启动 bundle (covers: S2.4; depends: T5)
- [x] T7: 打包脚本与文档 — acceptance: `Scripts/build-app.sh` 产出 `LSUIElement` 的 `.app`；`docs/PROTOCOL.md` 记录 SSO+API 契约；README 写清构建/权限/卸载 (covers: S2.6, S2.2)
- [x] T8: 本机验证清单 — acceptance: 真实登录路径拿到 percent，且与 MiMo 设置页周额度一致（允许刷新延迟）；桥 miss 时不报错 (covers: S2.2, S2.4)

> 注：本机仅有 CommandLineTools（无 XCTest），测试命令为 `swift run MImoMeter --run-self-tests`（45 checks）。

### 实现顺序（agent 执行）

1. Workspace 已在 `.worktrees/mimo-meter`（branch `mimo/meter`）
2. T1 → T2（可并行于 T3 的协议草稿，但合并前测试须绿）
3. T3、T4 可并行
4. T5 依赖 T2–T4
5. T6 依赖 T5
6. T7、T8 收尾
7. Verify：`cd MImoMeter && swift run MImoMeter --run-self-tests && swift build`
8. Review：对照本节 acceptance 逐条打勾

### 验收摘要（交付门禁）

- [x] 无 5h 时状态栏不会显示伪 5h 标签
- [x] 有周额度时状态栏为剩余整数百分比，与设置页一致（`--fetch-once` → percent=97）
- [x] 未登录 / SSO 失败时有可读中文原因
- [x] 测试覆盖 S2.8 + SSO 签名向量（`--run-self-tests`）
- [x] 不修改 `~/Library/Application Support/Xiaomi MiMo` 内任何文件

## Journey log

- 参考项目 `CodexMenuMeter_MAC` 的 5h 优先 + weekly=0% 覆盖逻辑 **不可**直接移植到 MiMo。
- desktop-api 路由前缀是 `/v1`；`/health` 等无前缀路径全是 404。Bare `/v1/user/usage` 亦 404——桥当前无用量。
- 仅带 partition cookies 打 `/user/usage` 会 401；必须走 `sid=mimopc` 两阶段 SSO（`clientSign=urlencode(base64(sha1("nonce=..&ssecurity")))`）换 `serviceToken`。
- 真实 usage 响应除 `percent`/`resetDate` 外还有 `resetAt`（Unix 秒），展示应优先用它。
- 双通道「A 优先」在 v1 是探测预留，不是可依赖数据源；主路径是 B。
