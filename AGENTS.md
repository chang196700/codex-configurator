# Testing guidelines

- Do not create tests unless explicitly requested.
- For bug fixes, add a regression test only when the bug can reasonably reappear.
- Prefer integration tests and public interfaces; do not test private functions.
- Do not add tests only for coverage, unnecessary mocks, or change tests to hide failures.
- Ask when uncertain. Before adding more than three tests, explain each purpose and why existing tests are insufficient.

# Project conventions

- Configuration semantics, validation, editing, and persistence belong in `codex-config-core`.
- GUI and TUI render schema-driven forms. Never reserialize a complete user document in a frontend.
- Preserve existing unknown keys, comments, and formatting; never use the developer's real Codex files for verification.
- Use the latest stable dependencies when updating, then commit the resolved lockfiles.
- Rust, Dart, and the FRB generator must use the same FRB version.
- New source files are licensed under MIT OR Apache-2.0.

