use crate::{Config, Failure};
use reqwest::{blocking::Client, header::HeaderMap};
use serde::{Deserialize, Serialize};
use serde_yaml_ng::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    io::{Read, Write},
    path::Path,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

pub const MAX_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug, Deserialize, Serialize)]
pub struct Provider {
    pub proxies: Vec<Proxy>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct Proxy {
    name: String,
    server: String,
    port: u16,
    #[serde(flatten)]
    protocol: Protocol,
}

// Keep all transport options (Reality, XHTTP, TLS fingerprints, etc.) verbatim.
// Mihomo is the final authority for protocol-specific semantics.
#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum Protocol {
    Vless {
        uuid: String,
        #[serde(flatten)]
        options: BTreeMap<String, Value>,
    },
    Hysteria2 {
        password: String,
        #[serde(flatten)]
        options: BTreeMap<String, Value>,
    },
    Vmess {
        uuid: String,
        #[serde(flatten)]
        options: BTreeMap<String, Value>,
    },
    Trojan {
        password: String,
        #[serde(flatten)]
        options: BTreeMap<String, Value>,
    },
    Ss {
        cipher: String,
        password: String,
        #[serde(flatten)]
        options: BTreeMap<String, Value>,
    },
}

fn has_flag(headers: &HeaderMap, name: &str) -> bool {
    headers
        .get(name)
        .and_then(|h| h.to_str().ok())
        .is_some_and(|v| v.eq_ignore_ascii_case("true") || v == "1")
}

pub fn parse(headers: &HeaderMap, status: u16, body: &[u8]) -> Result<Provider, Failure> {
    // Capybara sends HTTP 200 with a syntactically valid dummy node on rejection.
    if has_flag(headers, "x-hwid-max-devices-reached") {
        return Err(Failure::DeviceLimit);
    }
    if has_flag(headers, "x-hwid-not-supported") {
        return Err(Failure::UnsupportedClient);
    }
    if !(200..300).contains(&status) {
        return Err(Failure::Http(status));
    }
    if body.len() as u64 > MAX_BYTES {
        return Err(Failure::TooLarge);
    }
    let text = std::str::from_utf8(body).map_err(|_| Failure::InvalidProfile)?;
    let lower = text.to_lowercase();
    if lower.contains("приложение не поддерживается")
        || lower.contains("application is not supported")
    {
        return Err(Failure::UnsupportedClient);
    }
    if lower.contains("достигнут лимит устройств") || lower.contains("device limit reached")
    {
        return Err(Failure::DeviceLimit);
    }
    let provider: Provider = serde_yaml_ng::from_str(text).map_err(|_| Failure::InvalidProfile)?;
    if provider.proxies.is_empty() || provider.proxies.len() > 2000 {
        return Err(Failure::InvalidProfile);
    }
    let mut names = HashSet::new();
    for proxy in &provider.proxies {
        let name = proxy.name.trim();
        if name.starts_with('@')
            || name.to_lowercase().contains("подписк")
            || name.to_lowercase().contains("истек")
            || name.to_lowercase().contains("expired")
        {
            return Err(Failure::Placeholder);
        }
        if name.is_empty()
            || name.len() > 512
            || !names.insert(name)
            || proxy.server.trim().is_empty()
            || proxy.port == 0
        {
            return Err(Failure::InvalidProfile);
        }
        let credential = match &proxy.protocol {
            Protocol::Vless { uuid, .. } | Protocol::Vmess { uuid, .. } => uuid,
            Protocol::Hysteria2 { password, .. }
            | Protocol::Trojan { password, .. }
            | Protocol::Ss { password, .. } => password,
        };
        if credential.trim().is_empty() {
            return Err(Failure::InvalidProfile);
        }
    }
    Ok(provider)
}

