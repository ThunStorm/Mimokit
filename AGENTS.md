# Mimokit — Agent 约定

## 项目

macOS 菜单栏工具集。当前主功能 **MImoMeter**：显示 Xiaomi MiMo Desktop 周额度剩余百分比。

- 设计规格：`docs/compose/spec/mimo-meter.md`
- 实现目录：`MImoMeter/`
- **直接在主 worktree 工作**（`Mimokit/`，branch `mimo/dev`），不使用 `.worktrees/`

## 命令

```sh
cd MImoMeter
swift build
swift run MImoMeter --run-self-tests   # 45 项纯逻辑自检
swift run MImoMeter --fetch-once       # 真实 SSO+usage 一次
swift run MImoMeter                    # 启动菜单栏应用（开发）
./Scripts/build-app.sh                 # 打包并安装 ~/Applications/MImoMeter.app
```

## 硬约束

- 不伪造 5h 窗口；服务端未返回则不渲染
- 不修改 `~/Library/Application Support/Xiaomi MiMo` 内任何文件
- 不把 passToken / serviceToken 写入日志或用户可见文件
- 本地桥 usage 404 必须静默回落平台 API，不算用户可见错误
- 本机仅有 CommandLineTools（无 XCTest）；测试走 `--run-self-tests`，不要依赖 `swift test`
- 不要在本仓库新建 worktree；改动直接落在主 worktree

## 发布

`Scripts/build-app.sh` 会：
1. `swift build -c release`
2. 生成 `.build/MImoMeter.app`（含图标、ad-hoc 签名）
3. 安装到 `~/Applications/MImoMeter.app`（路径稳定，供 SMAppService 登录项使用）
