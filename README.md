# Codex Configurator

[English](README.en.md)

用于编辑 Codex `config.toml` 的独立桌面工具：Rust CLI、Rust TUI，以及 Flutter + flutter_rust_bridge (FRB) GUI。无需安装 Codex 即可编辑、校验和静态分析配置。

项目代码采用 **MIT OR Apache-2.0** 双许可。Windows、Linux、macOS 均提供原生工程，CI 覆盖三个系统的 x64 和 arm64。当前本地验证范围为 **Windows x64**。

## 功能

- GUI 分为配置编辑、生效分析、备份恢复和工具设置；当前页标题合并到顶部栏，文件标签、分类导航、嵌套对象面包屑与搜索避免把选项挤在同一页。Profiles 在编辑器中管理。
- 从官方 JSON Schema 生成表单，支持标量、枚举、数组、动态键对象、嵌套对象及联合类型；未设置与显式默认值分别处理。保留原始 TOML 编辑和差异视图。
- 中英文界面。官方字段名保持原样；尚未翻译的 Schema 说明显示英文原文，并标明回退状态。
- “工具设置 → 界面风格”支持跟随系统、Windows Fluent、macOS、Linux Yaru 和 Material；切换即时生效，并在本机保存选择。
- 共享 Rust 核心保留 TOML 注释、未知字段和未修改的格式，使用 TOML 字面量传递整数，避免浮点精度损失。
- 系统、用户、项目和独立 `<name>.config.toml` Profile 文件管理；文件目标与分析上下文分开选择。
- 保存前校验、磁盘修订冲突检测、原子替换、备份与恢复。GUI 中未应用的字段输入也会随保存提交，并计入未保存提示。
- 静态分层分析显示来源、覆盖链、项目信任与忽略规则、已知相对路径解析、可静态判定的 requirements 约束和未确定事项。默认隐藏分析报告中的敏感值。
- 内置官方 Schema 快照，可检查更新、更新、导入及恢复内置版本。Schema 版本与静态语义版本分别记录。
- GUI/TUI 的 Features 配置项按本机 `codex features list` 显示 `under development`、`experimental`、`stable`、`deprecated`、`removed` 等阶段。支持全局配置和 Profile；阶段读取在后台进行，GUI 可刷新并查看来源版本，未安装 Codex 时仍可编辑配置。
- Features 字段同时显示 `codex features list` 第三列的 `true`/`false` 启用状态；全局目录读取的是隔离运行时状态，打开项目并核验后可显示项目运行时状态。

