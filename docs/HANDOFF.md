# HANDOFF — MImoMeter

## 现在处于什么状态

v1.1 已实现、打包并安装在本机 `~/Applications/MImoMeter.app`（2026-09-12）。

| 门禁 | 结果 |
| --- | --- |
| `--run-self-tests` | 45 checks PASSED |
| `--fetch-once` | 真实周额度 percent 可用 |
| `Scripts/build-app.sh` | 产出带图标、ad-hoc 签名的 `.app`，并装到 `~/Applications` |
| 登录项 | `.app` 内可勾选 SMAppService；`.notFound` 不再禁用勾选框 |
| 生命周期 | 跟随 MiMo 启停；未运行时 idle 壳显示 `--%` |
| 图标 | C6：白底圆角、白进度环+橙弧、黑色 MiMo 四图形 |

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

## 可选后续

- 通知「额度将尽」
- 系统设置登录项 UI 引导截图
- 若桥提供 `/v1/user/usage`，适配器已就位

## 恢复

```sh
cd /Volumes/D/Projects/Codework/XiaomiMiMoProjects/Mimokit/MImoMeter
swift run MImoMeter --run-self-tests
swift run MImoMeter --fetch-once
./Scripts/build-app.sh
open ~/Applications/MImoMeter.app
```
