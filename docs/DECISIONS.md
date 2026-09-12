# DECISIONS — MImoMeter

## 2026-09-12

1. **不移植 Codex 的 5h 优先逻辑**  
   MiMo 无 5h 窗口。选择器：weekly → fiveHour → monthly → unknown。

2. **主路径：平台 API + 官方 SSO；本地桥仅探测**  
   桥 `/v1/user/usage` 404；平台 API 可拿到 `{percent,resetDate,resetAt}`。

3. **测试用 `--run-self-tests`，不用 XCTest**  
   本机仅 CommandLineTools。

4. **SSO 字段用 FlexibleString；Phase2 跨重定向抓 Set-Cookie**  
   数字 nonce/userId；serviceToken 可能挂在 302 响应头。

5. **不在本仓库使用 worktree**  
   实现从 `.worktrees/mimo-meter` 迁回主 worktree（`mimo/dev`），后续直接改主目录。

6. **安装到 `~/Applications` 而非 `/Applications`**  
   免 sudo、路径稳定、便于 SMAppService。用户确认不需要系统级 Applications。

7. **登录项勾选框在 `.notFound` 时仍可点**  
   新装 ad-hoc app 常见 notFound，应允许尝试 `register()`。

8. **图标定稿 C6**  
   白进度环 + 橙弧 + 黑色 MiMo 四图形；去掉外框。

9. **展示提示线为可选设置**  
   默认关闭；与示数等宽、静态橙色；关闭时示数仍垂直居中。
