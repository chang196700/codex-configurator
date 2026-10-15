# Verification record

Date: 2026-10-15. Native host: Windows x64. All configuration writes used temporary fixtures under the ignored build/cache directories; the user's real Codex configuration was not modified.

## Feature lifecycle labels

- The release CLI `features --catalog` returned 167 feature stages from local `codex-cli 0.162.1`: 66 under development, 4 experimental, 52 stable, 4 deprecated, and 41 removed. The response has catalog scope, no project cwd, and includes the command's boolean `enabled` column from the isolated process.
- A missing executable returned a nonfatal unavailable catalog with diagnostics and no stages. The existing global `features` snapshot still returned `unsupported_scope` without starting Codex.
- A real ConPTY TUI session searched for `multi_agent` and displayed `stable`, `removed`, and `under development` labels, then exited cleanly. The temporary draft path was not created or saved.
- Rust format checking and strict workspace Clippy passed. Full Flutter analysis and Windows x64 release builds passed. No source tests or mocks were added. GUI screenshot acceptance remains subject to the desktop limitation below.

## Passed

- `scripts/build.ps1 -Platform windows -Architecture x64`: optimized CLI/TUI executable and Flutter Windows release bundle. FRB Rust, Dart, and generator versions are all 2.13.0.
- `cargo fmt --all --check` and `cargo clippy --workspace --locked -- -D warnings`.
- Regenerating FRB bindings with the pinned generator reproduced all four generated source files byte for byte.
- `flutter analyze` for the complete GUI project: no issues found.
- `scripts/verify-artifacts.ps1 -Platform windows -Architecture x64`: CLI, GUI, Flutter engine, Rust bridge, and bundled Visual C++ DLLs report x64 PE machine type.
- Release CLI public-interface checks: dry-run does not write; set/get; leading/trailing comments, CRLF, unknown fields and signed 64-bit values survive edits; backups restore exact original bytes; stale revisions are rejected; stdin UTF-8 BOM is accepted; invalid Profile names and invalid configurations return the expected error exit codes.
- Core public RPC checks: system/user/Profile/project/CLI precedence, custom project root markers, trust and ignored project fields, source-relative paths, requirements diagnostics, redacted secrets, invalid schema imports and missing Codex handling.
- Real ConPTY TUI session: 80×24 Chinese layout, schema search, model editing, draft application, unsaved-change prompt, discard and clean terminal restoration.
- Actual generated Dart FRB API loaded the release Rust DLL and completed schema, typed inspection, nested edits, exact `9223372036854775807` round-trip, validation, diff, file save, conflict rejection, and backup restoration. The GUI's `CodexBackend` adapter was used in this check.
- Schema structure review: all 102 top-level properties are assigned to a category. Expanded form branches have controls/navigation for objects, unions, arrays, maps, and unrestricted values.
- Native GUI process started successfully and remained responsive. Windows app-local Visual C++ runtime DLLs are included in the build and portable package.

No source test files or mocks were added. The checks above used temporary fixtures and public interfaces.

## GUI layout follow-up

- Notifications now use a positioned bottom-right overlay outside the main content column. Showing or dismissing a notification does not consume content height. Ordinary notices dismiss after five seconds, pausing on hover or keyboard focus; errors remain until dismissed. Long messages scroll within the notification, and the icon and close control align with the first text line at the active text scale.
- Analysis headers and rows share column widths and spacing. Form controls, reset-button slots, file-tab indicators, and category indentation use consistent alignment. Editor toolbars wrap on narrow windows, where categories and search remain available through a navigation dialog.
- Rebuilt Windows x64 release with `scripts/build.ps1 -Platform windows -Architecture x64 -SkipGenerate`; full `flutter analyze` passed and `verify-artifacts.ps1` checked 14 native artifacts. No source tests were added for these layout changes.
- Visual acceptance remains subject to the desktop automation limitation below.

## Boundaries

- Desktop clicking and screenshot review could not run because the Computer Use native pipe was unavailable. Process startup, schema reachability review, Dart analysis, and FRB calls do not substitute for visual acceptance of every form and interaction.
- Linux, macOS, Windows arm64, and both Unix arm64 targets were not built locally. The six native CI jobs are configured but were not executed in this workspace.
- macOS project references and scheme XML were statically checked after removing the generated test target. CocoaPods integration and entitlements are configured for a local configuration editor; a native macOS build is still required.
- Full Codex runtime verification remains TODO at https://github.com/openai/codex/issues/26255. Cloud/MDM state and model-dependent runtime defaults remain unknown; optional feature snapshots do not establish a complete effective configuration.
- Dependency versions are pinned from the stable releases checked on the date above. `material_color_utilities` follows Flutter's SDK pin (0.13.0), even though 0.13.1 was available. Native folder selection uses `file_selector` 1.1.0; its compatible `cross_file` dependency resolves to 0.3.5+5 rather than forcing the incompatible 0.4.0 release.

## Project selection and compact pages

- The GUI starts in explicit global mode and offers native **Open project**, **Switch project**, and **Close project** actions in the top bar. Project changes preflight discovery and the next document before closing confirmed project drafts. Opened global document roles survive `CODEX_HOME` changes. Analysis and backup state is invalidated when the context changes.
- Editor, analysis, backups, and settings titles now share the app bar; their duplicate large page headings and subtitles were removed. The Windows UI uses Segoe UI with Microsoft YaHei UI fallback; monospace code uses the available Cascadia Mono/Consolas family. The host has Segoe UI, Microsoft YaHei, and Consolas font files.
- Windows x64 release build and full Flutter analysis passed. Native folder-picker registration is present in the Windows, Linux, and macOS projects; only Windows was compiled. Architecture verification now covers 15 native executables and DLLs, including the directory-picker plugin.
- Core formatting, checking, and strict Clippy passed. Public RPC fixtures verified global/project isolation, independent Profiles, default CLI compatibility, source-relative path resolution, invalid directory rejection, and global feature-snapshot suppression without launching a subprocess. Fixture file hashes remained unchanged.
- No source tests were added. Desktop visual acceptance and native picker interaction remain unverified because the Computer Use pipe is unavailable.

## Content-space layout revision

- File tabs and file actions now share one row. Narrow layouts keep the row by using icon buttons and a More menu. Long tab labels are bounded, duplicate filenames use the shortest unique path suffix, and active tabs scroll into view after selection, resizing, or text scaling.
- Main navigation remains a 64-pixel icon rail at all widths. The 216-pixel category pane can be collapsed, and narrow windows retain the category dialog. Form/page margins were reduced to 12–16 pixels and field-card padding to 14 pixels. Editor view actions start on the left; other page actions sit beside their related inputs instead of being pushed to the far edge.
- Full `flutter analyze` and the final Windows x64 release build passed. No source tests or configuration semantics were changed. Desktop screenshots remain unavailable, so this record does not claim visual acceptance.
