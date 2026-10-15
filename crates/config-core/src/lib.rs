//! Shared configuration engine. All frontends use the same JSON request contract.
mod analysis;
mod document;
mod features;
mod files;
mod schema;

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub const SEMANTIC_VERSION: &str = "codex-config-2026-10-15";

#[derive(Debug)]
pub struct CoreError {
    pub code: &'static str,
    pub message: String,
    pub diagnostics: Vec<Value>,
}

pub type CoreResult<T> = Result<T, CoreError>;

impl CoreError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            diagnostics: Vec::new(),
        }
    }
    pub fn diagnostics(
        code: &'static str,
        message: impl Into<String>,
        diagnostics: Vec<Value>,
    ) -> Self {
        Self {
            code,
            message: message.into(),
            diagnostics,
        }
    }
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}
impl std::error::Error for CoreError {}
impl From<std::io::Error> for CoreError {
    fn from(error: std::io::Error) -> Self {
        Self::new("io_error", error.to_string())
    }
}

pub(crate) fn required<'a>(request: &'a Value, key: &str) -> CoreResult<&'a str> {
    request
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| CoreError::new("invalid_request", format!("{key} must be a string")))
}

pub(crate) fn absolute(path: impl AsRef<Path>) -> CoreResult<PathBuf> {
    let path = path.as_ref();
    if path.as_os_str().is_empty() {
        return Err(CoreError::new("invalid_path", "Path cannot be empty"));
    }
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    // Do not canonicalize: absent files are valid targets. Saving checks symlinks separately.
    Ok(path)
}

pub(crate) fn pointer_part(value: &str) -> String {
    value.replace('~', "~0").replace('/', "~1")
}

pub(crate) fn diagnostic(
    severity: &str,
    code: &str,
    pointer: &str,
    message: impl Into<String>,
) -> Value {
    json!({"severity":severity,"code":code,"pointer":pointer,"message":message.into()})
}

/// Execute one request without frontend-specific state.
///
/// Every request contains `op`. Success is `{ok:true,data:...}`; failures are
/// `{ok:false,error:{code,message,diagnostics}}`. TOML values travel as literals
/// so 64-bit integers never pass through a JavaScript/Dart floating-point value.
pub fn dispatch(request: Value) -> Value {
    match execute(&request) {
        Ok(data) => json!({"ok":true,"data":data}),
        Err(error) => {
            json!({"ok":false,"error":{"code":error.code,"message":error.message,"diagnostics":error.diagnostics}})
        }
    }
}

fn execute(request: &Value) -> CoreResult<Value> {
    match required(request, "op")? {
        "schema" => schema::describe(),
        "open" => files::open(&absolute(required(request, "path")?)?),
        "edit" => document::edit(request),
        "inspect" => document::inspect(request),
        "validate" => {
            let diagnostics = schema::validate(required(request, "content")?)?;
            let valid = !diagnostics.iter().any(|item| item["severity"] == "error");
            Ok(json!({"valid":valid,"diagnostics":diagnostics}))
        }
        "diff" => {
            let before = required(request, "before")?;
            let after = required(request, "after")?;
            let diff = similar::TextDiff::from_lines(before, after)
                .unified_diff()
                .context_radius(3)
                .header("before/config.toml", "after/config.toml")
                .to_string();
            Ok(json!({"diff":diff}))
        }
        "save" => files::save_request(request),
        "paths" => analysis::paths(request),
        "analyze" => analysis::analyze(request),
        "profiles" => files::profiles(request),
        "backups" => files::backups(&absolute(required(request, "path")?)?),
        "restore" => files::restore(request),
        "schema_update" => schema::update(request),
        "feature_catalog" => features::catalog(request),
        "features" => features::snapshot(request),
        op => Err(CoreError::new(
            "unknown_operation",
            format!("Unknown operation: {op}"),
        )),
    }
}
