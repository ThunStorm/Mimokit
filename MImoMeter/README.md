# MImoMeter

macOS 菜单栏常驻 **Xiaomi MiMo Desktop** 周额度余量。

状态栏主数字为周额度**剩余**百分比（如 `97%`）；无数据时显示 `--%`。

## 安装 / 运行

```sh
cd MImoMeter
./Scripts/build-app.sh
open ~/Applications/MImoMeter.app
```

双击 `~/Applications/MImoMeter.app` 即可；菜单栏出现示数。设置中可勾选「登录时启动，并跟随 MiMo」。

## 行为

- **MiMo 打开** → 自动开始读取额度
- **MiMo 退出** → 状态栏变为等待态（`--%`）
- **登录启动** → 常驻后台，跟随 MiMo 启停
- 可选设置：周期前缀、1–9% 红字、展示提示线、刷新间隔、API Base
- **提示线任务状态**（开启「展示提示线」后生效）：黄=运行中，绿=1h 内成功完成，红=需要处理，灰=未知异常，橙=空闲

## 自测 / 一次性拉取

```sh
swift run MImoMeter --run-self-tests   # 纯逻辑自检（无网络）
swift run MImoMeter --fetch-once       # 真实 SSO + usage 一次
```

## 数据路径

1. **本地桥探测（预留）**  
   `GET http://127.0.0.1:<port>/v1/user/usage`（Bearer）  
   当前 **404** → 静默回落平台 API。

2. **平台 API（主路径）**  
   只读本机 MiMo 账号分区 cookies → `sid=mimopc` 两阶段 SSO → `serviceToken`  
   → `GET {apiBase}/user/usage`。  
   `percent` 为**剩余**百分比；`resetAt`（Unix 秒）优先于 `resetDate`。

默认 `apiBase`：`https://mimo-server-cn.xiaomimimo.com/api`  
可用环境变量 `MIMO_API_BASE_URL` 或设置窗覆盖。

## 安全边界

- 只读本机 MiMo userData 下配置/cookies；**不修改** MiMo 目录任何文件
- 不外传凭证；token 仅存内存（缓存约 30 分钟），不写日志
- 仅请求 `127.0.0.1` 与已知 `*.xiaomimimo.com`
- 无子进程、不注入 MiMo 进程

## 卸载

1. 菜单「退出 MImoMeter」
2. 关闭登录项（系统设置 → 通用 → 登录项）
3. 删除 `~/Applications/MImoMeter.app`

## 文档

- 设计规格：`../docs/compose/spec/mimo-meter.md`
- 协议契约：`docs/PROTOCOL.md`
- 架构说明：`docs/ARCHITECTURE.md`
