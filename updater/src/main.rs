mod integrate;
mod provider;
mod service;

use clap::{Parser, Subcommand};
use serde::{Deserialize, Serialize};
use std::{fs, net::SocketAddr, path::PathBuf, process::ExitCode, time::Duration};
use url::Url;

#[derive(Parser)]
#[command(version, about = "Validated Capybara subscription provider for Mihomo")]
struct Args {
    #[arg(long)]
    config: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Serve,
    Refresh,
    Status,
    /// Configure /etc/mihomo to use the local provider. Requires administrator privileges.
    Integrate,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    subscription_url: Url,
    user_agent: String,
    listen: SocketAddr,
    state_dir: PathBuf,
    identity_file: PathBuf,
    mihomo_binary: PathBuf,
    controller: Url,
    provider: String,
}

#[derive(Debug, thiserror::Error)]
pub enum Failure {
    #[error(
        "Достигнут лимит устройств Capybara. Удалите неиспользуемое устройство в кабинете или боте и повторите обновление."
    )]
    DeviceLimit,
    #[error(
        "Не удалось прочитать сохранённый идентификатор устройства. Восстановите device.json из резервной копии; новый HWID автоматически не создаётся."
    )]
    Identity,
    #[error("Capybara не поддерживает идентификацию этого клиента.")]
    UnsupportedClient,
    #[error("Сервер подписки вернул HTTP {0}. Повторите обновление позже.")]
    Http(u16),
    #[error("Не удалось подключиться к серверу подписки: ошибка сети или TLS.")]
    Network,
    #[error("Сервер подписки не ответил за отведённое время.")]
    Timeout,
    #[error("Подписка вернула пустой, неподдерживаемый или некорректный список серверов.")]
    InvalidProfile,
    #[error("Capybara вернула служебную заглушку вместо VPN-серверов.")]
    Placeholder,
    #[error("Размер подписки превышает допустимые 8 МиБ.")]
    TooLarge,
    #[error("Mihomo отклонил загруженный профиль. Сохранённый профиль не изменён.")]
    Validation,
    #[error("Проверка профиля в Mihomo превысила 15 секунд.")]
    ValidationTimeout,
    #[error("Не удалось сохранить профиль или статус обновления на диске.")]
    Storage,
    #[error("Некорректные настройки обновлятора.")]
    Config,
    #[error("Обновление подписки уже выполняется.")]
    Busy,
    #[error("Не удалось загрузить обновлённый провайдер в Mihomo. Повторите обновление.")]
    Apply,
    #[error("Обновлятор недоступен. Проверьте службу capybara-updater.")]
    Unavailable,
}

impl Failure {
    fn code(&self) -> &'static str {
        match self {
            Self::DeviceLimit => "device_limit",
            Self::Identity => "identity_error",
            Self::UnsupportedClient => "unsupported_client",
            Self::Http(_) => "http_error",
            Self::Network => "network_error",
            Self::Timeout => "timeout",
            Self::InvalidProfile => "invalid_profile",
            Self::Placeholder => "placeholder",
            Self::TooLarge => "too_large",
            Self::Validation => "validation_failed",
            Self::ValidationTimeout => "validation_timeout",
            Self::Storage => "storage_error",
            Self::Config => "config_error",
            Self::Busy => "busy",
            Self::Apply => "apply_failed",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Serialize)]
struct ErrorReply {
    ok: bool,
    code: &'static str,
    error: String,
}

fn error_reply(error: &Failure) -> ErrorReply {
    ErrorReply {
        ok: false,
        code: error.code(),
        error: error.to_string(),
    }
}

fn read_config(path: Option<PathBuf>) -> Result<Config, Failure> {
    let path = path
        .or_else(|| {
            std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .or_else(|| std::env::var_os("HOME").map(|s| PathBuf::from(s).join(".config")))
                .map(|p| p.join("capybara-updater/config.json"))
        })
        .ok_or(Failure::Config)?;
    let config: Config = serde_json::from_slice(&fs::read(path).map_err(|_| Failure::Config)?)
        .map_err(|_| Failure::Config)?;
    if config.subscription_url.scheme() != "https"
        || config.subscription_url.host_str() != Some("sub.capybara.support")
        || !config.subscription_url.username().is_empty()
        || config.subscription_url.password().is_some()
        || !config.listen.ip().is_loopback()
        || config.controller.scheme() != "http"
        || config.controller.host_str() != Some("127.0.0.1")
        || !config.state_dir.is_absolute()
        || !config.identity_file.is_absolute()
        || !config.mihomo_binary.is_absolute()
        || config.provider != "capybara"
    {
        return Err(Failure::Config);
    }
    Ok(config)
}

fn run(args: Args) -> Result<bool, Failure> {
    let config = read_config(args.config)?;
    if matches!(args.command, Command::Integrate) {
        integrate::install(&config)?;
        return Ok(true);
    }
    if matches!(args.command, Command::Serve) {
        service::serve(config)?;
        return Ok(true);
    }
    let client = reqwest::blocking::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(65))
        .build()
        .map_err(|_| Failure::Unavailable)?;
    let endpoint = format!(
        "http://{}/{}",
        config.listen,
        if matches!(args.command, Command::Refresh) {
            "refresh"
        } else {
            "status"
        }
    );
    let request = if matches!(args.command, Command::Refresh) {
        client.post(endpoint).header("X-Capybara-Action", "refresh")
    } else {
        client.get(endpoint)
    };
    let response = request.send().map_err(|_| Failure::Unavailable)?;
    let ok = response.status().is_success();
    let value: serde_json::Value = response.json().map_err(|_| Failure::Unavailable)?;
    println!("{value}");
    Ok(ok)
}

fn main() -> ExitCode {
    match run(Args::parse()) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(error) => {
            // Never print reqwest/YAML diagnostics: they may contain subscription tokens.
            if let Ok(json) = serde_json::to_string(&error_reply(&error)) {
                println!("{json}");
            }
            ExitCode::FAILURE
        }
    }
}
