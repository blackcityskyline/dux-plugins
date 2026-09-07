use crate::{Config, Failure, provider};
use serde_yaml_ng::{Mapping, Value};
use std::{
    fs,
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

// Explicit admin-only installation; normal refresh/serve never writes to /etc.
pub fn install(config: &Config) -> Result<(), Failure> {
    let directory = Path::new("/etc/mihomo");
    let path = directory.join("config.yaml");
    let original = fs::read(&path).map_err(|_| Failure::Storage)?;
    // Seed Mihomo with the freshly validated cache. Copying the old profile with
    // a new mtime could otherwise postpone its first HTTP refresh for an hour.
    let fresh = fs::read(config.state_dir.join("provider.yaml")).map_err(|_| Failure::Storage)?;
    let parsed = provider::parse(&reqwest::header::HeaderMap::new(), 200, &fresh)?;
    let fresh = serde_yaml_ng::to_string(&parsed).map_err(|_| Failure::InvalidProfile)?;
    provider::validate(&config.mihomo_binary, fresh.as_bytes(), directory)?;
    let mut document: Value = serde_yaml_ng::from_slice(&original).map_err(|_| Failure::Config)?;
    let providers = document
        .get_mut("proxy-providers")
        .and_then(Value::as_mapping_mut)
        .ok_or(Failure::Config)?;
    let capybara = providers
        .get_mut(Value::String("capybara".into()))
        .and_then(Value::as_mapping_mut)
        .ok_or(Failure::Config)?;
    let old_type = capybara
        .get("type")
        .and_then(Value::as_str)
        .ok_or(Failure::Config)?;
    if old_type != "file" && old_type != "http" {
        return Err(Failure::Config);
    }
    let old_relative = capybara
        .get("path")
        .and_then(Value::as_str)
        .ok_or(Failure::Config)?
        .to_owned();
    if Path::new(&old_relative).is_absolute()
        || Path::new(&old_relative)
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(Failure::Config);
    }
    let set = |map: &mut Mapping, key: &str, value: Value| {
        map.insert(Value::String(key.into()), value);
    };
    set(capybara, "type", "http".into());
    set(
        capybara,
        "url",
        format!("http://{}/provider/capybara", config.listen).into(),
    );
    set(capybara, "proxy", "DIRECT".into());
    set(capybara, "path", "./providers/capybara.yaml".into());
    set(capybara, "interval", 3600.into());
    set(capybara, "size-limit", provider::MAX_BYTES.into());
    capybara.remove("header");
    let candidate = serde_yaml_ng::to_string(&document).map_err(|_| Failure::Config)?;
    let mut pending = tempfile::NamedTempFile::new_in(directory).map_err(|_| Failure::Storage)?;
    use std::io::Write;
    pending
        .write_all(candidate.as_bytes())
        .map_err(|_| Failure::Storage)?;
    let mut child = Command::new(&config.mihomo_binary)
        .args(["-t", "-d"])
        .arg(directory)
        .arg("-f")
        .arg(pending.path())
        .env("SAFE_PATHS", "/usr/share/metacubexd")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| Failure::Validation)?;
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) => return Err(Failure::Validation),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Failure::ValidationTimeout);
            }
        }
    }
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let backup = directory.join(format!("config.yaml.before-capybara-updater-{stamp}"));
    provider::atomic_write(&backup, &original)?;
    let target = directory.join("providers/capybara.yaml");
    if target.exists() {
        let previous = fs::read(&target).map_err(|_| Failure::Storage)?;
        provider::atomic_write(
            &directory.join(format!("providers/capybara.yaml.before-updater-{stamp}")),
            &previous,
        )?;
    }
    provider::atomic_write(&target, fresh.as_bytes())?;
    provider::atomic_write(&path, candidate.as_bytes())?;
    println!(
        "{}",
        serde_json::json!({"ok":true, "backup":backup, "restart_required":true})
    );
    Ok(())
}
