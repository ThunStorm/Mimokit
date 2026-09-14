# Mimokit

Toolkit for Xiaomi MiMo Desktop.

## MImoMeter

<p align="center">
  <img src="MImoMeter/Resources/AppIcon.png" alt="MImoMeter" width="72" height="72">
</p>

macOS 菜单栏余量显示：状态栏常驻 Xiaomi MiMo 周额度剩余百分比，并可选用提示线反映项目任务状态。

- 文档：[MImoMeter/README.md](MImoMeter/README.md)

```sh
cd MImoMeter
./Scripts/build-app.sh
open ~/Applications/MImoMeter.app
```

开发调试：

```sh
cd MImoMeter
swift run MImoMeter --run-self-tests    # 纯逻辑自检
swift run MImoMeter --fetch-once        # 真实 SSO+usage 一次
swift run MImoMeter --task-status-once  # 实时任务状态一次
swift run MImoMeter                     # 启动菜单栏（开发用，登录项不可用）
```

## TODO

- [ ] MImoMeter：多任务并发测试
- [ ] MImoMeter：迁移 Windows 版
