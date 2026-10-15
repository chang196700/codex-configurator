use crate::{CoreError, CoreResult, absolute, document, required, schema};
use fs2::FileExt;
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

const MAX_CONFIG_BYTES: u64 = 16 * 1024 * 1024;

fn refuse_link(path: &Path) -> CoreResult<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(CoreError::new(
            "symlink_target",
            "Refusing to replace a symlink; open its resolved target explicitly",
        )),
        Ok(metadata) if !metadata.is_file() => Err(CoreError::new(
            "invalid_path",
            "The target is not a regular file",
        )),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

pub(crate) fn read(path: &Path) -> CoreResult<Option<String>> {
    match fs::metadata(path) {
        Ok(metadata) if metadata.len() > MAX_CONFIG_BYTES => {
            return Err(CoreError::new(
                "file_too_large",
                "Configuration file exceeds the 16 MiB limit",
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
        _ => {}
    }
    match fs::read_to_string(path) {
        Ok(content) => Ok(Some(content)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

pub(crate) fn open(path: &Path) -> CoreResult<Value> {
    let content = read(path)?;
    let exists = content.is_some();
    let revision = content
        .as_ref()
        .map(|content| schema::hash(content.as_bytes()));
    let content = content.unwrap_or_default();
    let diagnostics = schema::validate(&content)?;
    Ok(
        json!({"path":path,"content":content,"revision":revision,"exists":exists,"diagnostics":diagnostics}),
    )
}

#[cfg(unix)]
fn private(path: &Path, directory: bool) -> CoreResult<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(
        path,
        fs::Permissions::from_mode(if directory { 0o700 } else { 0o600 }),
    )?;
    Ok(())
}

#[cfg(windows)]
fn private(path: &Path, _directory: bool) -> CoreResult<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::ConvertStringSecurityDescriptorToSecurityDescriptorW;
    use windows_sys::Win32::Security::{
        DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, SetFileSecurityW,
    };
    let sddl: Vec<u16> = "D:P(A;;FA;;;OW)(A;;FA;;;SY)\0".encode_utf16().collect();
    let mut descriptor = std::ptr::null_mut();
    let path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    // A protected DACL grants the owner and SYSTEM access. No inherited grants
    // can make backup secrets readable by other local users.
    unsafe {
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            std::ptr::null_mut(),
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let result = SetFileSecurityW(
            path.as_ptr(),
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        );
        LocalFree(descriptor);
        if result == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    Ok(())
}

#[cfg(not(any(unix, windows)))]
fn private(_path: &Path, _directory: bool) -> CoreResult<()> {
    Ok(())
}

fn private_directory(path: &Path) -> CoreResult<()> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(CoreError::new(
                "unsafe_backup_path",
                "Backup location must be a regular directory",
            ));
        }
    } else {
        fs::create_dir_all(path)?;
    }
    private(path, true)
}

#[cfg(windows)]
fn replace(temp: &Path, target: &Path, exists: bool) -> CoreResult<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_WRITE_THROUGH, MoveFileExW, ReplaceFileW,
    };
    let temp: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
    let target: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    // ReplaceFile preserves the original file's DACL and other metadata.
    // Unlike remove + rename, there is no interval without the config file.
    let result = unsafe {
        if exists {
            ReplaceFileW(
                target.as_ptr(),
                temp.as_ptr(),
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        } else {
            MoveFileExW(temp.as_ptr(), target.as_ptr(), MOVEFILE_WRITE_THROUGH)
        }
    };
    if result == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

pub(crate) fn atomic_write(path: &Path, bytes: &[u8]) -> CoreResult<()> {
    atomic_write_inner(path, bytes, true)
}

fn atomic_create(path: &Path, bytes: &[u8]) -> CoreResult<()> {
    atomic_write_inner(path, bytes, false)
}

fn atomic_write_inner(path: &Path, bytes: &[u8], allow_replace: bool) -> CoreResult<()> {
    refuse_link(path)?;
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::new("invalid_path", "Target has no parent directory"))?;
    let exists = path.exists();
    if exists && !allow_replace {
        return Err(CoreError::new(
            "already_exists",
            "The destination already exists",
        ));
    }
    let mut temporary = tempfile::Builder::new()
        .prefix(".codex-configurator-")
        .tempfile_in(parent)?;
    private(temporary.path(), false)?;
    temporary.write_all(bytes)?;
    temporary.flush()?;
    #[cfg(unix)]
    if exists {
        temporary
            .as_file()
            .set_permissions(fs::metadata(path)?.permissions())?;
    }
    temporary.as_file().sync_all()?;
    #[cfg(windows)]
    {
        // Close the file handle before ReplaceFileW: Windows sharing modes may
        // otherwise reject replacing a still-open temporary file with OS 32.
        let temporary_path = temporary.into_temp_path();
        replace(&temporary_path, path, exists)?;
    }
    #[cfg(not(windows))]
    {
        if exists {
            fs::rename(temporary.path(), path)?;
        } else {
            // persist_noclobber uses a no-overwrite operation for newly created files.
            temporary
                .persist_noclobber(path)
                .map_err(|error| CoreError::from(error.error))?;
        }
        File::open(parent)?.sync_all()?;
    }
    Ok(())
}

fn backup_directory(path: &Path) -> CoreResult<PathBuf> {
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::new("invalid_path", "Target has no parent directory"))?;
    let key = schema::hash(path.as_os_str().to_string_lossy().as_bytes());
    Ok(parent.join(".codex-configurator-backups").join(&key[..16]))
}

