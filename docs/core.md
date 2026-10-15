# Shared Rust configuration engine

`codex_config_core::dispatch(serde_json::Value)` is the public interface used by
the CLI, TUI and Flutter bridge. It returns `{ "ok": true, "data": ... }` or
`{ "ok": false, "error": { "code", "message", "diagnostics": [...] } }`.
The engine never launches a model session.

## Document operations

| Operation | Request fields | Result |
| --- | --- | --- |
| `open` | `path` | `path`, original `content`, SHA-256 `revision`, `exists`, diagnostics |
| `inspect` | `content`, optional `pointer` | Recursive node with `key`, `pointer`, `kind`, `value_toml`, `value` or `children` |
| `edit` | `content`, `pointer`, `action`, `value_toml` for set | Edited content and diagnostics; incomplete drafts are allowed |
| `validate` | `content` | `valid` and diagnostics |
| `diff` | `before`, `after` | Unified `diff` |
| `save` | `path`, `content`, `revision` | New snapshot and optional backup descriptor |
| `backups` | `path` | Backup descriptors with id, path and creation time |
| `restore` | `path`, `backup_id`, `revision` | Restored snapshot and backup of the replaced version |

Pointers follow RFC 6901, including `~0` and `~1`; the document root is `""`.
Array indices are zero-based and `-` appends to ordinary arrays. Keys containing
dots remain one pointer segment. `value_toml` is exactly one TOML literal, not a
JSON value or an assignment. Numeric `inspect.value` fields are strings so the
full TOML signed 64-bit integer range survives all frontends. Booleans use JSON
booleans; strings use decoded JSON strings. Object and array children are nodes.

Editing uses `toml_edit` to retain unrelated comments, ordering and formatting.
Save requires valid TOML and rejects newly introduced schema errors. Existing
errors can remain while unrelated fields are changed. Unknown keys generate
warnings and are preserved. Revisions are mandatory; new files use `null`.
An external modification produces `revision_conflict` and is never force-saved.

Writes use a same-directory temporary file, flushing and syncing before atomic
replacement. Windows uses `ReplaceFileW` for existing files to retain their DACL;
Unix preserves the file mode. Symlink targets require explicitly opening the
resolved file. An advisory lock serializes cooperating writers. Backups live
under `.codex-configurator-backups/<target-hash>/` next to the target and have
private permissions. They contain full original content, including secrets.
No backup is pruned automatically.

## Schema and forms

`schema` returns `schema`, `form_schema`, `metadata`, and bilingual `categories`.
The bundled schema is fetched from the official OpenAI endpoint. The form schema
expands local references and aggregates `allOf` shapes while preserving compound
logical constraints. Cycles are reported as `x-recursive-ref`. The categories
partition all root properties; fields without maintained translations carry
`translation_status: "source-fallback"` and retain official labels/descriptions.

`schema_update` accepts actions `check`, `update`, `import` (with `path`), or
`reset`. Only explicit check/update performs network access. Imported schemas
must compile as Draft 7 and cannot contain remote references. An invalid download
or import does not replace the active schema. Runtime schemas use the platform
local application-data directory, or `CODEX_CONFIGURATOR_DATA_DIR`, independently
of Codex's own home directory. Metadata records the content hash and origin;
the schema snapshot and static semantic rules have separate versions.

## Discovery and analysis

`paths` and `analyze` accept optional `codex_home`, `cwd`, and `include_project`.
`include_project` defaults to `true` to preserve CLI and TUI behavior, using the
process working directory when `cwd` is absent. An explicit project `cwd` must be
an existing directory. With `include_project: false`, `cwd` is ignored and the
engine does not discover or read project layers, evaluate project trust, or use
the process working directory as analysis context. Discovery returns
`scope: "global"`, `include_project: false`, `cwd: null`, `project_root: null`,
and `projects: []`; analysis returns the same context fields with `trust: null`.
Project context uses `scope: "project"`. Independent profiles continue to work
in both scopes and their operations depend only on Codex home.

Explicit Codex home
takes priority over `CODEX_HOME`, then the user's `.codex` directory. Windows
system files live under `%ProgramData%\OpenAI\Codex`; Unix uses `/etc/codex`.
`analyze` also accepts `profile`, `overrides` (TOML `key=value` strings), and an
explicit `reveal_secrets` flag. The default analysis redacts sensitive values.

Analysis reads system, user, independent profile and project files, applies
recursive table merge and array replacement, and reports each field's source
and overwrite chain. Project layers require a matching trusted project entry;
machine-local provider, notification and telemetry keys are marked ignored in
project files. Known path-valued fields include source-relative `resolved_path`
or `resolved_paths` alongside their original literals. In global scope,
source-relative file values still resolve against their source file directory;
relative CLI override paths have no base and return null resolved paths with
`path_resolution: "unresolved"` and an explanation. Legacy managed defaults
are observed separately and never merged into ordinary values. Local
`requirements.toml` is read only for constraint diagnostics.

`system_path`, `managed_path`, `requirements_path`, and `include_system: false`
are optional analysis overrides for isolated fixture use and alternate system
layouts. They do not change Codex itself. Discovery without a project marker
uses the selected directory as the project root; trust uses the nearest matching
ancestor entry and should be treated as static semantic analysis.

The result explicitly reports `mode: "static"` and
`complete_runtime_analysis: false`. Cloud bundles, macOS MDM, runtime policy
fallbacks, account restrictions and model-dependent built-in defaults are listed
in `unknowns`. App-server integration remains a future extension; the analyzer
does not claim to reproduce facts it cannot observe.

`profiles` supports `list`, `create`, `copy`, `rename`, and `delete`. Names contain
1–128 ASCII letters, digits, underscores or hyphens and refer to
`<name>.config.toml`. Delete makes a backup; copying and renaming never overwrite
an existing destination. `create` accepts optional initial `content`.

`features` optionally accepts `executable` and runs `codex --version` (three-second
deadline) and `codex features list` (eight-second deadline), with captured output
and no interactive input. Missing
Codex, unsupported commands and failures return a nonfatal feature snapshot.
Snapshots include executable, version, cwd, Codex home, arguments and capture
time; they explicitly do not verify selected profiles or unsaved changes.
Their results do not replace schema data or modify configuration.
With `include_project: false`, `features` returns a nonfatal disabled snapshot
with the `unsupported_scope` diagnostic, a null cwd, and empty argument lists;
it starts no subprocess, including the version check.

`feature_catalog` accepts an optional `executable` and reads the same version
and feature-list commands in a temporary Codex home and working directory.
It works without an open project and returns `{name, stage, enabled}` rows from
the command's third column. In catalog scope the boolean describes the Codex
process using an isolated temporary home, not an unsaved GUI draft. Its context
uses `scope: "catalog"`, `include_project: false`, null `cwd`/`codex_home`, and
identifies the executable, version and isolated configuration. GUI/TUI load this
metadata in the background; CLI exposes it as
`features --catalog`. Stages retain the executable's spelling, including unknown
future stages. Missing Codex, command failures and empty or incompatible output
produce `available: false`, empty features and diagnostics. The GUI clears old
labels on refresh and does not infer `removed` for a key absent from the list.
