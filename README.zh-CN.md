# 松烟（Songyan）

![CI](../../actions/workflows/ci.yml/badge.svg)

[English](README.md)

松烟是一款基于 [RIME 中州韵](https://rime.im) 引擎的 iOS 通用中文输入法：主 App 负责管理输入方案，键盘扩展直接在设备端运行引擎。

## 功能

- RIME 引擎（librime 1.17）直接在键盘扩展中运行，包含 `lua`、`octagram`（语法模型）与 `predict` 插件。
- 内置全拼和小鹤双拼两种输入方案，可用于 26 键、14 键、18 键、9 键四种键盘布局；14、18、9 键版本由方案自动生成。
- 在合并键上左右滑动可直接打出其中一个字母；可选在字母键上显示双拼提示。
- 支持从文件或链接导入 RIME 输入方案与词库，可在主 App 中启用、停用或删除。
- 支持自定义键盘外观、候选栏与键盘布局，并可直接试打。
- 可按需开启错键纠正、上屏联想（需自行导入 `predict.db`）和语法模型，并支持逐项开关 Lua 组件。
- 支持手动备份与合并学习数据。
- 键盘扩展不会发起任何网络请求。只有你主动操作时主 App 才会联网：通过链接导入或更新输入方案，或下载词库、模型文件。开启「允许完全访问」仅用于通过 App Group 与主 App 共享数据。

## 环境要求

- macOS 与 Xcode 26 或更高版本（iOS 26 SDK 及以上）；App 支持 iOS 17.0 及以上。
- 在模拟器上运行需要 Apple 芯片的 Mac：引擎只提供 arm64 模拟器版本。
- Python 3.11 或更高版本，用于运行项目脚本与测试（只用标准库）。

仓库已包含预编译引擎 `Packages/RimeBridge/Vendored/RimeKit.xcframework`，构建 App 时无需编译 librime。

## 快速开始

1. 克隆仓库并打开 `Songyan.xcodeproj`。
2. 在模拟器上运行：执行 `make sim-stage`。它会构建 Debug 版本并做 Ad-hoc 签名，无需开发者账号即可使用 App Group，然后安装到专用模拟器上，详见 [DEBUG.md](DEBUG.md)。
3. 在真机上运行：新建 `Config/Local.xcconfig`（Git 会忽略它），把 `DEVELOPMENT_TEAM` 设为你的团队。如果默认标识已被占用，一并改掉：

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   SONGYAN_BUNDLE_ID = com.example.songyan
   SONGYAN_APP_GROUP = group.com.example.songyan
   ```

   键盘扩展的 Bundle ID 为 `$(SONGYAN_BUNDLE_ID).keyboard`。
4. 构建并运行 `HostApp` scheme，然后在「设置 → 通用 → 键盘 → 键盘」中添加松烟，并开启「允许完全访问」。

## 开发

| 命令 | 用途 |
| --- | --- |
| `make fast` | 结构检查、Swift 包测试与离线探针 |
| `make lint` / `make format` | 检查 / 整理 Swift、Shell 与 Python 代码格式 |
| `make extended` | `fast` + 原生引擎 harness + 模拟器与真机 Debug 构建 |
| `make release` | `extended` + 已安装引擎检查 + Release 构建 |
| `make sim-stage` | 在专用模拟器上构建、安装并启动 |

每个 Pull Request 都会在 CI 上运行代码格式检查、`make fast` 测试，以及模拟器与真机的无签名 Debug 和 Release 构建。

开发流程参见 [CONTRIBUTING.md](CONTRIBUTING.md)，模块索引参见 [ARCHITECTURE.md](ARCHITECTURE.md)，调试与模拟器自动化参见 [DEBUG.md](DEBUG.md)。

## 重新构建引擎

`Tools/BuildRime`（macOS）与 `Tools/BuildRimeIOS`（iOS 切片）基于锁定版本的上游源码构建 librime 及其插件：`Tools/BuildRimeIOS/scripts/43-build-rimekit.py` 生成 XCFramework，`Tools/BuildRimeIOS/scripts/export-rimekit.py` 检查并安装它，校验值记录在 `Packages/RimeBridge/RimeKitArtifact.json`；上游版本记录在 `Tools/BuildRime/VERSIONS.env` 中。

## 已知问题

- **键盘上方偶尔多出 17pt 空白（iOS 26、27 的问题）。** 键盘弹出时切到别的 App 再回来，或者从带顶栏的系统键盘（英文、拼音）切到松烟，iOS 可能会在所有第三方键盘上方多加一条 17pt 的空白。键盘自身的尺寸和安全区都没有变化，所以松烟无法察觉，也无法修正。切到表情键盘再切回来，或者彻底关掉正在打字的 App 再打开，空白就会消失。详见 [Apple 开发者论坛](https://developer.apple.com/forums/thread/843093)（FB24460699、FB25094825）。

## 许可

Copyright © 2026 Suzukaa-a。松烟采用 [GNU 通用公共许可证第 3 版](LICENSE)，仅限第 3 版（GPL-3.0-only）。

第三方组件及其许可证详见 [Resources/Legal/ThirdPartyNotices.txt](Resources/Legal/ThirdPartyNotices.txt)。
