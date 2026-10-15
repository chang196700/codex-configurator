use crate::{
    CoreError, CoreResult, SEMANTIC_VERSION, diagnostic, document, pointer_part, required,
};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs,
    path::PathBuf,
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};

pub const OFFICIAL_URL: &str = "https://developers.openai.com/codex/config-schema.json";
const BUNDLED: &str = include_str!("../../../assets/config-schema.json");
const MAX_SCHEMA_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone)]
struct Loaded {
    raw: Value,
    form: Value,
    metadata: Value,
    validator: Arc<jsonschema::Validator>,
}

pub(crate) fn hash(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn cache_path() -> CoreResult<PathBuf> {
    let base = std::env::var_os("CODEX_CONFIGURATOR_DATA_DIR")
        .map(PathBuf::from)
        .or_else(|| dirs::data_local_dir().map(|path| path.join("codex-configurator")))
        .ok_or_else(|| {
            CoreError::new(
                "no_data_directory",
                "Cannot find the application data directory",
            )
        })?;
    Ok(base.join("schema.json"))
}

fn local_refs_only(value: &Value) -> CoreResult<()> {
    match value {
        Value::Object(map) => {
            if let Some(reference) = map.get("$ref").and_then(Value::as_str)
                && !reference.starts_with('#')
            {
                return Err(CoreError::new(
                    "unsafe_schema",
                    "Only local JSON Schema references are accepted",
                ));
            }
            for value in map.values() {
                local_refs_only(value)?;
            }
        }
        Value::Array(array) => {
            for value in array {
                local_refs_only(value)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn merge(target: &mut Value, incoming: Value) {
    match (target, incoming) {
        (Value::Object(target), Value::Object(incoming)) => {
            for (key, value) in incoming {
                if key == "required"
                    && let (Some(Value::Array(existing)), Value::Array(new)) =
                        (target.get_mut(&key), &value)
                {
                    for entry in new {
                        if !existing.contains(entry) {
                            existing.push(entry.clone());
                        }
                    }
                    continue;
                }
                if let Some(existing) = target.get_mut(&key) {
                    merge(existing, value);
                } else {
                    target.insert(key, value);
                }
            }
        }
        (target, incoming) => *target = incoming,
    }
}

fn expand(
    node: &Value,
    root: &Value,
    stack: &mut BTreeSet<String>,
    depth: usize,
) -> CoreResult<Value> {
    if depth > 128 {
        return Err(CoreError::new(
            "schema_too_deep",
            "Schema nesting exceeds 128 levels",
        ));
    }
    let Some(object) = node.as_object() else {
        return Ok(node.clone());
    };
    let mut output = json!({});
    if let Some(reference) = object.get("$ref").and_then(Value::as_str) {
        if stack.contains(reference) {
            return Ok(json!({"x-recursive-ref":reference,"translation_status":"source-fallback"}));
        }
        let target = root
            .pointer(reference.strip_prefix('#').unwrap_or(reference))
            .ok_or_else(|| {
                CoreError::new(
                    "invalid_schema",
                    format!("Unresolved schema reference: {reference}"),
                )
            })?;
        stack.insert(reference.to_owned());
        output = expand(target, root, stack, depth + 1)?;
        stack.remove(reference);
    }
    if let Some(all_of) = object.get("allOf").and_then(Value::as_array) {
        let branches = all_of
            .iter()
            .map(|branch| expand(branch, root, stack, depth + 1))
            .collect::<CoreResult<Vec<_>>>()?;
        for branch in &branches {
            merge(&mut output, branch.clone());
        }
        // Aggregate shape for form controls, while retaining compound logical
        // constraints. For example, two separate `not` clauses are conjunctive,
        // not a single combined negation.
        if branches.len() > 1 {
            output["allOf"] = Value::Array(branches);
        }
    }
    for (key, value) in object {
        if matches!(key.as_str(), "$ref" | "allOf" | "definitions" | "$defs") {
            continue;
        }
        let resolved = match key.as_str() {
            "properties" | "patternProperties" => {
                let mut properties = Map::new();
                if let Some(values) = value.as_object() {
                    for (name, child) in values {
                        let mut resolved = expand(child, root, stack, depth + 1)?;
                        if let Some(map) = resolved.as_object_mut() {
                            let label = map
                                .get("title")
                                .and_then(Value::as_str)
                                .unwrap_or(name)
                                .to_owned();
                            map.insert("label_en".into(), json!(label));
                            map.insert("label_zh".into(), json!(name));
                            map.insert("translation_status".into(), json!("source-fallback"));
                            if let Some(description) = map.get("description").cloned() {
                                map.insert("description_en".into(), description);
                            }
                        }
                        properties.insert(name.clone(), resolved);
                    }
                }
                Value::Object(properties)
            }
            "additionalProperties"
            | "items"
            | "contains"
            | "not"
            | "if"
            | "then"
            | "else"
            | "propertyNames" => {
                if let Some(array) = value.as_array() {
                    Value::Array(
                        array
                            .iter()
                            .map(|child| expand(child, root, stack, depth + 1))
                            .collect::<CoreResult<Vec<_>>>()?,
                    )
                } else {
                    expand(value, root, stack, depth + 1)?
                }
            }
            "oneOf" | "anyOf" | "prefixItems" => Value::Array(
                value
                    .as_array()
                    .unwrap_or(&Vec::new())
                    .iter()
                    .map(|child| expand(child, root, stack, depth + 1))
                    .collect::<CoreResult<Vec<_>>>()?,
            ),
            _ => value.clone(),
        };
        if let Some(object) = output.as_object_mut() {
            object.insert(key.clone(), resolved);
        }
    }
    Ok(output)
}

fn allow_unknown_fields(node: &mut Value) {
    match node {
        Value::Object(map) => {
            if map.get("additionalProperties") == Some(&Value::Bool(false)) {
                map.insert("additionalProperties".into(), Value::Bool(true));
            }
            for value in map.values_mut() {
                allow_unknown_fields(value);
            }
        }
        Value::Array(values) => {
            for value in values {
                allow_unknown_fields(value);
            }
        }
        _ => {}
    }
}

fn parse_schema(text: &str, source: &str) -> CoreResult<Loaded> {
    if text.len() > MAX_SCHEMA_BYTES {
        return Err(CoreError::new(
            "schema_too_large",
            "Schema exceeds the 8 MiB limit",
        ));
    }
    let raw: Value = serde_json::from_str(text)
        .map_err(|error| CoreError::new("invalid_schema", error.to_string()))?;
    if !raw.get("properties").is_some_and(Value::is_object) {
        return Err(CoreError::new(
            "invalid_schema",
            "Expected a configuration object schema with properties",
        ));
    }
    local_refs_only(&raw)?;
    // Compile the original as well: imports must be valid, including references.
    jsonschema::options()
        .with_draft(jsonschema::Draft::Draft7)
        .build(&raw)
        .map_err(|error| CoreError::new("invalid_schema", error.to_string()))?;
    let form = expand(&raw, &raw, &mut BTreeSet::new(), 0)?;
    let mut permissive = raw.clone();
    allow_unknown_fields(&mut permissive);
    let validator = jsonschema::options()
        .with_draft(jsonschema::Draft::Draft7)
        .build(&permissive)
        .map_err(|error| CoreError::new("invalid_schema", error.to_string()))?;
    let metadata = json!({"source":source,"sha256":hash(text.as_bytes()),"draft":"draft-07", "bundled_date":"2026-10-15",
        "semantic_version":SEMANTIC_VERSION,"translation_status":"source-fallback","official_url":OFFICIAL_URL});
    Ok(Loaded {
        raw,
        form,
        metadata,
        validator: Arc::new(validator),
    })
}

fn load() -> CoreResult<Loaded> {
    static CACHE: OnceLock<Mutex<Option<(String, Loaded)>>> = OnceLock::new();
    let path = cache_path()?;
    let (text, source) = match fs::read_to_string(&path) {
        Ok(text) => (text, path.to_string_lossy().into_owned()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            (BUNDLED.to_owned(), format!("bundled:{OFFICIAL_URL}"))
        }
        Err(error) => return Err(error.into()),
    };
    let key = format!("{}:{}", source, hash(text.as_bytes()));
    let mut cache = CACHE
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|_| CoreError::new("internal_error", "Schema cache lock failed"))?;
    if let Some((cached_key, loaded)) = cache.as_ref()
        && cached_key == &key
    {
        return Ok(loaded.clone());
    }
    let mut loaded = match parse_schema(&text, &source) {
        Ok(loaded) => loaded,
        Err(error) if text != BUNDLED => {
            let mut fallback = parse_schema(BUNDLED, &format!("bundled:{OFFICIAL_URL}"))?;
            fallback.metadata["cache_warning"] = json!(error.message);
            fallback
        }
        Err(error) => return Err(error),
    };
    if let Ok(metadata) = fs::read_to_string(path.with_extension("meta.json"))
        && let Ok(metadata) = serde_json::from_str::<Value>(&metadata)
        && metadata["sha256"] == loaded.metadata["sha256"]
    {
        loaded.metadata["cache_path"] = json!(path);
        loaded.metadata["source"] = metadata["source"].clone();
        loaded.metadata["updated_at"] = metadata["updated_at"].clone();
    }
    *cache = Some((key, loaded.clone()));
    Ok(loaded)
}

fn categories(raw: &Value) -> Vec<Value> {
    let groups = [
        ("models", "Models and providers", "模型与提供商"),
        ("permissions", "Permissions and sandbox", "权限与沙盒"),
        ("integrations", "MCP, apps and plugins", "MCP、应用与插件"),
        ("agents", "Agents and instructions", "代理与指令"),
        ("interface", "Interface and notifications", "界面与通知"),
        ("runtime", "Runtime and storage", "运行时与存储"),
        ("advanced", "Advanced settings", "高级设置"),
    ];
    let mut result: Vec<Value> = groups
        .iter()
        .map(|(id, en, zh)| json!({"id":id,"label_en":en,"label_zh":zh,"keys":[]}))
        .collect();
    if let Some(properties) = raw.get("properties").and_then(Value::as_object) {
        for key in properties.keys() {
            let group = if key.starts_with("model")
                || matches!(
                    key.as_str(),
                    "openai_base_url"
                        | "chatgpt_base_url"
                        | "service_tier"
                        | "oss_provider"
                        | "review_model"
                ) {
                0
            } else if key.contains("approval")
                || key.contains("sandbox")
                || key.contains("permission")
                || matches!(
                    key.as_str(),
                    "auto_review" | "windows" | "projects" | "shell_environment_policy"
                )
            {
                1
            } else if key.starts_with("mcp")
                || matches!(key.as_str(), "apps" | "plugins" | "marketplaces" | "skills")
            {
                2
            } else if key.contains("instruction")
                || key.starts_with("project_doc")
                || matches!(
                    key.as_str(),
                    "agents" | "orchestrator" | "memories" | "goals" | "hooks"
                )
            {
                3
            } else if matches!(
                key.as_str(),
                "tui"
                    | "notify"
                    | "notifications"
                    | "personality"
                    | "notice"
                    | "file_opener"
                    | "audio"
                    | "realtime"
                    | "desktop"
            ) {
                4
            } else if key.contains("dir")
                || key.contains("home")
                || matches!(
                    key.as_str(),
                    "history" | "analytics" | "otel" | "feedback" | "cloud"
                )
            {
                5
            } else {
                6
            };
            result[group]["keys"]
                .as_array_mut()
                .expect("category keys is an array")
                .push(json!(key));
        }
    }
    result
}

pub(crate) fn describe() -> CoreResult<Value> {
    let loaded = load()?;
    Ok(
        json!({"schema":loaded.raw,"form_schema":loaded.form,"metadata":loaded.metadata,"categories":categories(&loaded.raw)}),
    )
}

fn candidates<'a>(schema: &'a Value, instance: &Value) -> Vec<&'a Value> {
    for union in ["oneOf", "anyOf"] {
        if let Some(branches) = schema.get(union).and_then(Value::as_array) {
            let matching: Vec<_> = branches
                .iter()
                .filter(|branch| match branch.get("type").and_then(Value::as_str) {
                    Some("object") => instance.is_object(),
                    Some("array") => instance.is_array(),
                    Some("string") => instance.is_string(),
                    Some("boolean") => instance.is_boolean(),
                    Some("number" | "integer") => instance.is_number(),
                    Some("null") => instance.is_null(),
                    _ => true,
                })
                .collect();
            if !matching.is_empty() {
                return matching;
            }
        }
    }
    vec![schema]
}

fn unknown_fields(instance: &Value, schema: &Value, pointer: &str, diagnostics: &mut Vec<Value>) {
    match instance {
        Value::Object(object) => {
            let options = candidates(schema, instance);
            for (key, value) in object {
                let next = format!("{pointer}/{}", pointer_part(key));
                let known = options.iter().find_map(|option| {
                    option
                        .get("properties")
                        .and_then(|properties| properties.get(key))
                });
                if let Some(child) = known {
                    unknown_fields(value, child, &next, diagnostics);
                    continue;
                }
                let additional = options.iter().find_map(|option| {
                    option
                        .get("additionalProperties")
                        .filter(|value| value.is_object())
                });
                if let Some(child) = additional {
                    unknown_fields(value, child, &next, diagnostics);
                    continue;
                }
                if options
                    .iter()
                    .all(|option| option.get("additionalProperties") == Some(&Value::Bool(false)))
                {
                    diagnostics.push(diagnostic(
                        "warning",
                        "unknown_field",
                        &next,
                        "This schema does not recognize the field; its content is preserved",
                    ));
                }
            }
        }
        Value::Array(array) => {
            let options = candidates(schema, instance);
            if let Some(items) = options.iter().find_map(|option| option.get("items")) {
                for (index, value) in array.iter().enumerate() {
                    unknown_fields(value, items, &format!("{pointer}/{index}"), diagnostics);
                }
            }
        }
        _ => {}
    }
}

pub(crate) fn validate(content: &str) -> CoreResult<Vec<Value>> {
    let value = match document::typed(content) {
        Ok(value) => value,
        Err(error) => {
            return Ok(if error.diagnostics.is_empty() {
                vec![diagnostic("error", "toml_syntax", "", error.message)]
            } else {
                error.diagnostics
            });
        }
    };
    let instance = serde_json::to_value(value)
        .map_err(|error| CoreError::new("unsupported_value", error.to_string()))?;
    let loaded = load()?;
    let mut diagnostics: Vec<_> = loaded
        .validator
        .iter_errors(&instance)
        .map(|error| {
            let mut detail = diagnostic(
                "error",
                "schema_validation",
                &error.instance_path().to_string(),
                error.masked().to_string(),
            );
            detail["schema_path"] = json!(error.schema_path().to_string());
            detail
        })
        .collect();
    unknown_fields(&instance, &loaded.form, "", &mut diagnostics);
    if instance.get("profile").is_some() || instance.get("profiles").is_some() {
        diagnostics.push(diagnostic("warning", "legacy_profiles", "/profiles", "Codex 0.134.0 and later use <name>.config.toml profile files; inline profiles and the profile selector are legacy settings"));
    }
    Ok(diagnostics)
}

fn download() -> CoreResult<String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(25)))
        .build()
        .into();
    agent
        .get(OFFICIAL_URL)
        .call()
        .map_err(|error| CoreError::new("schema_download_failed", error.to_string()))?
        .body_mut()
        .read_to_string()
        .map_err(|error| CoreError::new("schema_download_failed", error.to_string()))
}

