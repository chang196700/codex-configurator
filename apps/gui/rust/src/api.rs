/// Execute a configuration operation using the shared, offline Rust core.
pub fn request(request_json: String) -> String {
    match serde_json::from_str(&request_json) {
        Ok(request) => codex_config_core::dispatch(request).to_string(),
        Err(error) => serde_json::json!({
            "ok": false,
            "error": { "code": "invalid_request", "message": error.to_string() }
        })
        .to_string(),
    }
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