fn make_backup(path: &Path, content: &str) -> CoreResult<Value> {
    let directory = backup_directory(path)?;
    private_directory(
        directory
            .parent()
            .ok_or_else(|| CoreError::new("invalid_path", "Invalid backup directory"))?,
    )?;
    private_directory(&directory)?;
    let time = chrono::Utc::now();
    let id = format!(
        "{}-{}.toml",
        time.format("%Y%m%dT%H%M%S%.9fZ"),
        &schema::hash(content.as_bytes())[..12]
    );
    let backup = directory.join(&id);
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&backup)?;
    private(&backup, false)?;
    output.write_all(content.as_bytes())?;
    output.sync_all()?;
    Ok(json!({"id":id,"path":backup,"created_at":time.to_rfc3339()}))
}

fn lock_directory(path: &Path) -> CoreResult<File> {
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::new("invalid_path", "Target has no parent directory"))?;
    let lock_path = parent.join(".codex-configurator.lock");
    if fs::symlink_metadata(&lock_path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(CoreError::new(
            "unsafe_lock_path",
            "Lock file cannot be a symlink",
        ));
    }
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)?;
    private(&lock_path, false)?;
    lock.try_lock_exclusive().map_err(|error| {
        CoreError::new(
            "file_busy",
            format!("Another writer holds the configuration lock: {error}"),
        )
    })?;
    Ok(lock)
}

fn check_revision(content: &Option<String>, revision: &Value) -> CoreResult<()> {
    let actual = content.as_ref().map(|text| schema::hash(text.as_bytes()));
    if revision.as_str() != actual.as_deref() || (!revision.is_null() && !revision.is_string()) {
        return Err(CoreError::new(
            "revision_conflict",
            "The file changed outside this editor. Reload and review the changes before saving.",
        ));
    }
    Ok(())
}

