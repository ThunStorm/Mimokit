# BRIEF — MImoMeter

用户需要在 macOS 菜单栏常驻看到 Xiaomi MiMo Desktop 的账号周额度余量。

- 形态：Swift 原生 `NSStatusItem` 菜单栏应用
- 状态栏：周额度**剩余**整数百分比；不可用时 `--%`
- 取数：本机 cookies → `sid=mimopc` SSO → `GET {apiBase}/user/usage`
- 桥：`desktop-api` 当前无 usage，404 静默回落
- 生命周期：跟随 MiMo 启停；支持登录项
- 不伪造 5h 窗口
