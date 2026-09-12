# Mimokit

Toolkit for mimo desktop.

## MImoMeter

macOS 菜单栏余量显示：状态栏常驻 Xiaomi MiMo 周额度剩余百分比。

- 文档：[MImoMeter/README.md](MImoMeter/README.md)
- 构建并安装到 `~/Applications`：

```sh
cd MImoMeter
./Scripts/build-app.sh
open ~/Applications/MImoMeter.app
```

开发调试：

```sh
cd MImoMeter
swift run MImoMeter --run-self-tests   # 纯逻辑自检
swift run MImoMeter --fetch-once       # 真实 SSO+usage 一次
swift run MImoMeter                    # 启动菜单栏（开发用，登录项不可用）
```
