//! Restricted local administrative helper. No user-supplied paths or commands.
//! The installed, root-owned binary is the only executable allowed by Polkit.
use clap::{Parser, ValueEnum};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use serde_yaml_ng::Value;
use std::{
    fs,
    io::Write,
    path::Path,
    process::{Command, ExitCode, Stdio},
    thread,
    time::{Duration, Instant},
};

const DIRECTORY: &str = "/etc/mihomo";
const API: &str = "http://127.0.0.1:9090/configs";

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Action {
    On,
    Off,
    Ensure,
    Restart,
}

#[derive(Parser)]
struct Args {
    #[arg(value_enum)]
    action: Action,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Mode {
    Direct,
    Rule,
    Global,
}

impl Mode {
    fn text(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Rule => "rule",
            Self::Global => "global",
        }
    }
    fn parse(text: &str) -> Result<Self, Failure> {
        match text.to_ascii_lowercase().as_str() {
            "direct" => Ok(Self::Direct),
            "rule" => Ok(Self::Rule),
            "global" => Ok(Self::Global),
            _ => Err(Failure::Config),
        }
    }
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct State {
    last_enabled: Mode,
}
impl Default for State {
    fn default() -> Self {
        Self {
            last_enabled: Mode::Rule,
        }
    }
}

#[derive(Debug, thiserror::Error)]
enum Failure {
    #[error("Не удалось сохранить режим VPN. Системные настройки не подтверждены.")]
    Storage,
    #[error("Некорректные настройки Mihomo или сохранённого режима VPN.")]
    Config,
    #[error("Режим VPN уже переключается. Повторите попытку.")]
    Busy,
    #[error("Mihomo отклонил настройки. Предыдущий режим сохранён.")]
    Validation,
    #[error("Не удалось запустить Mihomo. Проверьте журнал mihomo.service.")]
    Service,
    #[error("Режим сохранён, но Mihomo его пока не подтвердил. Нажмите перезапуск.")]
    Apply,
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), Failure> {
    let parent = path.parent().ok_or(Failure::Storage)?;
    let mut pending = tempfile::NamedTempFile::new_in(parent).map_err(|_| Failure::Storage)?;
    pending.write_all(bytes).map_err(|_| Failure::Storage)?;
    pending.as_file().sync_all().map_err(|_| Failure::Storage)?;
    pending.persist(path).map_err(|_| Failure::Storage)?;
    fs::File::open(parent)
        .and_then(|f| f.sync_all())
        .map_err(|_| Failure::Storage)
}

fn configured_mode(document: &Value) -> Result<Mode, Failure> {
    match document.get("mode") {
        None => Ok(Mode::Rule),
        Some(value) => Mode::parse(value.as_str().ok_or(Failure::Config)?),
    }
}

fn read_state(directory: &Path) -> Result<State, Failure> {
    let state: State = match fs::read(directory.join("widget-state.json")) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(|_| Failure::Config)?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => State::default(),
        Err(_) => return Err(Failure::Storage),
    };
    if state.last_enabled == Mode::Direct {
        return Err(Failure::Config);
    }
    Ok(state)
}

fn target(action: Action, current: Mode, state: &mut State) -> Mode {
    match action {
        Action::Off => {
            if current != Mode::Direct {
                state.last_enabled = current;
            }
            Mode::Direct
        }
        Action::On if current == Mode::Direct => state.last_enabled,
        _ => current,
    }
}

fn run_bounded(mut command: Command, seconds: u64) -> Result<bool, Failure> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| Failure::Service)?;
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status.success()),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Failure::Service);
            }
        }
    }
}

fn systemctl(action: &str) -> Result<bool, Failure> {
    let mut command = Command::new("/usr/bin/systemctl");
    command.args([action, "mihomo.service"]);
    run_bounded(command, 15)
}

fn validate(directory: &Path, candidate: &str) -> Result<(), Failure> {
    let mut pending = tempfile::NamedTempFile::new_in(directory).map_err(|_| Failure::Storage)?;
    pending
        .write_all(candidate.as_bytes())
        .map_err(|_| Failure::Storage)?;
    let mut command = Command::new("/usr/bin/mihomo");
    command
        .arg("-t")
        .arg("-d")
        .arg(directory)
        .arg("-f")
        .arg(pending.path())
        .env("SAFE_PATHS", "/usr/share/metacubexd");
    if run_bounded(command, 10).map_err(|_| Failure::Validation)? {
        Ok(())
    } else {
        Err(Failure::Validation)
    }
}

fn persist(
    directory: &Path,
    original: &[u8],
    document: &mut Value,
    mode: Mode,
    state: State,
    check: impl FnOnce(&str) -> Result<(), Failure>,
) -> Result<(), Failure> {
    let mapping = document.as_mapping_mut().ok_or(Failure::Config)?;
    mapping.insert("mode".into(), mode.text().into());
    let candidate = serde_yaml_ng::to_string(document).map_err(|_| Failure::Config)?;
    check(&candidate)?;
    let backup = directory.join("config.yaml.before-widget-control");
    if !backup.exists() {
        write_atomic(&backup, original)?;
    }
    // Remember the enabled mode first; config.yaml remains the authority for ON/OFF.
    write_atomic(
        &directory.join("widget-state.json"),
        &serde_json::to_vec(&state).map_err(|_| Failure::Storage)?,
    )?;
    write_atomic(&directory.join("config.yaml"), candidate.as_bytes())
}

