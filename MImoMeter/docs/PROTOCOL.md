# MImoMeter 数据协议

## 1. 本地桥（通道 A，探测预留）

配置：`~/Library/Application Support/Xiaomi MiMo/desktop-api.json`

```json
{ "api": "http://127.0.0.1:19347", "port": 19347, "token": "...", "pid": 123 }
```

请求：

```http
GET {api}/v1/user/usage
Authorization: Bearer {token}
Accept: application/json
```

| 状态 | 映射 |
| --- | --- |
| 200 + `{data:{percent,resetDate,resetAt}}` | 可用 |
| 404 | `unsupported` → 静默回落 B |
| 401 | `unauthorized` → 静默回落 B |
| 连不上 / 超时 | `unavailable` → 静默回落 B |

**已知事实（2026-09-12 实测）**：`/v1/health` 200；`/v1/user/usage` **404**。路由前缀必须是 `/v1`。

## 2. Xiaomi SSO（通道 B 凭据）

凭据源（只读）：`~/Library/Application Support/Xiaomi MiMo/Partitions/xiaomi-account/Cookies`  
需要：`passToken`、`userId`、`cUserId`（host 含 `xiaomi.com`）

### Phase 1

```http
GET https://account.xiaomi.com/pass/serviceLogin?_locale=zh_CN&_snsNone=true&sid=mimopc&_json=true
Cookie: passToken=...; userId=...; cUserId=...
User-Agent: MiClaw/1.0
```

响应 body 前缀 `&&&START&&&`，剥掉后 JSON。`nonce` 与 `userId` **可能是数字**（实现用 FlexibleString 解码）：

```json
{
  "code": 0,
  "location": "https://mimo-server-cn.xiaomimimo.com/api/sts?...",
  "nonce": 6513982663636965376,
  "ssecurity": "a+dFrbO+j+tXs3zEz6HTAQ==",
  "userId": 8933039
}
```

响应头 `extension-pragma` 也含 `nonce`/`ssecurity`，可作回退。  
`code != 0` 或缺 `location`/`nonce`/`ssecurity` → `authExpired`。

### Phase 2 clientSign

```
sigInput    = "nonce=" + nonce + "&" + ssecurity
clientSign  = urlencode(base64(SHA1(sigInput)))   // SHA1 raw digest → base64 → percent-encode
GET {location}&clientSign={clientSign}
User-Agent: MiClaw/1.0
```

从 `Set-Cookie` 提取 `serviceToken`（取到第一个 `;`，token 可含 `+/=`）。

## 3. 平台用量（通道 B 主路径）

```http
GET {apiBase}/user/usage
Cookie: serviceToken={token}; userId={uid}
Accept: application/json
```

`apiBase` 默认 `https://mimo-server-cn.xiaomimimo.com/api`。

成功样本：

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

| 字段 | 语义 |
| --- | --- |
| `percent` | **剩余**百分比（Double，`>= 0`）；clamp `0...100` 后 round 成整数 |
| `resetAt` | Unix 秒，展示优先 |
| `resetDate` | `yyyy-MM-dd` 回退字符串 |

| 条件 | 状态 |
| --- | --- |
| HTTP 200 + `code=0` + 合法 percent | available |
| HTTP 401 | `authExpired`（可重试一次 SSO） |
| `code≠0` / 无 `data` | `no-data` |
| 非 JSON（HTML） | `failed` |
| 超时 10s | `failed` |

## 4. 归一化

顶层单对象且无 kind/duration → **强制 `weekly`**。  
多窗口时：`kindHint` 优先，其次 `windowDurationMins`（240–360 fiveHour / 9000–11000 weekly / 38000–50000 monthly）。

## 5. 任务状态（提示线，通道 A）

```http
GET {api}/v1/sessions?limit=20
Authorization: Bearer {token}

GET {api}/v1/sessions/{id}/messages
Authorization: Bearer {token}
```

推断规则（取最近 2h 内更新的 session 的最后一条 message）：

| 信号 | 映射 |
| --- | --- |
| tool `state.status == pending` | 需要处理（红） |
| assistant 且 `time.completed` 空，或存在 running tool / `step-finish reason=tool-calls` | 运行中（黄） |
| assistant 完成且 `step-finish reason=stop`，完成时间 ≤ 1h | 最近完成（绿） |
| 完成但 reason 非 stop 且含 error tool | 需要处理（红） |
| 桥不可达 / 无相关 session | 空闲（橙） |
| 无法解析 / 未知 reason | 状态未知（灰） |

多 session 优先级：红 > 黄 > 绿 > 灰 > 橙。轮询 15s，仅本地桥。

## 6. 展示

- 状态栏：`62%` 或 `--%`；可选 `W ` 前缀
- 菜单：每周剩余、重置时间、更新时间、打开 MiMo、刷新、设置、退出
- **不伪造 5h 窗口**；服务端未返回则不渲染
- 提示线（可选）：按任务状态着色，见第 5 节
