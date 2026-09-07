use crate::{Config, Failure, error_reply, provider};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::Read,
    os::unix::fs::PermissionsExt,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum Phase {
    #[default]
    Idle,
    Updating,
    Success,
    Error,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct Status {
    phase: Phase,
    attempted_at: Option<u64>,
    finished_at: Option<u64>,
    last_success_at: Option<u64>,
    node_count: Option<usize>,
    code: Option<String>,
    error: Option<String>,
}

struct App {
    config: Config,
    upstream: reqwest::blocking::Client,
    status: Mutex<Status>,
    updating: Mutex<()>,
    refreshing: Mutex<()>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

impl App {
    fn state(&self) -> Result<Status, Failure> {
        self.status
            .lock()
            .map(|s| s.clone())
            .map_err(|_| Failure::Storage)
    }

    fn save(&self, status: Status) -> Result<(), Failure> {
        let mut state = self.status.lock().map_err(|_| Failure::Storage)?;
        // Set memory first so a disk failure remains visible through /status.
        *state = status;
        let bytes = serde_json::to_vec(&*state).map_err(|_| Failure::Storage)?;
        provider::atomic_write(&self.config.state_dir.join("status.json"), &bytes)
    }

    fn record_failure(&self, failure: &Failure) {
        if let Ok(mut state) = self.state() {
            state.phase = Phase::Error;
            state.finished_at = Some(now());
            state.code = Some(failure.code().into());
            state.error = Some(failure.to_string());
            let _ = self.save(state);
        }
        eprintln!("{}: {}", failure.code(), failure);
    }

    fn update(&self) -> Result<Vec<u8>, Failure> {
        let _guard = self.updating.try_lock().map_err(|_| Failure::Busy)?;
        let mut state = self.state()?;
        state.phase = Phase::Updating;
        state.attempted_at = Some(now());
        // Keep the last error during retries; clear only after successful validation.
        if let Err(error) = self.save(state.clone()) {
            self.record_failure(&error);
            return Err(error);
        }
        let result = (|| {
            let (bytes, count) = provider::download(&self.config, &self.upstream)?;
            provider::validate(&self.config.mihomo_binary, &bytes, &self.config.state_dir)?;
            let cache = self.config.state_dir.join("provider.yaml");
            if cache.exists() {
                let previous = fs::read(&cache).map_err(|_| Failure::Storage)?;
                provider::atomic_write(
                    &self.config.state_dir.join("provider.previous.yaml"),
                    &previous,
                )?;
            }
            provider::atomic_write(&cache, &bytes)?;
            state.phase = Phase::Success;
            state.finished_at = Some(now());
            state.last_success_at = state.finished_at;
            state.node_count = Some(count);
            state.code = None;
            state.error = None;
            self.save(state)?;
            Ok(bytes)
        })();
        if let Err(ref error) = result {
            self.record_failure(error);
        }
        result
    }

    fn refresh(&self) -> Result<(), Failure> {
        // Leave workers available for Mihomo's callback even if buttons are clicked repeatedly.
        let _guard = self.refreshing.try_lock().map_err(|_| Failure::Busy)?;
        let client = reqwest::blocking::Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(2))
            .timeout(Duration::from_secs(55))
            .build()
            .map_err(|_| Failure::Config)?;
        let endpoint = self
            .config
            .controller
            .join("providers/proxies/capybara")
            .map_err(|_| Failure::Config)?;
        // Let Mihomo fetch and install through its normal provider update API.
        // No update lock is held here: its GET /provider runs on another worker.
        let is_http_provider = client
            .get(endpoint.clone())
            .timeout(Duration::from_secs(2))
            .send()
            .ok()
            .and_then(|r| r.json::<serde_json::Value>().ok())
            .is_some_and(|v| v.get("vehicleType").and_then(|v| v.as_str()) == Some("HTTP"));
        if is_http_provider {
            if client
                .put(endpoint)
                .send()
                .is_ok_and(|r| r.status().is_success())
            {
                return Ok(());
            }
            if self.state()?.phase != Phase::Error {
                self.record_failure(&Failure::Apply);
            }
            return Err(Failure::Apply);
        }
        // Works before integration and while the system VPN is switched off.
        self.update().map(|_| ())
    }

    fn respond_json(&self, request: Request, status: u16, value: &impl Serialize) {
        let body = serde_json::to_vec(value).unwrap_or_else(|_| b"{\"ok\":false}".to_vec());
        let mut response = Response::from_data(body).with_status_code(StatusCode(status));
        if let Ok(header) = Header::from_bytes("Content-Type", "application/json; charset=utf-8") {
            response.add_header(header);
        }
        if let Ok(header) = Header::from_bytes("Cache-Control", "no-store") {
            response.add_header(header);
        }
        let _ = request.respond(response);
    }

    fn handle(&self, request: Request) {
        let header = |key: &'static str| {
            request
                .headers()
                .iter()
                .find(|h| h.field.equiv(key))
                .map(|h| h.value.as_str())
        };
        // Local API only; block browser cross-origin requests and DNS rebinding.
        let expected_host = self.config.listen.to_string();
        if header("Host") != Some(expected_host.as_str())
            || header("Origin").is_some()
            || header("Sec-Fetch-Site").is_some_and(|v| v != "none" && v != "same-origin")
        {
            self.respond_json(request, 403, &error_reply(&Failure::Config));
            return;
        }
        match (request.method(), request.url()) {
            (&Method::Get, "/status") => match self.state() {
                Ok(state) => self.respond_json(request, 200, &state),
                Err(e) => self.respond_json(request, 500, &error_reply(&e)),
            },
            (&Method::Get, "/provider/capybara") => match self.update() {
                Ok(bytes) => {
                    let mut response = Response::from_data(bytes);
                    if let Ok(h) = Header::from_bytes("Content-Type", "text/yaml; charset=utf-8") {
                        response.add_header(h);
                    }
                    if let Ok(h) = Header::from_bytes("Cache-Control", "no-store") {
                        response.add_header(h);
                    }
                    let _ = request.respond(response);
                }
                Err(e) => self.respond_json(
                    request,
                    if matches!(e, Failure::Busy) { 409 } else { 502 },
                    &error_reply(&e),
                ),
            },
            (&Method::Post, "/refresh") if header("X-Capybara-Action") == Some("refresh") => {
                let result = self.refresh();
                match self.state() {
                    Ok(state) => {
                        self.respond_json(request, if result.is_ok() { 200 } else { 502 }, &state)
                    }
                    Err(e) => self.respond_json(request, 500, &error_reply(&e)),
                }
            }
            _ => self.respond_json(request, 404, &error_reply(&Failure::Config)),
        }
    }
}

