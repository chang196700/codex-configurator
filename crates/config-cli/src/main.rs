use clap::{CommandFactory, Parser, Subcommand, ValueEnum};
use serde_json::{Value, json};
use std::{
    io::{self, Read, Write},
    path::PathBuf,
    process::ExitCode,
};

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Language {
    En,
    Zh,
}

#[derive(Parser, Debug)]
#[command(
    version,
    about = "Edit Codex configuration from the command line or terminal / Codex 配置工具"
)]
struct Cli {
    /// Explicit config.toml file / 指定配置文件
    #[arg(long, global = true, conflicts_with = "target")]
    file: Option<PathBuf>,
    /// user, system, project, or profile:NAME / 配置层
    #[arg(long, global = true)]
    target: Option<String>,
    /// Codex home directory / Codex 用户目录
    #[arg(long, global = true)]
    codex_home: Option<PathBuf>,
    /// Working directory used for project discovery / 项目工作目录
    #[arg(long, global = true)]
    cwd: Option<PathBuf>,
    /// Profile used for analysis; does not select the file to edit / 分析使用的 Profile
    #[arg(long, global = true)]
    profile: Option<String>,
    /// Emit a stable JSON response / 输出 JSON
    #[arg(long, global = true)]
    json: bool,
    #[arg(long, global = true, value_enum, default_value = "en")]
    lang: Language,
    /// Preview set/unset without saving / 仅预览编辑
    #[arg(long, global = true)]
    dry_run: bool,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Discover configuration files / 发现配置文件
    Paths,
    /// Print the selected file, including its actual values / 显示文件内容
    Show,
    /// Read a value using an RFC 6901 JSON Pointer, e.g. /model / 读取字段
    Get { pointer: String },
    /// Set a field using a TOML value / 设置字段
    Set {
        pointer: String,
        #[arg(
            long,
            conflicts_with = "stdin",
            required_unless_present = "stdin",
            allow_hyphen_values = true
        )]
        value: Option<String>,
        /// Read the TOML value from standard input / 从标准输入读取 TOML 值
        #[arg(long)]
        stdin: bool,
    },
    /// Remove a field so lower layers can apply / 取消字段设置
    Unset { pointer: String },
    /// Validate the selected file / 校验配置文件
    Validate {
        /// Validate a complete TOML document from standard input / 校验标准输入
        #[arg(long)]
        stdin: bool,
    },
    /// Compare selected file with another file / 比较文件
    Diff { other: PathBuf },
    /// Explain the static configuration overlay / 分析配置覆盖来源
    Analyze {
        /// Runtime TOML key=value overrides; can be repeated / 临时覆盖
        #[arg(short = 'c', long = "config", allow_hyphen_values = true)]
        overrides: Vec<String>,
        /// Include sensitive values in this explicitly requested output / 显示敏感值
        #[arg(long)]
        reveal_secrets: bool,
    },
    /// Manage separate Profile files / 管理 Profile 文件
    Profile {
        #[command(subcommand)]
        action: ProfileCommand,
    },
    /// Inspect or update the configuration schema / 查看或更新 Schema
    Schema {
        #[command(subcommand)]
        action: Option<SchemaCommand>,
    },
    /// List backups for the selected file / 列出备份
    Backup,
    /// Restore a backup using the current revision / 恢复备份
    Restore { backup_id: String },
    /// Read a Codex features snapshot / 读取 Codex 功能状态快照
    Features {
        #[arg(long)]
        executable: Option<PathBuf>,
        /// Read lifecycle stages only, without configured enablement / 仅读取功能阶段
        #[arg(long)]
        catalog: bool,
    },
    /// Open the schema-driven terminal editor / 打开终端表单编辑器
    Tui,
    /// Send one core JSON request from standard input / 从标准输入发送一条内核 JSON 请求
    Rpc,
}

#[derive(Subcommand, Debug)]
enum ProfileCommand {
    List,
    Create { name: String },
    Copy { name: String, new_name: String },
    Rename { name: String, new_name: String },
    Delete { name: String },
}