pub(crate) fn update(request: &Value) -> CoreResult<Value> {
    let action = required(request, "action")?;
    match action {
        "check" => {
            let remote = download()?;
            let checked = parse_schema(&remote, OFFICIAL_URL)?;
            let mut current = describe()?;
            current["update"] = json!({"available":current["metadata"]["sha256"] != checked.metadata["sha256"],"remote":checked.metadata});
            Ok(current)
        }
        "update" | "import" => {
            let (text, source) = if action == "update" {
                (download()?, OFFICIAL_URL.to_string())
            } else {
                let path = crate::absolute(required(request, "path")?)?;
                (
                    fs::read_to_string(&path)?,
                    path.to_string_lossy().into_owned(),
                )
            };
            parse_schema(&text, &source)?;
            let path = cache_path()?;
            let parent = path
                .parent()
                .ok_or_else(|| CoreError::new("invalid_path", "Invalid schema cache path"))?;
            fs::create_dir_all(parent)?;
            crate::files::atomic_write(&path, text.as_bytes())?;
            let metadata = json!({"source":source,"sha256":hash(text.as_bytes()),"updated_at":chrono::Utc::now().to_rfc3339()});
            let metadata = serde_json::to_vec_pretty(&metadata)
                .map_err(|error| CoreError::new("invalid_schema", error.to_string()))?;
            crate::files::atomic_write(&path.with_extension("meta.json"), &metadata)?;
            describe()
        }
        "reset" => {
            let path = cache_path()?;
            if path.exists() {
                fs::remove_file(&path)?;
            }
            let metadata = path.with_extension("meta.json");
            if metadata.exists() {
                fs::remove_file(metadata)?;
            }
            describe()
        }
        _ => Err(CoreError::new(
            "invalid_request",
            "schema_update action must be check, update, import, or reset",
        )),
    }
}