pub fn client() -> Result<Client, Failure> {
    Client::builder()
        .no_proxy()
        .https_only(true)
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        // Subscription credentials must not be forwarded to a different host.
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 {
                return attempt.error("redirect limit");
            }
            if attempt.url().scheme() != "https"
                || attempt.url().host_str() != Some("sub.capybara.support")
            {
                return attempt.stop();
            }
            attempt.follow()
        }))
        .build()
        .map_err(|_| Failure::Config)
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    hwid: String,
    os: String,
    model: String,
    os_version: Option<String>,
}

fn load_identity(path: &Path) -> Result<Identity, Failure> {
    match fs::read(path) {
        Ok(bytes) => {
            let identity: Identity =
                serde_json::from_slice(&bytes).map_err(|_| Failure::Identity)?;
            if identity.hwid.len() != 16
                || !identity
                    .hwid
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'A'..=b'F').contains(&c))
                || identity.os != "Linux"
            {
                return Err(Failure::Identity);
            }
            return Ok(identity);
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(Failure::Identity),
    }
    let machine_id = fs::read_to_string("/etc/machine-id").map_err(|_| Failure::Config)?;
    if machine_id.trim().len() != 32 {
        return Err(Failure::Identity);
    }
    let digest = format!("{:X}", Sha256::digest(machine_id.trim().as_bytes()));
    let os_release = fs::read_to_string("/etc/os-release").unwrap_or_default();
    let field = |name: &str| {
        os_release.lines().find_map(|line| {
            line.strip_prefix(&format!("{name}="))
                .map(|v| v.trim_matches('"').to_owned())
        })
    };
    let identity = Identity {
        hwid: digest[..16].into(),
        os: "Linux".into(),
        model: field("NAME").unwrap_or_else(|| "Linux".into()),
        os_version: field("VERSION_ID"),
    };
    let bytes = serde_json::to_vec(&identity).map_err(|_| Failure::Identity)?;
    atomic_write(path, &bytes).map_err(|_| Failure::Identity)?;
    Ok(identity)
}

pub fn download(config: &Config, client: &Client) -> Result<(Vec<u8>, usize), Failure> {
    let identity = load_identity(&config.identity_file)?;
    let mut request = client
        .get(config.subscription_url.clone())
        .header("User-Agent", &config.user_agent)
        .header("x-hwid", &identity.hwid)
        .header("x-device-os", &identity.os)
        .header("x-device-model", &identity.model);
    if let Some(version) = identity.os_version {
        request = request.header("x-ver-os", version);
    }
    let response = request.send().map_err(|e| {
        if e.is_timeout() {
            Failure::Timeout
        } else {
            Failure::Network
        }
    })?;
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    // Check refusal headers before parsing or persisting any body.
    if has_flag(&headers, "x-hwid-max-devices-reached") {
        return Err(Failure::DeviceLimit);
    }
    if response.content_length().is_some_and(|n| n > MAX_BYTES) {
        return Err(Failure::TooLarge);
    }
    let mut body = Vec::new();
    response
        .take(MAX_BYTES + 1)
        .read_to_end(&mut body)
        .map_err(|_| Failure::Network)?;
    let parsed = parse(&headers, status, &body)?;
    let count = parsed.proxies.len();
    let normalized = serde_yaml_ng::to_string(&parsed).map_err(|_| Failure::InvalidProfile)?;
    Ok((normalized.into_bytes(), count))
}

pub fn validate(binary: &Path, bytes: &[u8], state_dir: &Path) -> Result<(), Failure> {
    let temp = tempfile::tempdir_in(state_dir).map_err(|_| Failure::Storage)?;
    // Inline the nodes: -t must validate the actual protocols, not just a file-provider reference.
    let mut config = bytes.to_vec();
    config.extend_from_slice(b"\nmode: rule\nrules:\n  - MATCH,DIRECT\n");
    atomic_write(&temp.path().join("config.yaml"), &config)?;
    let mut child = Command::new(binary)
        .args(["-t", "-d"])
        .arg(temp.path())
        .env("SAFE_PATHS", temp.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| Failure::Validation)?;
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                return if status.success() {
                    Ok(())
                } else {
                    Err(Failure::Validation)
                };
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Failure::ValidationTimeout);
            }
        }
    }
}