fn reject_new_errors(before: &str, after: &str) -> CoreResult<()> {
    let diagnostics = schema::validate(after)?;
    let errors: Vec<_> = diagnostics
        .iter()
        .filter(|item| item["severity"] == "error")
        .cloned()
        .collect();
    if errors.iter().any(|item| item["code"] == "toml_syntax") {
        return Err(CoreError::diagnostics(
            "invalid_toml",
            "Fix TOML syntax errors before saving",
            errors,
        ));
    }
    let baseline = schema::validate(before)?;
    let signatures: HashSet<String> = baseline
        .iter()
        .filter(|item| item["severity"] == "error")
        .map(|item| {
            format!(
                "{}|{}|{}",
                item["pointer"], item["schema_path"], item["message"]
            )
        })
        .collect();
    let before_json = document::typed(before)
        .ok()
        .and_then(|value| serde_json::to_value(value).ok());
    let after_json = document::typed(after)
        .ok()
        .and_then(|value| serde_json::to_value(value).ok());
    let introduced: Vec<_> = errors
        .into_iter()
        .filter(|item| {
            let signature = format!(
                "{}|{}|{}",
                item["pointer"], item["schema_path"], item["message"]
            );
            if !signatures.contains(&signature) {
                return true;
            }
            let pointer = item["pointer"].as_str().unwrap_or("");
            // Existing missing required members can remain while other fields change.
            if item["schema_path"]
                .as_str()
                .unwrap_or("")
                .ends_with("/required")
            {
                return false;
            }
            before_json
                .as_ref()
                .and_then(|value| value.pointer(pointer))
                != after_json.as_ref().and_then(|value| value.pointer(pointer))
        })
        .collect();
    if !introduced.is_empty() {
        return Err(CoreError::diagnostics(
            "new_validation_errors",
            "This change introduces schema errors; existing unrelated errors may be retained",
            introduced,
        ));
    }
    Ok(())
}

pub(crate) fn save(path: &Path, content: &str, revision: &Value) -> CoreResult<Value> {
    if content.len() as u64 > MAX_CONFIG_BYTES {
        return Err(CoreError::new(
            "file_too_large",
            "Configuration exceeds the 16 MiB limit",
        ));
    }
    refuse_link(path)?;
    let original = read(path)?;
    check_revision(&original, revision)?;
    reject_new_errors(original.as_deref().unwrap_or(""), content)?;
    if original.as_deref() == Some(content) {
        return open(path);
    }
    let parent = path
        .parent()
        .ok_or_else(|| CoreError::new("invalid_path", "Target has no parent directory"))?;
    fs::create_dir_all(parent)?;
    let _lock = lock_directory(path)?;
    let current = read(path)?;
    check_revision(&current, revision)?;
    let backup = current
        .as_deref()
        .map(|old| make_backup(path, old))
        .transpose()?;
    // Recheck after the backup operation, so an external editor cannot be
    // silently overwritten after the initial optimistic revision check.
    check_revision(&read(path)?, revision)?;
    if current.is_some() {
        atomic_write(path, content.as_bytes())?;
    } else {
        atomic_create(path, content.as_bytes())?;
    }
    let mut snapshot = open(path)?;
    if let Some(backup) = backup {
        snapshot["backup"] = backup;
    }
    Ok(snapshot)
}

pub(crate) fn save_request(request: &Value) -> CoreResult<Value> {
    let revision = request.get("revision").ok_or_else(|| {
        CoreError::new(
            "invalid_request",
            "revision is required (null for a new file)",
        )
    })?;
    save(
        &absolute(required(request, "path")?)?,
        required(request, "content")?,
        revision,
    )
}

pub(crate) fn backups(path: &Path) -> CoreResult<Value> {
    let directory = backup_directory(path)?;
    let mut backups = Vec::new();
    if directory.exists() {
        for item in fs::read_dir(directory)? {
            let item = item?;
            let name = item.file_name().to_string_lossy().into_owned();
            if !name.ends_with(".toml") || !item.file_type()?.is_file() {
                continue;
            }
            let time: chrono::DateTime<chrono::Utc> = item.metadata()?.modified()?.into();
            backups.push(json!({"id":name,"path":item.path(),"created_at":time.to_rfc3339()}));
        }
    }
    backups.sort_by(|left, right| right["id"].as_str().cmp(&left["id"].as_str()));
    Ok(json!({"backups":backups}))
}

