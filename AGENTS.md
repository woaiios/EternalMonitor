# 本机 iOS 开发环境

本仓库所在的 Windows 已配置 **xtool（Xtools）+ WSL**，可构建、签名、安装并启动 iOS/iPadOS 真机 App，且 **go-ios + WebDriverAgent UI 自动化已跑通过**。

处理本机 iOS 构建、部署或测试前，先读取共享说明 `D:\lab\AGENTS.md`（WSL 为 `/mnt/d/lab/AGENTS.md`）及完整工具说明 `D:\lab\xtool\README.md`。

工具主目录：`D:\lab\xtool`；WSL：`Ubuntu-24.04`、用户 `dev`；xtool：`/usr/local/bin/xtool`。不要仅因 Windows 宿主机而断言无法运行或测试 iOS App。xtool 使用 SwiftPM，具体工程是否需要适配、设备连接、签名及 WDA 即时状态仍需按上述文档核对。
