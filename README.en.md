# Codex Configurator

[简体中文](README.md)

A standalone editor for Codex `config.toml`: a Rust CLI, Rust TUI, and Flutter desktop GUI backed by Rust through flutter_rust_bridge (FRB). Editing, validation, and static analysis work without Codex installed.

Original code is dual licensed under **MIT OR Apache-2.0**. Native projects and CI cover Windows, Linux, and macOS on x64 and arm64. Local verification currently targets **Windows x64** only.

## Features

- Separate editor, analysis, backups, and settings pages, with the current page title in the app bar; document tabs, categories, nested navigation, and search. Profiles are managed from the editor.
- Forms generated from the official JSON Schema: scalars, enums, arrays, dynamic maps, nested objects, and unions. Unset values remain distinct from explicitly configured defaults. Raw TOML and diff views are available.
- Chinese and English UI. Configuration keys retain their original names. Untranslated upstream descriptions fall back to English with an explicit fallback status.
- A shared Rust core preserves comments, unknown fields, and untouched formatting. TOML literals preserve integer precision across the bridge.
- System, user, project, and independent `<name>.config.toml` Profile files. Editing targets and analysis contexts are separate.
- Validation before saving, disk revision checks, atomic replacement, backups, and restoration. Pending field input participates in save and unsaved-change handling.
- Static source and override chains, project trust and field restrictions, known relative-path resolution, locally decidable requirements, and explicit unknowns. Sensitive analysis values are redacted by default.
- Bundled official Schema with check, update, import, and reset actions. Schema and analyzer semantics have independent versions.
- GUI/TUI feature fields show lifecycle stages from local `codex features list`: `under development`, `experimental`, `stable`, `deprecated`, `removed`, and any future stage names. Global and Profile fields are supported. Stages load in the background; the GUI offers refresh and source-version details. Editing still works without Codex installed.
- Feature fields also show the `true`/`false` enablement column from `codex features list`. Global mode reports isolated runtime state; after opening a project and verifying it, the project runtime snapshot can replace that state.

