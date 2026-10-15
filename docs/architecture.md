# Architecture

Codex Configurator is a local file editor and a static configuration analyzer. It does not require Codex, authentication, a web service, or an API key.

The Cargo workspace contains a shared `codex-config-core` library, a `codex-configurator` CLI, a `codex-config-tui` library, and the Flutter FRB adapter. The Flutter desktop app is in `apps/gui`.

The macOS runner uses the Flutter Native Assets build hook and runs outside App Sandbox so the editor can access user-selected system, user, and project paths. It retains normal filesystem permissions. CI packages use the local ad-hoc signature required by macOS; no distribution certificate or notarization is configured. Windows packages include app-local Visual C++ redistributables.

All frontends invoke the same JSON operation boundary through `codex_config_core::dispatch`. FRB exposes a single asynchronous Dart `request(requestJson: ...)` call. Rust owns all TOML parsing and persistence. Values cross this boundary as TOML literals or typed trees with exact integer text; JSON numbers are not used to round-trip configuration integers.

Requests have an `op` field. Responses have either `{ "ok": true, "data": ... }` or `{ "ok": false, "error": { "code": ..., "message": ... } }`. Field addresses are RFC 6901 JSON Pointers, not dotted strings. A missing file has a null revision; existing revisions are SHA-256 hashes of file bytes.

The schema snapshot is independent of the static semantics version. Updating a schema adds field descriptions and validation rules but does not prove that the analyzer understands newer Codex runtime behavior. Unknown runtime defaults, cloud policy, and MDM state are explicitly identified in analysis reports.

An editing target and an analysis context are separate concepts. Opening a profile does not activate it or write a deprecated `profile` selector. Each GUI document has an independent draft and revision. Saving rechecks the disk revision and does not overwrite an externally changed document.

The GUI starts with an explicit global context (`include_project: false`), independent of the process working directory. The top bar opens, switches, or closes a project through the native directory picker. A project transition first confirms all affected drafts and reads the next paths and target snapshot before closing the previous project documents. Global document roles survive changes to `CODEX_HOME`, including when a project contains the global configuration directory. Analysis and backup pages invalidate their cached results on context revisions and reject outdated asynchronous responses. CLI/TUI defaults still include their working-directory project context.

## Runtime verification

Full effective-configuration verification is tracked as TODO against https://github.com/openai/codex/issues/26255. There is no app-server integration. Optional `codex features list` observations are independent snapshots with command, executable version, timestamp, working directory, and Codex home. They do not certify unsaved drafts or profile contexts that the subcommand cannot establish.

Feature lifecycle badges use a separate `feature_catalog` operation, available in global mode. It reads the installed Codex executable in a temporary home and working directory and returns names, stages, and the command's true/false enablement column. Catalog enablement describes that isolated Codex process; a project-scoped `features` snapshot can replace it after verification. GUI/TUI fetch the metadata in the background; GUI refreshes discard old metadata and reject superseded responses. Root Features and inline Profile Features use the same catalog. Unknown stage names are retained, and keys absent from the executable's list are not inferred to be removed.

## License

Original project code is licensed under MIT OR Apache-2.0. Third-party SDK and build integration files retain their upstream notices. The embedded Codex schema originates from OpenAI's Apache-2.0-licensed Codex project; its upstream notice is retained in the asset provenance record.