fn live_mode(client: &Client) -> Option<Mode> {
    let response = client.get(API).send().ok()?.error_for_status().ok()?;
    let data: serde_json::Value = response.json().ok()?;
    Mode::parse(data.get("mode")?.as_str()?).ok()
}

fn run(action: Action) -> Result<Mode, Failure> {
    let directory = Path::new(DIRECTORY);
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(directory.join("widget-control.lock"))
        .map_err(|_| Failure::Storage)?;
    lock.try_lock().map_err(|_| Failure::Busy)?;
    let original = fs::read(directory.join("config.yaml")).map_err(|_| Failure::Storage)?;
    let mut document: Value = serde_yaml_ng::from_slice(&original).map_err(|_| Failure::Config)?;
    let saved_mode = configured_mode(&document)?;
    let mut state = read_state(directory)?;
    let client = Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| Failure::Apply)?;
    let live = live_mode(&client);
    // Explicit toggles may adopt a mode selected in the local dashboard. A plain
    // recovery/start NEVER overwrites the stored intent with a transient API value.
    let current = if matches!(action, Action::On | Action::Off) {
        live.unwrap_or(saved_mode)
    } else {
        saved_mode
    };
    let desired = target(action, current, &mut state);
    if matches!(action, Action::On | Action::Off) {
        persist(
            directory,
            &original,
            &mut document,
            desired,
            state,
            |candidate| validate(directory, candidate),
        )?;
    }
    if matches!(action, Action::Restart) {
        if !systemctl("restart")? {
            return Err(Failure::Service);
        }
    } else if live != Some(desired) {
        let applied = live.is_some()
            && client
                .patch(API)
                .json(&serde_json::json!({"mode":desired}))
                .send()
                .is_ok_and(|r| r.status().is_success());
        if !applied {
            let operation = if systemctl("is-active")? {
                "restart"
            } else {
                "start"
            };
            if !systemctl(operation)? {
                return Err(Failure::Service);
            }
        }
    }
    let deadline = Instant::now() + Duration::from_secs(6);
    loop {
        if live_mode(&client) == Some(desired) {
            return Ok(desired);
        }
        if Instant::now() >= deadline {
            return Err(Failure::Apply);
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn main() -> ExitCode {
    match run(Args::parse().action) {
        Ok(mode) => {
            println!(
                "{}",
                serde_json::json!({"ok":true,"available":true,"active":mode != Mode::Direct,"mode":mode})
            );
            ExitCode::SUCCESS
        }
        Err(error) => {
            // Never include config content, credentials, subprocess output or paths supplied by a caller.
            println!(
                "{}",
                serde_json::json!({"ok":false,"error":error.to_string()})
            );
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    const CONFIG: &[u8] = b"mode: global\ntun: {enable: true}\nexternal-controller: '127.0.0.1:9090'\nproxy-providers: {capybara: {type: http, url: 'http://127.0.0.1:9095/provider/capybara'}}\nrules: ['MATCH,VPN']\n";

    #[test]
    fn off_and_on_survive_reload_without_changing_routes() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("config.yaml"), CONFIG).unwrap();
        let mut state = State::default();
        let mut document: Value = serde_yaml_ng::from_slice(CONFIG).unwrap();
        for action in [Action::Off, Action::Off, Action::On] {
            let old = fs::read(directory.path().join("config.yaml")).unwrap();
            document = serde_yaml_ng::from_slice(&old).unwrap();
            let mode = target(action, configured_mode(&document).unwrap(), &mut state);
            persist(directory.path(), &old, &mut document, mode, state, |_| {
                Ok(())
            })
            .unwrap();
            // Emulate process exit and a new service reading only disk state.
            state = read_state(directory.path()).unwrap();
            let reloaded: Value =
                serde_yaml_ng::from_slice(&fs::read(directory.path().join("config.yaml")).unwrap())
                    .unwrap();
            assert_eq!(configured_mode(&reloaded).unwrap(), mode);
            assert_eq!(target(Action::Restart, mode, &mut state), mode);
            assert_eq!(target(Action::Ensure, mode, &mut state), mode);
            assert_eq!(state.last_enabled, Mode::Global);
        }
        let original: Value = serde_yaml_ng::from_slice(CONFIG).unwrap();
        assert_eq!(document, original);
        assert_eq!(
            fs::read(directory.path().join("config.yaml.before-widget-control")).unwrap(),
            CONFIG
        );
    }

    #[test]
    fn rejected_candidate_never_changes_mode_or_state() {
        let directory = tempfile::tempdir().unwrap();
        fs::write(directory.path().join("config.yaml"), CONFIG).unwrap();
        let mut document: Value = serde_yaml_ng::from_slice(CONFIG).unwrap();
        assert!(
            persist(
                directory.path(),
                CONFIG,
                &mut document,
                Mode::Direct,
                State::default(),
                |_| Err(Failure::Validation)
            )
            .is_err()
        );
        assert_eq!(
            fs::read(directory.path().join("config.yaml")).unwrap(),
            CONFIG
        );
        assert!(!directory.path().join("widget-state.json").exists());
    }

    #[test]
    fn helper_has_no_arbitrary_commands_or_paths() {
        assert!(Args::try_parse_from(["helper", "ensure"]).is_ok());
        assert!(Args::try_parse_from(["helper", "off", "/tmp/config.yaml"]).is_err());
        assert!(Args::try_parse_from(["helper", "serve"]).is_err());
        assert!(Args::try_parse_from(["helper", "--config", "/tmp/config.yaml", "on"]).is_err());
        assert!(Mode::parse("invalid").is_err());
    }
}