#[derive(Subcommand, Debug)]
enum SchemaCommand {
    Show,
    Check,
    Update,
    Import { path: PathBuf },
    Reset,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    if cli.command.is_none() {
        let _ = Cli::command().print_help();
        println!();
        return ExitCode::SUCCESS;
    }
    match execute(&cli) {
        Ok(result) => {
            if let Some(response) = result {
                let failed_validation =
                    response.pointer("/data/valid") == Some(&Value::Bool(false));
                if let Err(error) = print_response(&cli, &response)
                    && error.kind() != io::ErrorKind::BrokenPipe
                {
                    eprintln!("{error}");
                    return ExitCode::FAILURE;
                }
                if failed_validation {
                    return ExitCode::from(2);
                }
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            if cli.json {
                let _ = writeln!(io::stdout().lock(), "{error}");
            } else {
                let prefix = if matches!(cli.lang, Language::Zh) {
                    "错误"
                } else {
                    "Error"
                };
                eprintln!(
                    "{prefix} [{}]: {}",
                    error["error"]["code"].as_str().unwrap_or("unknown"),
                    error["error"]["message"]
                        .as_str()
                        .unwrap_or("Operation failed")
                );
                if let Some(diagnostics) = error["error"].get("diagnostics") {
                    eprintln!(
                        "{}",
                        serde_json::to_string_pretty(diagnostics).unwrap_or_default()
                    );
                }
            }
            ExitCode::FAILURE
        }
    }
}

fn execute(cli: &Cli) -> Result<Option<Value>, Value> {
    let command = cli.command.as_ref().expect("checked above");
    if cli.dry_run && !matches!(command, Command::Set { .. } | Command::Unset { .. }) {
        return Err(failure(
            "arguments",
            "--dry-run is only supported by set and unset / 仅 set 和 unset 支持 --dry-run",
        ));
    }
    let mut request = context(cli);
    let response = match command {
        Command::Paths => {
            request["op"] = json!("paths");
            call(request)?
        }
        Command::Rpc => {
            let request: Value = serde_json::from_str(&read_stdin()?)
                .map_err(|error| failure("json", &error.to_string()))?;
            call(request)?
        }
        Command::Show => open(cli)?,
        Command::Get { pointer } => {
            let snapshot = open(cli)?;
            call(json!({"op":"inspect", "content":snapshot["data"]["content"], "pointer":pointer}))?
        }
        Command::Set {
            pointer,
            value,
            stdin,
        } => {
            let value = if *stdin {
                read_stdin()?
            } else {
                value.clone().unwrap_or_default()
            };
            edit(cli, pointer, "set", Some(value))?
        }
        Command::Unset { pointer } => edit(cli, pointer, "unset", None)?,
        Command::Validate { stdin } => {
            let content = if *stdin {
                json!(read_stdin()?)
            } else {
                open(cli)?["data"]["content"].clone()
            };
            call(json!({"op":"validate", "content":content}))?
        }
        Command::Diff { other } => {
            let before = open(cli)?;
            let after = call(json!({"op":"open", "path":other}))?;
            call(
                json!({"op":"diff", "before":before["data"]["content"], "after":after["data"]["content"]}),
            )?
        }
        Command::Analyze {
            overrides,
            reveal_secrets,
        } => {
            request["op"] = json!("analyze");
            request["overrides"] = json!(overrides);
            request["reveal_secrets"] = json!(reveal_secrets);
            call(request)?
        }
        Command::Profile { action } => {
            request["op"] = json!("profiles");
            match action {
                ProfileCommand::List => request["action"] = json!("list"),
                ProfileCommand::Create { name } => {
                    request["action"] = json!("create");
                    request["name"] = json!(name);
                }
                ProfileCommand::Copy { name, new_name } => {
                    request["action"] = json!("copy");
                    request["name"] = json!(name);
                    request["new_name"] = json!(new_name);
                }
                ProfileCommand::Rename { name, new_name } => {
                    request["action"] = json!("rename");
                    request["name"] = json!(name);
                    request["new_name"] = json!(new_name);
                }
                ProfileCommand::Delete { name } => {
                    request["action"] = json!("delete");
                    request["name"] = json!(name);
                }
            }
            without_content(call(request)?)
        }
        Command::Schema { action } => match action {
            None | Some(SchemaCommand::Show) => call(json!({"op":"schema"}))?,
            Some(action) => {
                request["op"] = json!("schema_update");
                request["action"] = json!(match action {
                    SchemaCommand::Check => "check",
                    SchemaCommand::Update => "update",
                    SchemaCommand::Import { .. } => "import",
                    SchemaCommand::Reset => "reset",
                    SchemaCommand::Show => unreachable!(),
                });
                if let SchemaCommand::Import { path } = action {
                    request["path"] = json!(path);
                }
                call(request)?
            }
        },
        Command::Backup => call(json!({"op":"backups", "path":target_path(cli)?}))?,
        Command::Restore { backup_id } => {
            let snapshot = open(cli)?;
            without_content(call(
                json!({"op":"restore", "path":snapshot["data"]["path"], "backup_id":backup_id, "revision":snapshot["data"]["revision"]}),
            )?)
        }
        Command::Features {
            executable,
            catalog,
        } => {
            request["op"] = json!(if *catalog {
                "feature_catalog"
            } else {
                "features"
            });
            if let Some(executable) = executable {
                request["executable"] = json!(executable);
            }
            call(request)?
        }
        Command::Tui => {
            if cli.json {
                return Err(failure(
                    "arguments",
                    "--json cannot be combined with tui / tui 不支持 --json",
                ));
            }
            let path = target_path(cli)?;
            codex_config_tui::run(codex_config_tui::Options {
                path,
                codex_home: cli.codex_home.clone(),
                cwd: cli.cwd.clone(),
                profile: cli.profile.clone(),
                language: if matches!(cli.lang, Language::Zh) {
                    "zh".into()
                } else {
                    "en".into()
                },
            })
            .map_err(|error| failure("terminal", &error.to_string()))?;
            return Ok(None);
        }
    };
    Ok(Some(response))
}

fn context(cli: &Cli) -> Value {
    let mut result = json!({});
    if let Some(path) = &cli.codex_home {
        result["codex_home"] = json!(path);
    }
    if let Some(path) = &cli.cwd {
        result["cwd"] = json!(path);
    }
    if let Some(profile) = &cli.profile {
        result["profile"] = json!(profile);
    }
    result
}

fn target_path(cli: &Cli) -> Result<PathBuf, Value> {
    if let Some(path) = &cli.file {
        return Ok(path.clone());
    }
    let mut request = context(cli);
    request["op"] = json!("paths");
    let response = call(request)?;
    let paths = &response["data"];
    let target = cli.target.as_deref().unwrap_or("user");
    let path = match target {
        "user" => paths["user"].as_str().map(PathBuf::from),
        "system" => paths["system"].as_str().map(PathBuf::from),
        "project" => Some(
            PathBuf::from(paths["cwd"].as_str().unwrap_or("."))
                .join(".codex")
                .join("config.toml"),
        ),
        target if target.starts_with("profile:") => {
            let name = &target[8..];
            if name.is_empty()
                || name.len() > 128
                || name
                    .bytes()
                    .any(|ch| !ch.is_ascii_alphanumeric() && ch != b'-' && ch != b'_')
            {
                return Err(failure(
                    "arguments",
                    "Invalid Profile name / Profile 名称无效",
                ));
            }
            Some(
                PathBuf::from(paths["codex_home"].as_str().unwrap_or("."))
                    .join(format!("{name}.config.toml")),
            )
        }
        _ => {
            return Err(failure(
                "arguments",
                "--target must be user, system, project or profile:NAME",
            ));
        }
    };
    path.ok_or_else(|| failure("path", "Configuration path is unavailable / 配置路径不可用"))
}

fn open(cli: &Cli) -> Result<Value, Value> {
    call(json!({"op":"open", "path":target_path(cli)?}))
}

fn edit(cli: &Cli, pointer: &str, action: &str, value: Option<String>) -> Result<Value, Value> {
    let snapshot = open(cli)?;
    let mut request = json!({"op":"edit", "content":snapshot["data"]["content"], "pointer":pointer, "action":action});
    if let Some(value) = value {
        request["value_toml"] = json!(value);
    }
    let changed = call(request)?;
    if cli.dry_run {
        let mut diff = call(
            json!({"op":"diff", "before":snapshot["data"]["content"], "after":changed["data"]["content"]}),
        )?;
        diff["data"]["diagnostics"] = changed["data"]["diagnostics"].clone();
        diff["data"]["saved"] = json!(false);
        Ok(diff)
    } else {
        Ok(without_content(call(
            json!({"op":"save", "path":snapshot["data"]["path"], "content":changed["data"]["content"], "revision":snapshot["data"]["revision"]}),
        )?))
    }
}

fn without_content(mut response: Value) -> Value {
    if let Some(data) = response["data"].as_object_mut() {
        data.remove("content");
    }
    response
}

fn read_stdin() -> Result<String, Value> {
    let mut value = String::new();
    io::stdin()
        .read_to_string(&mut value)
        .map_err(|error| failure("stdin", &error.to_string()))?;
    if value.starts_with('\u{feff}') {
        value.drain(..'\u{feff}'.len_utf8());
    }
    Ok(value)
}

fn call(request: Value) -> Result<Value, Value> {
    let response = codex_config_core::dispatch(request);
    if response["ok"] == true {
        Ok(response)
    } else {
        Err(response)
    }
}

fn failure(code: &str, message: &str) -> Value {
    json!({"ok":false,"error":{"code":code,"message":message}})
}

fn print_response(cli: &Cli, response: &Value) -> io::Result<()> {
    let mut output = io::stdout().lock();
    if cli.json {
        return writeln!(output, "{}", serde_json::to_string_pretty(response)?);
    }
    let data = &response["data"];
    match cli.command.as_ref() {
        Some(Command::Show) => write!(output, "{}", data["content"].as_str().unwrap_or_default()),
        Some(Command::Get { .. }) => writeln!(
            output,
            "{}",
            data["value_toml"].as_str().unwrap_or_default()
        ),
        Some(Command::Diff { .. }) | Some(Command::Set { .. } | Command::Unset { .. })
            if cli.dry_run || matches!(cli.command, Some(Command::Diff { .. })) =>
        {
            write!(output, "{}", data["diff"].as_str().unwrap_or_default())
        }
        Some(Command::Validate { .. }) => {
            let valid = data["valid"] == true;
            let message = match (cli.lang, valid) {
                (Language::Zh, true) => "配置校验通过",
                (Language::Zh, false) => "配置校验未通过",
                (Language::En, true) => "Configuration is valid",
                (Language::En, false) => "Configuration is invalid",
            };
            writeln!(output, "{message}")?;
            if data["diagnostics"]
                .as_array()
                .is_some_and(|items| !items.is_empty())
            {
                writeln!(
                    output,
                    "{}",
                    serde_json::to_string_pretty(&data["diagnostics"])?
                )?;
            }
            Ok(())
        }
        _ => writeln!(output, "{}", serde_json::to_string_pretty(data)?),
    }
}
