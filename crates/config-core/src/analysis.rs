use crate::{
    CoreError, CoreResult, SEMANTIC_VERSION, absolute, document, files, pointer_part, schema,
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    env,
    path::{Path, PathBuf},
};

const PROJECT_IGNORED: &[&str] = &[
    "openai_base_url",
    "chatgpt_base_url",
    "apps_mcp_product_sku",
    "model_provider",
    "model_providers",
    "notify",
    "profile",
    "profiles",
    "experimental_realtime_ws_base_url",
    "otel",
];

pub(crate) fn codex_home(request: &Value) -> CoreResult<PathBuf> {
    let path = request["codex_home"]
        .as_str()
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("CODEX_HOME")
                .filter(|path| !path.is_empty())
                .map(PathBuf::from)
        })
        .or_else(|| dirs::home_dir().map(|path| path.join(".codex")))
        .ok_or_else(|| {
            CoreError::new(
                "no_home_directory",
                "Cannot determine CODEX_HOME or the user's home directory",
            )
        })?;
    absolute(path)
}

pub(crate) fn project_cwd(request: &Value) -> CoreResult<Option<PathBuf>> {
    if !request["include_project"].as_bool().unwrap_or(true) {
        return Ok(None);
    }
    let path = match request["cwd"].as_str() {
        Some(path) => {
            let path = absolute(path)?;
            if !path.is_dir() {
                return Err(CoreError::new(
                    "invalid_cwd",
                    "The selected project working directory must be an existing directory",
                ));
            }
            path
        }
        None => env::current_dir()?,
    };
    Ok(Some(path))
}

fn scope(cwd: Option<&Path>) -> &'static str {
    if cwd.is_some() { "project" } else { "global" }
}

fn system_file(request: &Value) -> CoreResult<PathBuf> {
    if let Some(path) = request["system_path"].as_str() {
        return absolute(path);
    }
    #[cfg(windows)]
    {
        Ok(
            PathBuf::from(env::var_os("ProgramData").unwrap_or_else(|| "C:\\ProgramData".into()))
                .join("OpenAI")
                .join("Codex")
                .join("config.toml"),
        )
    }
    #[cfg(not(windows))]
    {
        Ok(PathBuf::from("/etc/codex/config.toml"))
    }
}

fn project_directories(cwd: &Path, markers: &[String]) -> Vec<PathBuf> {
    let ancestors: Vec<_> = cwd.ancestors().map(Path::to_path_buf).collect();
    let root = ancestors.iter().position(|path| {
        markers
            .iter()
            .any(|marker| !marker.is_empty() && path.join(marker).exists())
    });
    match root {
        Some(index) => ancestors[..=index].iter().rev().cloned().collect(),
        None => vec![cwd.to_path_buf()],
    }
}