pub(crate) fn restore(request: &Value) -> CoreResult<Value> {
    let path = absolute(required(request, "path")?)?;
    let id = required(request, "backup_id")?;
    if id.is_empty()
        || id.contains(['/', '\\', ':'])
        || id == "."
        || id == ".."
        || !id.ends_with(".toml")
    {
        return Err(CoreError::new(
            "invalid_backup_id",
            "Invalid backup identifier",
        ));
    }
    let backup = backup_directory(&path)?.join(id);
    refuse_link(&backup)?;
    let content = read(&backup)?.ok_or_else(|| CoreError::new("not_found", "Backup not found"))?;
    let revision = request
        .get("revision")
        .ok_or_else(|| CoreError::new("invalid_request", "revision is required"))?;
    save(&path, &content, revision)
}

pub(crate) fn valid_profile(name: &str) -> CoreResult<()> {
    if name.is_empty()
        || name.len() > 128
        || !name
            .bytes()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == b'-' || ch == b'_')
    {
        return Err(CoreError::new(
            "invalid_profile",
            "Profile names must contain 1-128 ASCII letters, numbers, hyphens, or underscores",
        ));
    }
    Ok(())
}

pub(crate) fn profile_list(home: &Path) -> CoreResult<Vec<Value>> {
    let mut result = Vec::new();
    if home.is_dir() {
        for entry in fs::read_dir(home)? {
            let entry = entry?;
            let filename = entry.file_name().to_string_lossy().into_owned();
            if let Some(name) = filename.strip_suffix(".config.toml")
                && valid_profile(name).is_ok()
                && entry.file_type()?.is_file()
            {
                result.push(json!({"name":name,"path":entry.path()}));
            }
        }
    }
    result.sort_by(|left, right| left["name"].as_str().cmp(&right["name"].as_str()));
    Ok(result)
}

pub(crate) fn profiles(request: &Value) -> CoreResult<Value> {
    let home = crate::analysis::codex_home(request)?;
    let action = required(request, "action")?;
    if action == "list" {
        return Ok(json!({"profiles":profile_list(&home)?}));
    }
    let name = required(request, "name")?;
    valid_profile(name)?;
    let source = home.join(format!("{name}.config.toml"));
    match action {
        "create" => save(
            &source,
            request["content"].as_str().unwrap_or(""),
            &Value::Null,
        ),
        "copy" | "rename" => {
            let new_name = required(request, "new_name")?;
            valid_profile(new_name)?;
            let destination = home.join(format!("{new_name}.config.toml"));
            if destination.exists() {
                return Err(CoreError::new(
                    "already_exists",
                    "The destination profile already exists",
                ));
            }
            refuse_link(&source)?;
            let content =
                read(&source)?.ok_or_else(|| CoreError::new("not_found", "Profile not found"))?;
            if action == "copy" {
                return save(&destination, &content, &Value::Null);
            }
            let _lock = lock_directory(&source)?;
            let backup = make_backup(&source, &content)?;
            // Stage a no-clobber destination on the same volume. This also works
            // on filesystems that do not support hard links.
            atomic_create(&destination, content.as_bytes())?;
            if let Err(error) = fs::remove_file(&source) {
                let _ = fs::remove_file(&destination);
                return Err(error.into());
            }
            let mut snapshot = open(&destination)?;
            snapshot["backup"] = backup;
            Ok(snapshot)
        }
        "delete" => {
            refuse_link(&source)?;
            let content =
                read(&source)?.ok_or_else(|| CoreError::new("not_found", "Profile not found"))?;
            let _lock = lock_directory(&source)?;
            if let Some(revision) = request.get("revision") {
                check_revision(&Some(content.clone()), revision)?;
            }
            let backup = make_backup(&source, &content)?;
            check_revision(&read(&source)?, &json!(schema::hash(content.as_bytes())))?;
            fs::remove_file(&source)?;
            Ok(json!({"deleted":true,"path":source,"backup":backup}))
        }
        _ => Err(CoreError::new(
            "invalid_request",
            "profiles action must be list, create, copy, rename, or delete",
        )),
    }
}