完整运行时配置验证仍是 TODO，跟踪 [openai/codex#26255](https://github.com/openai/codex/issues/26255)。本工具不连接 app-server。可选的 `codex features list` 只提供独立的运行时观测，显示命令、版本、时间及上下文，不代表已验证未保存草稿或指定 Profile 的完整生效配置。内置默认值、云端策略、MDM 与无法在本地确定的行为会在静态报告中标记为未知。

## 使用

Windows 便携包解压后，运行 `gui/codex_configurator.exe` 打开 GUI。请保留 `gui` 中的 DLL 和 `data` 目录。CLI 与 TUI 共用根目录下的 `codex-configurator.exe`。

GUI 默认打开全局配置，不将程序启动目录当作项目。右上角“打开项目”使用系统文件夹选择器；选择后打开该目录的 `.codex/config.toml`，不存在的文件仅在保存时创建。右上角项目菜单支持切换项目或关闭项目返回全局配置，切换前会处理未保存的项目草稿。工具设置仅保留 `CODEX_HOME` 等工具选项，项目目录不在设置页配置。全局分析不读取项目层；可选的 Codex feature 核验需要先打开项目。

界面采用系统字体：Windows 使用 Segoe UI 配合微软雅黑 UI，配置键和 TOML 使用等宽字体。操作通知在右下角悬浮，不改变页面布局。

在“工具设置”的界面语言下方选择“界面风格”。“跟随系统”在 Windows 使用 Fluent、macOS 使用 macOS 风格、Linux 使用 Yaru；也可以在任意桌面平台手动选择其他风格。风格与浅色/深色模式独立，切换后无需重启。选择仅保存在 GUI 的本机偏好中，不写入 Codex `config.toml`；窗口标题栏、系统窗口按钮和文件夹选择器仍由宿主系统提供。偏好缺失、无法读取或值无效时使用“跟随系统”。

文件标签和打开、保存按钮共用一行；窄窗口中按钮使用图标和更多菜单，标签可横向滚动。主导航保持为窄图标栏；分类栏可通过表单顶部的箭头收起，再点“分类”展开。页内操作从左侧排列，内容使用可用宽度。

```powershell
codex-configurator --help
codex-configurator --lang zh paths
codex-configurator --file ./example.toml show
codex-configurator --file ./example.toml set /model --value '"gpt-5"'
codex-configurator --file ./example.toml get /model
codex-configurator --file ./example.toml --dry-run unset /model
codex-configurator --file ./example.toml validate
codex-configurator --file ./example.toml tui
codex-configurator --cwd . analyze
codex-configurator --json --profile work analyze -c 'model="gpt-5"'
codex-configurator profile create work
codex-configurator --target profile:work tui
codex-configurator schema check
codex-configurator features
codex-configurator features --catalog
```

`features --catalog` 列出本机 Codex 的功能阶段与 `codex features list` 返回的 `true`/`false` 状态；它在隔离进程中运行，不读取当前配置文件的启用值。GUI 的 Features 标题旁可刷新阶段；标签保留英文原文，悬停显示中文含义和来源版本。`not listed` 表示本机版本未列出此键，不等同于 `removed`。

`gpt-5` 仅为配置语法示例，不是模型可用性声明。字段地址使用 JSON Pointer：例如 `/mcp_servers/my.server/command`；名称中的 `/` 写作 `~1`，`~` 写作 `~0`。字符串值需包含 TOML 引号。复杂值可使用 `set POINTER --stdin`。

未指定文件目标时使用用户配置。`--file` 与 `--target user|system|project|profile:NAME` 互斥。`--codex-home` 和 `--cwd` 控制路径发现与分析；`--profile` 仅选择分析 Profile，打开 Profile 文件不会自动激活它。命令行和 TUI 的详细快捷键见 `--help` 与界面底部提示。

系统配置路径为 Windows `%ProgramData%\OpenAI\Codex\config.toml` 或 Unix `/etc/codex/config.toml`。用户配置位于 `$CODEX_HOME/config.toml`，未设置时为用户目录下的 `.codex/config.toml`。独立 Profiles 位于同一目录。项目文件为项目根至工作目录路径上的 `.codex/config.toml`，是否参与分析取决于信任状态及项目字段限制。

工具自己的 Schema 缓存使用系统本地应用数据目录中的 `codex-configurator/schema.json`，可用 `CODEX_CONFIGURATOR_DATA_DIR` 覆盖。备份保存在目标文件旁的 `.codex-configurator-backups`，不会自动清理旧备份。

## 从源码构建

依赖版本以 2026-10-15 查询的最新稳定版为基准，记录在 [tool-versions.json](tool-versions.json) 与 Cargo/Dart 锁文件中：Rust 1.99.0、Flutter 3.47.7 / Dart 3.13.5、FRB 2.13.0。GUI 的 Rust 动态库使用 Dart/Flutter Native Assets build hook 编译并随应用打包，不再使用 Cargokit。系统目录选择使用 [file_selector 1.1.0](https://pub.dev/packages/file_selector)。传递依赖遵循 SDK 和上游包的兼容约束，不强制覆盖。

界面风格依赖固定为 `fluent_ui 4.16.1`（BSD-3-Clause）、`macos_ui 2.2.2`（MIT）、`yaru 11.0.0`（主题与控件为 MPL-2.0），本机偏好使用 `shared_preferences 2.5.6`（BSD-3-Clause）。依赖的版权和资源许可见 [第三方声明](THIRD_PARTY_NOTICES.md)；项目原创代码继续采用 MIT OR Apache-2.0。

需要 Git、PowerShell 7、对应宿主的 Rust 和 Flutter，以及 Flutter 桌面平台工具链。Windows 需 Visual Studio 的 C++ 桌面开发组件和 Windows SDK；Linux 需 Clang、CMake、Ninja、pkg-config、GTK 3 开发库；macOS 需 Xcode 和 CocoaPods。使用与目标架构一致的原生宿主。

```powershell
rustup toolchain install 1.99.0 --component rustfmt --component clippy
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
# 将 Flutter 3.47.7 的 bin 目录加入 PATH
./scripts/build.ps1 -Platform windows -Architecture x64
./scripts/verify-artifacts.ps1 -Platform windows -Architecture x64
./scripts/package.ps1 -Platform windows -Architecture x64
```

只编译 CLI/TUI 可用 `./scripts/build.ps1 -CliOnly`。已有的 FRB 生成文件纳入版本管理；修改接口后运行 `apps/gui` 目录下的 `flutter_rust_bridge_codegen generate`。完整构建脚本会重新生成绑定，并运行 `flutter analyze`。

构建产物：

- CLI/TUI：`target/x86_64-pc-windows-msvc/release/codex-configurator.exe`
- GUI：`apps/gui/build/windows/x64/runner/Release/`
- 便携包：`dist/codex-configurator-0.1.0-windows-x64.zip` 及 SHA-256 文件

[CI](.github/workflows/build.yml) 在六种原生宿主上构建、静态检查、核对绑定与二进制架构并上传便携包。没有安装器、签名或公证步骤。尚未执行的 CI 平台不计入本地验证结果。

## 代码结构

| 路径 | 用途 |
| --- | --- |
| `crates/config-core` | Schema、TOML 文档、文件保存、Profiles、静态分析 |
| `crates/config-cli` | CLI 与 JSON 输出，`rpc` 提供共享核心的 JSON 请求入口 |
| `crates/config-tui` | Ratatui 交互配置界面 |
| `apps/gui/lib` | Flutter 页面、表单和文件草稿状态 |
| `apps/gui/rust` | FRB Rust 适配层及生成绑定 |
| `assets` | 官方 Schema 快照与来源记录 |
| `scripts` | 原生构建、架构检查与便携打包 |

更多设计见 [架构说明](docs/architecture.md)，实际检查与边界见 [验证记录](docs/verification.md)，第三方版权见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