fn project_markers(config: &toml::Value) -> Vec<String> {
    config
        .get("project_root_markers")
        .and_then(toml::Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(toml::Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_else(|| vec![".git".into()])
}

pub(crate) fn paths(request: &Value) -> CoreResult<Value> {
    let home = codex_home(request)?;
    let cwd = project_cwd(request)?;
    let system = system_file(request)?;
    if let Some(profile) = request["profile"].as_str() {
        files::valid_profile(profile)?;
    }
    let project_dirs = if let Some(cwd) = cwd.as_deref() {
        let mut discovery = toml::Value::Table(Default::default());
        let mut sources = Vec::new();
        if request["include_system"].as_bool().unwrap_or(true) {
            sources.push(system.clone());
        }
        sources.push(home.join("config.toml"));
        if let Some(profile) = request["profile"].as_str() {
            sources.push(home.join(format!("{profile}.config.toml")));
        }
        for source in sources {
            if let Ok(Some(content)) = files::read(&source)
                && let Ok(value) = document::typed(&content)
            {
                merge(&mut discovery, value);
            }
        }
        project_directories(cwd, &project_markers(&discovery))
    } else {
        Vec::new()
    };
    let projects: Vec<_> = project_dirs
        .iter()
        .map(|path| path.join(".codex").join("config.toml"))
        .collect();
    Ok(
        json!({"codex_home":home,"cwd":cwd,"scope":scope(cwd.as_deref()),"include_project":cwd.is_some(),"project_root":project_dirs.first(),"system":system,"user":home.join("config.toml"),"projects":projects,"profiles":files::profile_list(&home)?}),
    )
}

fn merge(target: &mut toml::Value, source: toml::Value) {
    match (target, source) {
        (toml::Value::Table(target), toml::Value::Table(source)) => {
            for (key, value) in source {
                if let Some(existing) = target.get_mut(&key) {
                    merge(existing, value);
                } else {
                    target.insert(key, value);
                }
            }
        }
        (target, source) => *target = source,
    }
}

fn flatten(value: &toml::Value, pointer: &str, output: &mut BTreeMap<String, String>) {
    if let toml::Value::Table(table) = value
        && !table.is_empty()
    {
        for (key, value) in table {
            flatten(value, &format!("{pointer}/{}", pointer_part(key)), output);
        }
    } else if !pointer.is_empty() {
        output.insert(pointer.to_string(), document::literal(value));
    }
}

fn normalized(path: &Path) -> String {
    let path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let value = path
        .to_string_lossy()
        .trim_start_matches("\\\\?\\")
        .replace('\\', "/")
        .trim_end_matches('/')
        .to_string();
    if cfg!(windows) {
        value.to_lowercase()
    } else {
        value
    }
}

fn trust(config: &toml::Value, cwd: &Path) -> Option<String> {
    let entries = config.get("projects")?.as_table()?;
    let cwd = normalized(cwd);
    entries
        .iter()
        .filter_map(|(path, value)| {
            let candidate = normalized(Path::new(path));
            let in_project = cwd == candidate || cwd.starts_with(&format!("{candidate}/"));
            if in_project {
                value
                    .get("trust_level")
                    .and_then(toml::Value::as_str)
                    .map(|level| (candidate.len(), level.to_owned()))
            } else {
                None
            }
        })
        .max_by_key(|(len, _)| *len)
        .map(|(_, value)| value)
}

pub(crate) fn is_sensitive(pointer: &str) -> bool {
    let lower = pointer.to_lowercase();
    let segments: Vec<_> = lower.split('/').collect();
    segments.iter().any(|segment| {
        segment.contains("password")
            || segment.contains("secret")
            || segment.contains("api_key")
            || segment.contains("access_token")
            || segment.contains("refresh_token")
            || segment.contains("bearer_token")
            || segment == &"token"
            || segment == &"authorization"
    }) || segments
        .windows(2)
        .any(|parts| matches!(parts[0], "env" | "http_headers" | "headers") && !parts[1].is_empty())
}

fn redact_entries(entries: &mut [Value], reveal: bool) {
    if reveal {
        return;
    }
    for entry in entries {
        if is_sensitive(entry["pointer"].as_str().unwrap_or("")) {
            entry["value_toml"] = json!("\"[REDACTED]\"");
            entry["redacted"] = json!(true);
            if let Some(chain) = entry["chain"].as_array_mut() {
                for origin in chain {
                    origin["value_toml"] = json!("\"[REDACTED]\"");
                    origin["redacted"] = json!(true);
                }
            }
        }
    }
}

struct Analyzer {
    merged: toml::Value,
    layers: Vec<Value>,
    chain: BTreeMap<String, Vec<Value>>,
    diagnostics: Vec<Value>,
}

impl Analyzer {
    fn new() -> Self {
        Self {
            merged: toml::Value::Table(Default::default()),
            layers: Vec::new(),
            chain: BTreeMap::new(),
            diagnostics: Vec::new(),
        }
    }

    fn layer(
        &mut self,
        kind: &str,
        path: &Path,
        enabled: bool,
        disabled_reason: Option<&str>,
        project: bool,
    ) -> CoreResult<()> {
        let content = match files::read(path) {
            Ok(Some(content)) => content,
            Ok(None) => {
                self.layers.push(json!({"kind":kind,"path":path,"status":"missing","reason":"File does not exist"}));
                return Ok(());
            }
            Err(error) => {
                self.layers
                    .push(json!({"kind":kind,"path":path,"status":"error","reason":error.message}));
                self.diagnostics.push(json!({"severity":"error","code":error.code,"path":path,"message":error.message}));
                return Ok(());
            }
        };
        let raw = match document::typed(&content) {
            Ok(raw) => raw,
            Err(error) => {
                self.layers.push(
                    json!({"kind":kind,"path":path,"status":"error","reason":"Invalid TOML"}),
                );
                for mut detail in error.diagnostics {
                    detail["path"] = json!(path);
                    self.diagnostics.push(detail);
                }
                return Ok(());
            }
        };
        let mut layer = json!({"kind":kind,"path":path,"status":if enabled {"loaded"}else{"skipped"},"revision":schema::hash(content.as_bytes())});
        if let Some(reason) = disabled_reason {
            layer["reason"] = json!(reason);
        }
        self.layers.push(layer);
        for mut detail in schema::validate(&content)? {
            detail["path"] = json!(path);
            self.diagnostics.push(detail);
        }
        let mut flattened = BTreeMap::new();
        flatten(&raw, "", &mut flattened);
        for (pointer, value) in flattened {
            let key = document::tokens(&pointer)?
                .into_iter()
                .next()
                .unwrap_or_default();
            let ignored = project && PROJECT_IGNORED.contains(&key.as_str());
            let status = if !enabled {
                "skipped"
            } else if ignored {
                "ignored"
            } else {
                "applied"
            };
            let mut origin = json!({"kind":kind,"path":path,"pointer":pointer,"value_toml":value,"status":status});
            if !enabled {
                origin["reason"] = json!(disabled_reason.unwrap_or("Layer is not active"));
            } else if ignored {
                origin["reason"] =
                    json!("Codex ignores this machine-local setting in project configuration");
                self.diagnostics.push(json!({"severity":"warning","code":"ignored_project_key","pointer":pointer,"path":path,"message":"This field is ignored in project configuration; set it in user configuration"}));
            }
            self.chain.entry(pointer).or_default().push(origin);
        }
        if enabled {
            let mut applied = raw;
            if project && let Some(table) = applied.as_table_mut() {
                for key in PROJECT_IGNORED {
                    table.remove(*key);
                }
            }
            merge(&mut self.merged, applied);
        }
        Ok(())
    }

    fn overrides(&mut self, overrides: &[Value]) -> CoreResult<()> {
        if overrides.is_empty() {
            return Ok(());
        }
        self.layers.push(json!({"kind":"cli","path":Value::Null,"status":"loaded","reason":"Explicit analysis-only overrides"}));
        for (index, item) in overrides.iter().enumerate() {
            let assignment = item.as_str().ok_or_else(|| {
                CoreError::new(
                    "invalid_request",
                    "Every override must be a TOML key=value string",
                )
            })?;
            let (key, text) = assignment.split_once('=').ok_or_else(|| {
                CoreError::new("invalid_override", "Override must contain key=value")
            })?;
            let key = key.trim();
            if key.is_empty() {
                return Err(CoreError::new(
                    "invalid_override",
                    "Override key cannot be empty",
                ));
            }
            let raw = match document::typed(assignment) {
                Ok(value) => value,
                Err(_) => document::typed(&format!(
                    "{key} = {}",
                    serde_json::to_string(text)
                        .map_err(|e| CoreError::new("invalid_override", e.to_string()))?
                ))?,
            };
            // Require precisely the one assignment the CLI expression represents.
            let mut flattened = BTreeMap::new();
            flatten(&raw, "", &mut flattened);
            for (pointer, value) in flattened {
                self.chain.entry(pointer.clone()).or_default().push(json!({"kind":"cli","path":Value::Null,"pointer":pointer,"value_toml":value,"status":"applied","index":index}));
            }
            merge(&mut self.merged, raw);
        }
        Ok(())
    }
}

fn requirements(path: &Path, merged: &toml::Value, diagnostics: &mut Vec<Value>) -> Value {
    match files::read(path) {
        Ok(None) => {
            json!({"kind":"requirements","path":path,"status":"missing","reason":"File does not exist"})
        }
        Err(error) => {
            diagnostics.push(json!({"severity":"warning","code":"requirements_unreadable","path":path,"message":error.message}));
            json!({"kind":"requirements","path":path,"status":"error","reason":error.message})
        }
        Ok(Some(content)) => match document::typed(&content) {
            Err(error) => {
                diagnostics.push(json!({"severity":"error","code":"invalid_requirements","path":path,"message":error.message}));
                json!({"kind":"requirements","path":path,"status":"error","reason":"Invalid TOML"})
            }
            Ok(value) => {
                for (allowlist, key) in [
                    ("allowed_approval_policies", "approval_policy"),
                    ("allowed_sandbox_modes", "sandbox_mode"),
                    ("allowed_web_search_modes", "web_search"),
                    ("allowed_permission_profiles", "default_permissions"),
                ] {
                    if let (Some(allowed), Some(configured)) = (
                        value.get(allowlist).and_then(toml::Value::as_array),
                        merged.get(key),
                    ) && !allowed.contains(configured)
                    {
                        diagnostics.push(json!({"severity":"warning","code":"managed_constraint_conflict","pointer":format!("/{key}"),"path":path,"message":format!("Configured value is outside {allowlist}; the Codex runtime must resolve a permitted value")}));
                    }
                }
                if let Some(features) = value.get("features").and_then(toml::Value::as_table) {
                    for (key, required) in features {
                        if let Some(configured) = merged
                            .get("features")
                            .and_then(|features| features.get(key))
                            && configured != required
                        {
                            diagnostics.push(json!({"severity":"warning","code":"managed_constraint_conflict","pointer":format!("/features/{}",pointer_part(key)),"path":path,"message":"The local requirements pin this feature to a different value"}));
                        }
                    }
                }
                if let Some(table) = value.as_table() {
                    for (key, required) in table {
                        if !key.starts_with("allowed_")
                            && !matches!(
                                key.as_str(),
                                "features"
                                    | "rules"
                                    | "hooks"
                                    | "network"
                                    | "permissions"
                                    | "mcp_servers"
                                    | "plugins"
                                    | "marketplaces"
                            )
                            && let Some(configured) = merged.get(key)
                            && configured != required
                        {
                            diagnostics.push(json!({"severity":"warning","code":"managed_constraint_review","pointer":format!("/{}",pointer_part(key)),"path":path,"message":"A local requirement differs from ordinary configuration; verify its runtime enforcement semantics"}));
                        }
                    }
                }
                json!({"kind":"requirements","path":path,"status":"loaded","revision":schema::hash(content.as_bytes()),"reason":"Read-only constraints; runtime fallbacks are not fabricated"})
            }
        },
    }
}

fn legacy_managed(path: &Path, diagnostics: &mut Vec<Value>) -> Value {
    match files::read(path) {
        Ok(None) => {
            json!({"kind":"legacy_managed","path":path,"status":"missing","reason":"File does not exist"})
        }
        Ok(Some(content)) => match document::typed(&content) {
            Ok(_) => {
                diagnostics.push(json!({"severity":"warning","code":"legacy_managed_unresolved","path":path,"message":"Legacy managed defaults require Codex runtime interpretation and are kept separate from ordinary configuration"}));
                json!({"kind":"legacy_managed","path":path,"status":"observed","revision":schema::hash(content.as_bytes()),"reason":"Read-only; legacy enforcement semantics are not merged into ordinary settings"})
            }
            Err(error) => {
                diagnostics.push(json!({"severity":"error","code":"invalid_managed_config","path":path,"message":error.message}));
                json!({"kind":"legacy_managed","path":path,"status":"error","reason":"Invalid TOML"})
            }
        },
        Err(error) => {
            diagnostics.push(json!({"severity":"warning","code":"managed_config_unreadable","path":path,"message":error.message}));
            json!({"kind":"legacy_managed","path":path,"status":"error","reason":error.message})
        }
    }
}

fn resolve_paths(entry: &mut Value, cwd: Option<&Path>) {
    if entry["status"] == "inactive" {
        return;
    }
    let pointer = entry["pointer"].as_str().unwrap_or("");
    let Ok(parts) = document::tokens(pointer) else {
        return;
    };
    let scalar = matches!(parts.as_slice(), [key] if matches!(key.as_str(),"model_instructions_file"|"model_catalog_json"|"experimental_compact_prompt_file"|"log_dir"|"sqlite_home"))
        || matches!(parts.as_slice(), [root,_,key] if (root=="agents"&&key=="config_file") || (root=="mcp_servers"&&key=="cwd"));
    let array = matches!(parts.as_slice(), [root,key] if root=="sandbox_workspace_write" && key=="writable_roots");
    if !scalar && !array {
        return;
    }
    let literal = entry["value_toml"].as_str().unwrap_or("");
    let Ok(parsed) = document::typed(&format!("value = {literal}")) else {
        return;
    };
    let Some(value) = parsed.get("value") else {
        return;
    };
    let base = entry["source"]["path"]
        .as_str()
        .and_then(|path| Path::new(path).parent())
        .or(cwd)
        .map(Path::to_path_buf);
    let resolve = |value: &str| {
        let path = Path::new(value);
        if path.is_absolute() {
            Some(path.to_path_buf())
        } else {
            base.as_ref().map(|base| base.join(path))
        }
    };
    let complete = if scalar && let Some(value) = value.as_str() {
        let resolved = resolve(value);
        entry["resolved_path"] = json!(resolved);
        resolved.is_some()
    } else if array && let Some(values) = value.as_array() {
        let resolved: Vec<_> = values
            .iter()
            .filter_map(toml::Value::as_str)
            .map(resolve)
            .collect();
        let complete = resolved.iter().all(Option::is_some);
        entry["resolved_paths"] = json!(resolved);
        complete
    } else {
        return;
    };
    entry["path_base"] = json!(base);
    if !complete {
        entry["path_resolution"] = json!("unresolved");
        entry["path_resolution_reason"] = json!(
            "Relative command-line paths require a project working directory; global analysis does not use the process working directory"
        );
    }
}

pub(crate) fn analyze(request: &Value) -> CoreResult<Value> {
    let home = codex_home(request)?;
    let cwd = project_cwd(request)?;
    let system = system_file(request)?;
    let profile = request["profile"].as_str();
    if let Some(profile) = profile {
        files::valid_profile(profile)?;
    }
    let mut analyzer = Analyzer::new();
    let include_system = request["include_system"].as_bool().unwrap_or(true);
    if include_system {
        analyzer.layer("system", &system, true, None, false)?;
    }
    analyzer.layer("user", &home.join("config.toml"), true, None, false)?;
    if let Some(profile) = profile {
        analyzer.layer(
            "profile",
            &home.join(format!("{profile}.config.toml")),
            true,
            None,
            false,
        )?;
    }
    let trust_level = cwd.as_deref().and_then(|cwd| trust(&analyzer.merged, cwd));
    let trusted = trust_level.as_deref() == Some("trusted");
    let project_dirs = cwd
        .as_deref()
        .map(|cwd| project_directories(cwd, &project_markers(&analyzer.merged)))
        .unwrap_or_default();
    for directory in &project_dirs {
        analyzer.layer(
            "project",
            &directory.join(".codex").join("config.toml"),
            trusted,
            if trusted {
                None
            } else {
                Some("Project trust is not established as trusted; Codex skips project layers")
            },
            true,
        )?;
    }
    if let Some(overrides) = request["overrides"].as_array() {
        analyzer.overrides(overrides)?;
    }
    let managed = request["managed_path"]
        .as_str()
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if cfg!(windows) {
                home.join("managed_config.toml")
            } else {
                system
                    .parent()
                    .unwrap_or(Path::new("/etc/codex"))
                    .join("managed_config.toml")
            }
        });
    if include_system {
        analyzer
            .layers
            .push(legacy_managed(&managed, &mut analyzer.diagnostics));
    }
    let requirements_path = request["requirements_path"]
        .as_str()
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            system
                .parent()
                .unwrap_or(Path::new("/etc/codex"))
                .join("requirements.toml")
        });
    if include_system {
        analyzer.layers.push(requirements(
            &requirements_path,
            &analyzer.merged,
            &mut analyzer.diagnostics,
        ));
    }
    let mut effective = BTreeMap::new();
    flatten(&analyzer.merged, "", &mut effective);
    let mut entries = Vec::new();
    for (pointer, mut chain) in analyzer.chain {
        let value = effective.get(&pointer);
        let winner = if value.is_some() {
            chain
                .iter()
                .rposition(|origin| origin["status"] == "applied")
        } else {
            None
        };
        for (index, origin) in chain.iter_mut().enumerate() {
            if origin["status"] == "applied" {
                origin["status"] = json!(if Some(index) == winner {
                    "effective"
                } else {
                    "overridden"
                });
            }
        }
        let source =
            winner.map(|index| json!({"kind":chain[index]["kind"],"path":chain[index]["path"]}));
        let constrained = analyzer.diagnostics.iter().any(|item| {
            item["pointer"] == pointer && item["code"] == "managed_constraint_conflict"
        });
        let mut entry = json!({"pointer":pointer,"value_toml":value.cloned().unwrap_or_else(||chain.last().and_then(|item|item["value_toml"].as_str()).unwrap_or("").to_owned()),"source":source,"chain":chain,
            "status":if constrained {"constrained"}else if value.is_some(){"configured"}else{"inactive"}});
        if constrained {
            entry["reason"] =
                json!("Conflicts with local requirements; the final runtime fallback is unknown");
        }
        resolve_paths(&mut entry, cwd.as_deref());
        entries.push(entry);
    }
    redact_entries(
        &mut entries,
        request["reveal_secrets"].as_bool().unwrap_or(false),
    );
    let mut unknowns = vec![
        json!({"kind":"cloud","reason":"Cloud configuration and requirements are not retrieved; app-server integration is a documented future extension"}),
        json!({"kind":"builtins","reason":"Model-dependent and runtime defaults are not inferred from JSON Schema defaults"}),
        json!({"kind":"runtime_constraints","reason":"Local requirements are diagnosed, but Codex-specific fallbacks and policy composition require the runtime"}),
    ];
    if analyzer
        .layers
        .iter()
        .any(|layer| layer["kind"] == "legacy_managed" && layer["status"] != "missing")
    {
        unknowns.push(json!({"kind":"legacy_managed","reason":"Legacy managed configuration was observed but its runtime enforcement is not applied to ordinary configuration values"}));
    }
    if cfg!(target_os = "macos") {
        unknowns.push(
            json!({"kind":"mdm","reason":"macOS managed preferences are not read by this version"}),
        );
    }
    Ok(
        json!({"context":{"codex_home":home,"cwd":cwd,"scope":scope(cwd.as_deref()),"include_project":cwd.is_some(),"profile":profile,"trust":trust_level,"project_root":project_dirs.first(),"semantic_version":SEMANTIC_VERSION,"mode":"static","complete_runtime_analysis":false},
        "layers":analyzer.layers,"entries":entries,"diagnostics":analyzer.diagnostics,"unknowns":unknowns}),
    )
}