pub fn atomic_write(path: &Path, data: &[u8]) -> Result<(), Failure> {
    let parent = path.parent().ok_or(Failure::Storage)?;
    let mut file = tempfile::NamedTempFile::new_in(parent).map_err(|_| Failure::Storage)?;
    file.write_all(data).map_err(|_| Failure::Storage)?;
    file.as_file().sync_all().map_err(|_| Failure::Storage)?;
    file.persist(path).map_err(|_| Failure::Storage)?;
    fs::File::open(parent)
        .and_then(|dir| dir.sync_all())
        .map_err(|_| Failure::Storage)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    const VALID: &[u8] = b"mixed-port: 9999\nproxies:\n  - name: Node\n    type: vless\n    server: example.com\n    port: 443\n    uuid: 11111111-1111-4111-8111-111111111111\n    tls: true\n    reality-opts:\n      public-key: test\nrules: [MATCH,DIRECT]\n";

    #[test]
    fn device_identity_is_persistent_and_corruption_never_rotates_it() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("device.json");
        let first = load_identity(&path).unwrap();
        assert_eq!(first.hwid, load_identity(&path).unwrap().hwid);
        // Persisted identity takes precedence over recomputing from this host.
        let pinned = Identity {
            hwid: "1234567890ABCDEF".into(),
            ..first
        };
        fs::write(&path, serde_json::to_vec(&pinned).unwrap()).unwrap();
        assert_eq!(load_identity(&path).unwrap().hwid, "1234567890ABCDEF");
        fs::write(&path, "corrupted").unwrap();
        assert!(matches!(load_identity(&path), Err(Failure::Identity)));
        assert_eq!(fs::read_to_string(path).unwrap(), "corrupted");
    }

    #[test]
    fn http_200_device_limit_is_failure() {
        let mut headers = HeaderMap::new();
        headers.insert("x-hwid-max-devices-reached", "true".parse().unwrap());
        assert!(matches!(
            parse(&headers, 200, VALID),
            Err(Failure::DeviceLimit)
        ));
    }
    #[test]
    fn html_empty_placeholder_and_http_error_are_not_profiles() {
        for body in [
            b"<html>login</html>".as_slice(),
            b"proxies: []",
            b"proxies: [{}]",
        ] {
            assert!(parse(&HeaderMap::new(), 200, body).is_err());
        }
        assert!(matches!(
            parse(&HeaderMap::new(), 502, VALID),
            Err(Failure::Http(502))
        ));
        let placeholder =
            String::from_utf8_lossy(VALID).replace("name: Node", "name: '@capybaravpnbot'");
        assert!(matches!(
            parse(&HeaderMap::new(), 200, placeholder.as_bytes()),
            Err(Failure::Placeholder)
        ));
    }
    #[test]
    fn strip_remote_routing_but_preserve_transport_options() {
        let provider = parse(&HeaderMap::new(), 200, VALID).unwrap();
        let text = serde_yaml_ng::to_string(&provider).unwrap();
        assert!(!text.contains("mixed-port"));
        assert!(!text.contains("rules:"));
        assert!(text.contains("reality-opts:"));
        assert!(text.contains("public-key: test"));
    }
    #[test]
    fn reject_duplicates_and_unknown_protocol() {
        let mut p = parse(&HeaderMap::new(), 200, VALID).unwrap();
        let second = parse(&HeaderMap::new(), 200, VALID).unwrap();
        p.proxies.extend(second.proxies);
        assert!(
            parse(
                &HeaderMap::new(),
                200,
                serde_yaml_ng::to_string(&p).unwrap().as_bytes()
            )
            .is_err()
        );
        let unsupported =
            String::from_utf8_lossy(VALID).replace("type: vless", "type: new-protocol");
        assert!(parse(&HeaderMap::new(), 200, unsupported.as_bytes()).is_err());
    }
}