pub fn serve(config: Config) -> Result<(), Failure> {
    fs::create_dir_all(&config.state_dir).map_err(|_| Failure::Storage)?;
    fs::set_permissions(&config.state_dir, fs::Permissions::from_mode(0o700))
        .map_err(|_| Failure::Storage)?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(config.state_dir.join("service.lock"))
        .map_err(|_| Failure::Storage)?;
    lock.try_lock().map_err(|_| Failure::Busy)?;
    let mut state: Status = match fs::File::open(config.state_dir.join("status.json")) {
        Ok(mut file) => {
            let mut data = String::new();
            file.read_to_string(&mut data)
                .map_err(|_| Failure::Storage)?;
            serde_json::from_str(&data).map_err(|_| Failure::Storage)?
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Status::default(),
        Err(_) => return Err(Failure::Storage),
    };
    if state.phase == Phase::Updating {
        state.phase = Phase::Error;
        state.code = Some("interrupted".into());
        state.error = Some("Предыдущее обновление прервано. Повторите обновление подписки.".into());
    }
    let server = Server::http(config.listen).map_err(|_| Failure::Unavailable)?;
    let app = Arc::new(App {
        upstream: provider::client()?,
        config,
        status: Mutex::new(state),
        updating: Mutex::new(()),
        refreshing: Mutex::new(()),
    });
    app.save(app.state()?)?;
    // Fixed workers bound local request concurrency; slow downloads do not block status.
    let server = Arc::new(server);
    thread::scope(|scope| {
        for _ in 0..4 {
            let app = Arc::clone(&app);
            let server = Arc::clone(&server);
            scope.spawn(move || {
                for request in server.incoming_requests() {
                    app.handle(request);
                }
            });
        }
    });
    Ok(())
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    #[test]
    fn failed_refresh_keeps_cache_and_persists_error_after_restart() {
        let temp = tempfile::tempdir().unwrap();
        let cache = temp.path().join("provider.yaml");
        fs::write(&cache, "last known good").unwrap();
        // A real local HTTP refusal exercises download -> status without any upstream access.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let worker = thread::spawn(move || {
            let mut identities = Vec::new();
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") {
                    let mut buffer = [0; 4096];
                    let count = stream.read(&mut buffer).unwrap();
                    assert!(count > 0);
                    request.extend_from_slice(&buffer[..count]);
                }
                let request = String::from_utf8(request).unwrap();
                identities.push(
                    request
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("x-hwid")
                                .then(|| value.trim().to_owned())
                        })
                        .unwrap(),
                );
                stream.write_all(b"HTTP/1.1 200 OK\r\nx-hwid-max-devices-reached: true\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
            }
            identities
        });
        let config = Config {
            subscription_url: format!("http://{address}/secret-token").parse().unwrap(),
            user_agent: "test".into(),
            listen: "127.0.0.1:0".parse().unwrap(),
            state_dir: temp.path().into(),
            identity_file: temp.path().join("device.json"),
            mihomo_binary: "/usr/bin/false".into(),
            controller: "http://127.0.0.1:1".parse().unwrap(),
            provider: "capybara".into(),
        };
        let app = App {
            config,
            upstream: reqwest::blocking::Client::builder()
                .no_proxy()
                .build()
                .unwrap(),
            status: Mutex::new(Status {
                last_success_at: Some(123),
                ..Status::default()
            }),
            updating: Mutex::new(()),
            refreshing: Mutex::new(()),
        };
        assert!(matches!(app.update(), Err(Failure::DeviceLimit)));
        let original_identity = fs::read(&app.config.identity_file).unwrap();
        let persisted = fs::read_to_string(temp.path().join("status.json")).unwrap();
        assert!(!persisted.contains("secret-token"));
        let state: Status = serde_json::from_str(&persisted).unwrap();
        assert_eq!(state.phase, Phase::Error);
        assert_eq!(state.last_success_at, Some(123));
        assert_eq!(state.code.as_deref(), Some("device_limit"));
        let restarted = App {
            status: Mutex::new(state),
            ..app
        };
        assert!(matches!(restarted.update(), Err(Failure::DeviceLimit)));
        let identities = worker.join().unwrap();
        assert_eq!(identities[0].len(), 16);
        assert_eq!(identities[0], identities[1]);
        assert_eq!(
            fs::read(&restarted.config.identity_file).unwrap(),
            original_identity
        );
        assert_eq!(fs::read_to_string(cache).unwrap(), "last known good");
    }
}
