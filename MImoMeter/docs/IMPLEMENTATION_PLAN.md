# MImoMeter — Agent 执行计划

> 权威设计见 [`docs/compose/spec/mimo-meter.md`](../../docs/compose/spec/mimo-meter.md)。本文件是实现阶段的逐步指令，不替代 spec。  
> **取数主路径已实测打通**：平台 API + `sid=mimopc` SSO。本地桥当前 **没有** usage 路由。

## 0. 环境

- 工作区：`Mimokit/.worktrees/mimo-meter`（branch `mimo/meter`）
- 代码根：`MImoMeter/`
- 工具：Xcode CLT / Swift 5.9+（目标 macOS 14+）
- 参考（只读）：`/Volumes/D/Projects/Codework/Git/Codexkit/CodexMenuMeter_MAC`

```sh
cd /Volumes/D/Projects/Codework/XiaomiMiMoProjects/Mimokit/.worktrees/mimo-meter/MImoMeter
swift --version
```

## 1. T1 — SPM 骨架

创建 `Package.swift`：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MImoMeter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MImoMeter", targets: ["MImoMeter"])],
    targets: [
        .executableTarget(name: "MImoMeter"),
        .testTarget(name: "MImoMeterTests", dependencies: ["MImoMeter"]),
    ]
)
```

**验收**：`swift test` PASS。

## 2. T2 — Domain / Normalizer / Selector

| 参考 Codex | MImoMeter |
| --- | --- |
| `usedPercent` 主导 | 平台给的是 `percent`（**剩余**） |
| 5h 优先 | weekly 优先；无 weekly 再 fiveHour/monthly/unknown |
| monthly 不显示 | 仅当服务端返回才显示 |

- `Normalizer` 必须读 `data.resetAt`（Unix 秒，优先）与 `data.resetDate`
- 顶层单对象且无 kind/duration → **强制 weekly**

## 3. T3 — 本地桥（预留探测）

- 配置：`~/Library/Application Support/Xiaomi MiMo/desktop-api.json`
- 鉴权：`Authorization: Bearer <token>` **only**
- 路由前缀 **`/v1`**：`GET /v1/user/usage`
- 实测：`/v1/health` 200；`/v1/user/usage` **404**
- 404/401/连不上 → `.unsupported` / `.unavailable`，**静默回落 B**

## 4. T4 — Xiaomi SSO + 平台用量（主路径）

### 4.1 读本机凭据（只读）

表：`Partitions/xiaomi-account/Cookies` → `cookies(host_key,name,value)`  
需要 `passToken`（本机明文 value，约 367 字符）、`userId`、`cUserId`。

### 4.2 Phase 1

```http
GET https://account.xiaomi.com/pass/serviceLogin?_locale=zh_CN&_snsNone=true&sid=mimopc&_json=true
Cookie: passToken=...; userId=...; cUserId=...
User-Agent: MiClaw/1.0
```

- Body 前缀 `&&&START&&&`，剥掉后 parse JSON
- 同时读响应头 `extension-pragma` 作为 `nonce`/`ssecurity` 回退
- 需要：`code==0`、`location`、`nonce`、`ssecurity`、`userId`

### 4.3 Phase 2 clientSign

```text
sigInput   = "nonce=" + nonce + "&" + ssecurity
clientSign = urlencode( base64( SHA1(sigInput) ) )   // SHA1 raw digest → base64
GET {location}&clientSign={clientSign}
User-Agent: MiClaw/1.0
```

从 `Set-Cookie` 提取 `serviceToken`（domain `mimo-server-cn.xiaomimimo.com`）。  
实现注意：token 含 `+/=`，解析要取到第一个 `;`。

### 4.4 用量

```http
GET https://mimo-server-cn.xiaomimimo.com/api/user/usage
Cookie: serviceToken=<token>; userId=<uid>
Accept: application/json
```

成功体（已验证）：

```json
{"code":0,"message":"success","data":{"percent":97.6,"resetDate":"2026-09-17","resetAt":1789650777}}
```

### 4.5 映射

| 条件 | 状态 |
| --- | --- |
| HTTP 200 + code=0 + data.percent 有限 | available |
| HTTP 401 | authExpired（可重试一次 SSO） |
| code≠0 / 无 data | no-data |
| 非 JSON（HTML） | failed |
| 超时 | failed |

日志禁止输出 passToken / serviceToken 全文。

## 5. T5 — AppState 回落

```text
bridge.probe() == unsupported/unavailable
  → sso.ensureServiceToken()
  → platform.getUsage()
```

- 失败不得保留旧 percent 冒充当前值
- 60s 轮询；失败退避至 5min；stale >5min → `--%`

## 6. T6 — 菜单栏 UI

- bundle：`com.xiaomi.mimo.desktop` / `/Applications/Xiaomi MiMo.app`
- 状态栏：`97%`（round）；不可用 `--%`
- 菜单：每周剩余、重置（优先 `resetAt` 本地时间）、更新时间、打开 MiMo、刷新、设置、退出
- `Info.plist`：`LSUIElement = true`

## 7. T7 — 打包与文档

- `Scripts/build-app.sh`
- `docs/PROTOCOL.md`：写入上述 SSO + usage 契约（**含 clientSign 公式**）
- README：构建、运行、仅读本机 cookie 的说明、卸载

## 8. T8 — 本机验证

```sh
swift test && swift build && swift run MImoMeter
```

手测：

1. 已登录 MiMo → 状态栏 percent 与设置页「每周使用限额」一致（允许刷新延迟）
2. 清空/改坏 cookies 权限 → 显示登录原因，不崩溃
3. 拔掉网络 → failed/stale，`--%`
4. 「打开 MiMo」「退出」正常
5. 桥 404 时静默走 API，菜单不报桥错误

## 9. Verify 门禁

| 命令 | 期望 |
| --- | --- |
| `swift test` | 全绿（含 SSO 签名向量、Normalizer、Selector） |
| `swift build` | 成功 |
| 真实 usage 一次 | percent 为有限数 |

## 10. 明确不做

- 不写入 MiMo userData
- 不实现真实任务状态
- 不伪造 5h
- 不把「仅 cookies 直连 usage」当作有效路径（已证 401）