Full runtime effective-configuration verification remains a TODO tracked by [openai/codex#26255](https://github.com/openai/codex/issues/26255). There is no app-server integration. Optional `codex features list` observations include the command, executable version, timestamp, and context. They do not certify unsaved drafts or complete Profile-specific behavior. Runtime defaults, cloud policies, MDM, and other unresolved behavior are reported as unknown.

## Usage

Extract the Windows portable archive and launch `gui/codex_configurator.exe`. Keep its DLLs and `data` directory together. The root `codex-configurator.exe` contains both CLI and TUI.

The GUI starts with global settings and does not treat its launch directory as a project. Use **Open project** at the top right to choose a folder with the native directory picker. Its `.codex/config.toml` opens as a draft; missing files are created only on save. The project menu can switch projects or close the project to return to global settings, with unsaved project drafts confirmed first. Settings retains `CODEX_HOME` and tool options; project selection belongs in the app bar. Global analysis excludes project layers, and optional Codex feature observations require an open project.

The interface uses native system fonts, with Segoe UI and Microsoft YaHei UI on Windows, plus monospace fonts for configuration keys and TOML. Notifications float at the bottom right without changing page layout.

File tabs share a row with Open and Save. Narrow windows use icon actions and a More menu while tabs scroll horizontally. Main navigation stays compact; collapse the category pane with the arrow above the form and reopen it with Categories. Page actions align to the left and content uses the available width.

```powershell
codex-configurator --help
codex-configurator paths
codex-configurator --file ./example.toml set /model --value '"gpt-5"'
codex-configurator --file ./example.toml get /model
codex-configurator --file ./example.toml --dry-run unset /model
codex-configurator --file ./example.toml validate
codex-configurator --file ./example.toml tui
codex-configurator --json --cwd . --profile work analyze -c 'model="gpt-5"'
codex-configurator profile create work
codex-configurator --target profile:work tui
codex-configurator schema check
codex-configurator features
codex-configurator features --catalog
```

`features --catalog` lists local Codex lifecycle metadata and the `true`/`false` status returned by `codex features list`. It runs in an isolated process and does not read the current configuration file's enablement values. Refresh stages beside the GUI Features heading; badges retain upstream stage names and show meaning and source version on hover. `not listed` means the local version did not report that key; it does not imply `removed`.

The model name above illustrates syntax, not model availability. Field addresses are JSON Pointers, for example `/mcp_servers/my.server/command`. Escape `/` inside a name as `~1` and `~` as `~0`. String values require TOML quotes. Use `set POINTER --stdin` for complex values.

The default editing target is the user configuration. `--file` and `--target user|system|project|profile:NAME` are mutually exclusive. `--codex-home` and `--cwd` control discovery and analysis; `--profile` selects the analysis Profile only. Opening a Profile does not activate it. See `--help` and the TUI footer for commands and shortcuts.

System configuration is `%ProgramData%\OpenAI\Codex\config.toml` on Windows and `/etc/codex/config.toml` on Unix. User configuration is `$CODEX_HOME/config.toml`, defaulting to `.codex/config.toml` in the home directory. Independent Profiles live alongside it. Project `.codex/config.toml` files are discovered from the project root toward the working directory and are subject to trust and project-field restrictions.

The tool's Schema cache is `codex-configurator/schema.json` under the OS local application data directory; override its directory with `CODEX_CONFIGURATOR_DATA_DIR`. Backups live beside the target in `.codex-configurator-backups`. Old backups are not automatically removed.

## Build

Versions were checked against stable releases on 2026-10-15 and are recorded in [tool-versions.json](tool-versions.json), Cargo.lock, and Dart lockfiles: Rust 1.99.0, Flutter 3.47.7 / Dart 3.13.5, FRB 2.13.0. The GUI Rust library is compiled and bundled by the Dart/Flutter Native Assets build hook; Cargokit is no longer used. The native directory picker uses [file_selector 1.1.0](https://pub.dev/packages/file_selector). Transitive packages follow SDK and upstream compatibility constraints without forced overrides.

Install Git, PowerShell 7, Rust, Flutter, and the native desktop toolchain. Windows requires Visual Studio Desktop development with C++ and a Windows SDK. Linux requires Clang, CMake, Ninja, pkg-config, and GTK 3 development libraries. macOS requires Xcode and CocoaPods. Build on a native host of the requested architecture.

```powershell
rustup toolchain install 1.99.0 --component rustfmt --component clippy
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
# Add Flutter 3.47.7's bin directory to PATH.
./scripts/build.ps1 -Platform windows -Architecture x64
./scripts/verify-artifacts.ps1 -Platform windows -Architecture x64
./scripts/package.ps1 -Platform windows -Architecture x64
```

Use `./scripts/build.ps1 -CliOnly` to build CLI/TUI alone. FRB bindings are checked in. Regenerate with `flutter_rust_bridge_codegen generate` from `apps/gui` after interface changes. The complete build script regenerates bindings and runs `flutter analyze`.

- CLI/TUI: `target/x86_64-pc-windows-msvc/release/codex-configurator.exe`
- GUI: `apps/gui/build/windows/x64/runner/Release/`
- Portable archive: `dist/codex-configurator-0.1.0-windows-x64.zip`, with a SHA-256 file

[CI](.github/workflows/build.yml) builds all six native targets, runs static checks, verifies bindings and binary architecture, and uploads portable archives. Signing, notarization, and installers are outside this delivery. Unexecuted CI platforms are not counted as locally verified.

## Layout

| Path | Purpose |
| --- | --- |
| `crates/config-core` | Schema, TOML documents, persistence, Profiles, static analysis |
| `crates/config-cli` | CLI and JSON output; `rpc` exposes the shared core request boundary |
| `crates/config-tui` | Ratatui interface |
| `apps/gui/lib` | Flutter pages, forms, and document drafts |
| `apps/gui/rust` | FRB Rust adapter and generated bindings |
| `assets` | Official Schema and provenance |
| `scripts` | Native build, architecture verification, and portable packaging |

See [architecture](docs/architecture.md), the [verification record](docs/verification.md), and [third-party notices](THIRD_PARTY_NOTICES.md).
