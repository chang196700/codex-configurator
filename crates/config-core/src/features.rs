use crate::{CoreError, CoreResult, analysis};
use serde_json::{Value, json};
use std::{
    io::Read,
    path::Path,
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

fn read_command(
    executable: &str,
    args: &[&str],
    home: &Path,
    cwd: &Path,
    timeout: Duration,
) -> Result<String, (&'static str, String)> {
    let mut command = Command::new(executable);
    command
        .args(args)
        .env("CODEX_HOME", home)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000);
    }
    let mut child = command
        .spawn()
        .map_err(|error| ("codex_unavailable", error.to_string()))?;
    let stdout = child
        .stdout
        .take()
        .ok_or(("process_error", "Cannot capture feature output".into()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or(("process_error", "Cannot capture feature diagnostics".into()))?;
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.take(1024 * 1024).read_to_string(&mut text);
        let _ = sender.send(text);
    });
    // Drain without exposing errors that might quote sensitive config values.
    thread::spawn(move || {
        let mut text = String::new();
        let _ = stderr.take(64 * 1024).read_to_string(&mut text);
    });
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                return receiver
                    .recv_timeout(Duration::from_millis(250))
                    .map_err(|_| {
                        (
                            "codex_output_timeout",
                            "Codex output did not close after the process exited".into(),
                        )
                    });
            }
            Ok(Some(status)) => {
                return Err((
                    "codex_command_failed",
                    format!(
                        "Codex read command exited with status {}; check its configuration",
                        status
                            .code()
                            .map(|code| code.to_string())
                            .unwrap_or_else(|| "unknown".into())
                    ),
                ));
            }
            Err(error) => return Err(("process_error", error.to_string())),
            Ok(None) => {}
        }
        if started.elapsed() > timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err((
                "codex_timeout",
                format!("Codex read command exceeded {} seconds", timeout.as_secs()),
            ));
        }
        thread::sleep(Duration::from_millis(25));
    }
}

fn parse_feature(line: &str) -> Option<Value> {
    let columns: Vec<_> = line.split_whitespace().collect();
    let enabled = columns.last()?.parse::<bool>().ok()?;
    if columns.len() < 3 {
        return None;
    }
    Some(json!({
        "name": columns[0],
        "stage": columns[1..columns.len() - 1].join(" "),
        "enabled": enabled,
    }))
}

/// Read the executable's feature stages without exposing configuration values.
pub(crate) fn catalog(request: &Value) -> CoreResult<Value> {
    let executable = request["executable"].as_str().unwrap_or("codex");
    if executable.is_empty() {
        return Err(CoreError::new(
            "invalid_request",
            "executable cannot be empty",
        ));
    }
    // Resolve an explicitly relative executable before changing its working directory.
    let executable =
        if Path::new(executable).is_relative() && Path::new(executable).components().count() > 1 {
            crate::absolute(executable)?.to_string_lossy().into_owned()
        } else {
            executable.to_owned()
        };
    let temporary = tempfile::Builder::new()
        .prefix("codex-configurator-features-")
        .tempdir()?;
    let home = temporary.path().join("home");
    let cwd = temporary.path().join("workspace");
    std::fs::create_dir(&home)?;
    std::fs::create_dir(&cwd)?;
    let mut result = json!({
        "available": false,
        "features": [],
        "context": {
            "executable": executable,
            "version": Value::Null,
            "cwd": Value::Null,
            "codex_home": Value::Null,
            "argv": ["features", "list"],
            "version_argv": ["--version"],
            "scope": "catalog",
            "include_project": false,
            "configuration": "isolated temporary home and working directory",
            "enablement_included": true,
            "enablement_scope": "isolated",
        },
        "source": "codex features list",
        "captured_at": chrono::Utc::now().to_rfc3339(),
        "diagnostics": [],
    });
    for (args, timeout) in [
        (&["--version"][..], Duration::from_secs(3)),
        (&["features", "list"][..], Duration::from_secs(8)),
    ] {
        let output = match read_command(&executable, args, &home, &cwd, timeout) {
            Ok(output) => output,
            Err((code, message)) => {
                result["diagnostics"] = json!([{
                    "severity": "warning", "code": code, "message": message,
                    "command": args.join(" "),
                }]);
                return Ok(result);
            }
        };
        if args == ["--version"] {
            if output.trim().is_empty() {
                result["diagnostics"] = json!([{
                    "severity": "warning",
                    "code": "unsupported_version_output",
                    "message": "Codex returned an empty version string",
                    "command": "--version",
                }]);
                return Ok(result);
            }
            result["context"]["version"] =
                json!(output.trim().chars().take(256).collect::<String>());
            continue;
        }
        let features: Option<Vec<_>> = output
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| {
                let feature = parse_feature(line)?;
                Some(json!({
                    "name": feature["name"],
                    "stage": feature["stage"],
                    "enabled": feature["enabled"],
                }))
            })
            .collect();
        match features {
            Some(features) if !features.is_empty() => {
                result["features"] = json!(features);
                result["available"] = json!(true);
            }
            _ => {
                result["diagnostics"] = json!([{
                    "severity": "warning",
                    "code": "unsupported_feature_output",
                    "message": "Codex returned no feature rows or an unsupported feature-list format",
                    "command": "features list",
                }]);
            }
        }
    }
    Ok(result)
}

pub(crate) fn snapshot(request: &Value) -> CoreResult<Value> {
    let executable = request["executable"].as_str().unwrap_or("codex");
    if executable.is_empty() {
        return Err(CoreError::new(
            "invalid_request",
            "executable cannot be empty",
        ));
    }
    let home = analysis::codex_home(request)?;
    let cwd = analysis::project_cwd(request)?;
    let mut context = json!({"executable":executable,"version":Value::Null,"cwd":cwd,"codex_home":home,"argv":["features","list"],
        "scope":if cwd.is_some(){"project"}else{"global"},"include_project":cwd.is_some(),
        "profile_verified":false,"unsaved_edits_verified":false,"configuration":"saved files only","version_argv":["--version"]});
    let Some(cwd) = cwd else {
        context["argv"] = json!([]);
        context["version_argv"] = json!([]);
        return Ok(
            json!({"available":false,"disabled":true,"features":[],"context":context,
            "diagnostics":[{"severity":"warning","code":"unsupported_scope","message":"Feature snapshots require an open project; no Codex command was started in global scope"}],
            "captured_at":chrono::Utc::now().to_rfc3339()}),
        );
    };
    let mut diagnostics = Vec::new();
    match read_command(
        executable,
        &["--version"],
        &home,
        &cwd,
        Duration::from_secs(3),
    ) {
        Ok(version) => {
            context["version"] = json!(version.trim().chars().take(256).collect::<String>())
        }
        Err((code, message)) => diagnostics.push(
            json!({"severity":"warning","code":code,"message":message,"command":"--version"}),
        ),
    }
    let output = match read_command(
        executable,
        &["features", "list"],
        &home,
        &cwd,
        Duration::from_secs(8),
    ) {
        Ok(output) => output,
        Err((code, message)) => {
            diagnostics.push(json!({"severity":"warning","code":code,"message":message,"command":"features list"}));
            return Ok(
                json!({"available":false,"features":[],"context":context,"diagnostics":diagnostics,"captured_at":chrono::Utc::now().to_rfc3339()}),
            );
        }
    };
    let features: Vec<_> = output.lines().filter_map(parse_feature).collect();
    Ok(
        json!({"available":true,"features":features,"context":context,"captured_at":chrono::Utc::now().to_rfc3339(),"diagnostics":diagnostics,"source":"codex features list"}),
    )
}
