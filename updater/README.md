# Capybara updater

Rust CLI and loopback-only HTTP adapter for the system Mihomo provider.
The DMS widget and MetaCubeXD update providers through Mihomo's standard API.
When this adapter is configured as an HTTP provider, Mihomo fetches its
`GET /provider/capybara` endpoint, which downloads and validates fresh nodes.
The widget has no direct dependency on this service. The standalone CLI and
`POST /refresh` remain available; they can store nodes for later use while
the Mihomo service is stopped.

## Device identity

The first request derives the Linux FlClashX HWID from the trimmed machine-id:
SHA-256, first 16 hexadecimal characters, uppercase. It persists this value and
device metadata in `~/.config/capybara-updater/device.json` (mode 0600).
All subsequent requests and redirects reuse the stored identity, including
after restarts and software updates. No random ID, per-request ID, retries
with alternate IDs, or HWID rotation on provider refusal are used.
Back up this file along with config.json when migrating/reinstalling the OS.
A malformed/unreadable identity is an error, never a reason to regenerate it.
The provider controls its own device accounting; the updater cannot release
existing device slots or bypass their limit.

## Failure behavior

`status.json` records the latest attempt, persistent error code/message, and
last successful update. Errors survive process and desktop restarts and remain
recorded on disk. DMS reports failures of updates requested through its button
using the HTTP result from Mihomo; it does not poll this adapter's status. Status can
be read even while a download is running or Mihomo is off.

HTTP 200 is insufficient: refusal headers, including
`x-hwid-max-devices-reached`, dummy nodes, empty/invalid YAML, duplicate names,
unknown protocols, oversized responses and non-2xx statuses all fail. Proxy
envelopes/protocols are typed with Serde; transport-specific fields are
preserved and validated by `mihomo -t` with nodes inline (not an unloaded
file-provider reference). Remote routing and other top-level settings are not
imported. Only a successful validation atomically replaces the private cache;
the previous file is retained. The adapter returns HTTP 502 on upstream or
validation failure, so Mihomo retains its own provider cache and its dashboard
reports a failed update. It never serves a cached copy as a successful refresh.
Dashboard error detail depends on its UI. DMS notifications show the provider
name and a safe HTTP/connection error; detailed reasons remain in this adapter's
status, without adding status cards or error tooltip overlays to DMS.
Tokens, UUIDs, raw response bodies and request URLs are
excluded from status, logs and errors. TLS verification stays enabled.

## Installation

1. `cargo build --release --locked` in this directory.
2. Install `target/release/capybara-updater` to `~/.local/bin/`.
3. Copy config.example.json to `~/.config/capybara-updater/config.json`, fill
   paths and subscription URL, set directory 0700 and file 0600.
4. Install the supplied `capybara-updater.service` in `~/.config/systemd/user/`,
   run `systemctl --user daemon-reload`, then
   `systemctl --user enable --now capybara-updater.service`.
   It listens only on 127.0.0.1:9095 and runs as the user.
5. `capybara-updater refresh` downloads and checks once; it returns a nonzero
   exit code and JSON on failure. `capybara-updater status` reads status.
6. As administrator, run the binary with `--config /absolute/config.json
   integrate`. It backs up `/etc/mihomo/config.yaml`, validates a candidate,
   and replaces only Capybara's provider settings. It validates the updater's
   current cache again and installs it as Mihomo's initial cache; a preexisting
   target cache is backed up. All other YAML settings are preserved (comments
   are in the backup). It never
   starts, enables or restarts Mihomo automatically.
7. Reload/start Mihomo once a valid subscription is available. The provider URL
   is `http://127.0.0.1:9095/provider/capybara`, `proxy: DIRECT`, interval 3600.
   A user service starts at login; before login Mihomo can use its own cache.

`GET /status` is read-only. `POST /refresh` requires `X-Capybara-Action: refresh`.
Cross-origin browser requests and foreign Host headers are rejected.

## Local VPN control

This is an optional legacy standalone tool, not a widget dependency. The
widget now uses only the Mihomo API for ON/OFF and its startup preference;
it never invokes this binary or Polkit, and its mode changes are runtime-only.
An existing helper installation is not automatically removed or modified.

`src/bin/mihomo-vpn-control.rs` is a separate restricted binary in this crate.
Unlike the subscription updater, it accepts no configuration paths, URLs, or
arbitrary commands. Its only actions are `on`, `off`, `ensure`, and `restart`.
It uses fixed system paths and only the loopback Mihomo API.

Build with `cargo build --release --locked`, then run
`pkexec /bin/sh /absolute/path/to/updater/install-vpn-control.sh` once.
The installer deploys the root-owned helper and its narrow Polkit policy,
enables mihomo.service and starts it without changing the configured mode.
The supplied rule is for the active local user `korbash`; review it before
installing on another machine. No password is needed for subsequent helper
actions in that session. Unrelated administrative commands remain protected.

An explicit toggle validates and atomically saves `mode` in the actual system
config before applying it. The last enabled rule/global mode is remembered in
`/etc/mihomo/widget-state.json`. The original config is retained as
`config.yaml.before-widget-control`. Configuration, routing and provider data
other than `mode` remain unchanged. Concurrent control commands are locked.
Validation failure leaves both the config and saved state unchanged. If the
live service cannot confirm the saved mode, the helper returns an error rather
than reporting success.

OFF means DIRECT while the core and local dashboard remain running. Repeated
OFF calls preserve the previous enabled mode. NetworkManager's try-restart,
resume hooks, normal systemd restarts and Mihomo's native process restart read
the saved config and cannot turn a saved OFF into ON. Direct API/dashboard
mode changes outside this helper, including widget changes, are runtime-only;
invoke this standalone helper for persistent state. `ensure` starts the core
without changing mode.

Legacy local launchers requiring persistent state or service startup must
invoke this helper explicitly, not the plugin bridge. The bridge's `set-vpn`
action now changes only the live API mode; its `restart` and `ensure-running`
actions have been removed. OFF should use DIRECT rather than stop the service.

## Validation

`cargo test --locked` checks rejection, profile normalization, cache retention,
durable status, and stable device identity. `cargo clippy --all-targets -- -D
warnings` checks the implementation. `make reload` from the widget project
validates and hot-reloads the desktop integration.

Request behavior was studied in FlClashX commit
`dc77f6f9714958403e2bd7ccbe8bcac6f80855bb`: `lib/common/package.dart`,
`lib/models/profile.dart`, `lib/common/request.dart`, and
`lib/utils/device_info_service.dart`. This is an independent implementation of
the HTTP exchange; FlClashX does not need to be installed.
