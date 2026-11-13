# Mihomo DMS Widget

A compact [DankMaterialShell (DMS)](https://github.com/AvengeMedia/DankMaterialShell)
widget built with [Quickshell](https://quickshell.org/) for the system
[Mihomo](https://github.com/MetaCubeX/mihomo/tree/Alpha) service. It presents
selected proxy groups, supports quick node switching, runs latency probes, and
opens a configured [MetaCubeXD](https://github.com/MetaCubeX/metacubexd)
dashboard.

Personal fork of [korbash/mihomo-dms-widget](https://github.com/korbash/mihomo-dms-widget)
that adds service control, TUN mode and three bar display modes.

![Mihomo VPN widget with an expanded proxy group](assets/mihomo-vpn.png)

## Features

- Update configured HTTP proxy providers through Mihomo's standard API.
  The update button is hidden when no HTTP providers are available. Failures
  from widget-initiated updates use notifications and a compact indicator.

- Select any number of Mihomo `Selector` groups and drag enabled groups in
  settings to arrange their widget order. Disabled groups appear at the bottom.
- Optionally enable VPN when the widget loads (including shell restarts and
  plugin reloads). `Enable VPN on startup` defaults to off and runs only once
  per widget instance after the API becomes available; manually turning VPN
  off is respected until the next load. This does not start the Mihomo service.
- Expand multiple groups at the same time.
- Display the active node, recent latency history, and probe status.
- Scroll long node lists while keeping the popout within the screen bounds.
- Switch nodes and probe all visible groups through the local controller API.
- Switch VPN ON/OFF through Mihomo's API: OFF selects `direct`; ON restores
  the previous `rule` or `global` mode (default: `rule`).
- Start and stop `mihomo.service` from the popout header.
- Toggle TUN mode through the local `miho` helper, which already handles the
  root daemon, DNS and interface cleanup.
- Open a configured MetaCubeXD dashboard directly from the widget.
- Preserve expanded groups and scroll positions across periodic API refreshes.

## Bar indicator

The bar shows a shield glyph plus, depending on the `Bar display` setting:

- `Full` — the shield and the active node or group name.
- `Emoji only` — the shield and the flag or emoji found in that name, if any.
- `Icon only` — the shield alone.

The shield itself carries the state: a plain shield before the first status
response, a shield with a check while a VPN mode is active, a shield with a
cross when Mihomo is unavailable, and a shield with an upward arrow in DIRECT
mode. The `OFF` caption is gone; a stopped VPN shows only the icon.

## Known limitation

In DMS connected frame mode, very rapid clicks while the popout is resizing can
occasionally be interpreted as an outside click and dismiss the popout.

## Requirements

### Runtime

- [DankMaterialShell (DMS)](https://github.com/AvengeMedia/DankMaterialShell)
  1.5.0 or newer. DMS provides the Quickshell and Qt 6 runtime used by the
  widget.
- A [Mihomo](https://github.com/MetaCubeX/mihomo/tree/Alpha) installation. The
  widget can start and stop `mihomo.service` (user or system unit); TUN mode
  additionally needs the `miho` helper used by this setup.
- Mihomo's
  [external controller REST API](https://wiki.metacubex.one/en/config/general/#external-control-api)
  reachable at `http://127.0.0.1:9090` with an empty API secret:

  ```yaml
  external-controller: 127.0.0.1:9090
  secret: ""
  ```

- `curl` and `jq` available on `PATH`.
- `systemctl` for service control, and `miho` (found on `PATH` or at
  `~/bin/others/miho`) for TUN mode.

The external controller is built into Mihomo. This widget and MetaCubeXD are
independent clients of that API: the widget connects directly to Mihomo, while
MetaCubeXD provides the optional full dashboard.

Mode, node, probe and provider operations use the controller API. Service start
and stop use `systemctl --user` (falling back to the system unit), and stop
falls back to `miho stop` when a daemon was started outside systemd. TUN mode
delegates to the `miho` helper because enabling TUN needs root: it regenerates
the TUN config, starts the daemon, and restores DNS on the way out. The bridge
runs that fixed helper call through `pkexec`, so DMS's polkit agent shows its
password dialog; cancelling the dialog changes nothing. Disabling TUN stops the
root daemon the same way and starts `mihomo.service` again so proxy mode is
back under systemd.

The bundled `mihomo-dms` script is a local bridge, not a general-purpose root
helper: under `pkexec` it only runs fixed `miho` actions, sets `HOME` to the
calling user's home, and hands `~/.config/mihomo` and `~/.config/miho` back to
that user. A polkit agent must be running for the password dialog; DMS ships
one.

The VPN switch reads `GET /configs`, applies `PATCH /configs`, and confirms
the resulting mode with another GET. OFF uses DIRECT, bypassing routing rules
while the core and dashboard remain running. ON restores the last enabled
mode, remembered in `$XDG_STATE_HOME/mihomo-dms/previous-mode` (default state
directory: `~/.local/state`). Repeated OFF does not overwrite it; missing or
invalid saved state defaults to `rule`. ON while already enabled preserves
the current mode. The indicator reflects routing mode, not an end-to-end
connectivity guarantee.

These mode changes are runtime changes: the plugin does not write the Mihomo
config file or preserve OFF across a Mihomo restart/config reload. Mihomo then
uses its own configured mode. Start the core separately using your service
manager or the popout header button. When the API is unavailable the switch is
disabled, the bar shows the cross shield, and a compact error indicator stays
until status is available again.
The obsolete bridge actions `restart` and `ensure-running` are no longer supported.
Labels, tooltips and errors are displayed in English. Known Russian group and
server names are translated only for display; API identifiers, selection and
routing stay unchanged. No subscription or service-status cards are added to
the popout: failure details use notifications, and update progress uses the
button icon. There are no tooltip overlays on the bar indicator; button
tooltips are short action labels only. Previous subscription failures are not
highlighted while a retry is running. Status changes do not change widget height.
Latency probes ask Mihomo to fetch `https://www.gstatic.com/generate_204`
through each selected node.

### Subscription updates

The widget discovers HTTP providers through `GET /providers/proxies` and
updates each with `PUT /providers/proxies/{name}`. File and built-in providers
are excluded. Updates run sequentially, continue after individual failures,
and report partial failure instead of claiming that all providers succeeded.
OFF/DIRECT does not prevent updates while the Mihomo controller is reachable.
This updates provider node lists, not an entire downloaded Mihomo configuration.

No provider-specific updater or subscription token is required by the widget.
The optional [Capybara adapter](updater/README.md) can remain configured as an
HTTP provider in Mihomo; the widget uses the same API for it as for any other
HTTP provider and never contacts port 9095. Detailed adapter diagnostics stay
in the adapter. The widget reports provider names and safe HTTP/connection
errors without exposing upstream response bodies or subscription URLs.

### Optional dashboard

The **Open MetaCubeXD** action opens `http://127.0.0.1:9090/ui/` through Qt.
Configure MetaCubeXD assets with Mihomo's
[`external-ui`](https://wiki.metacubex.one/en/config/general/#external-user-interface)
setting to serve the dashboard at that address. MetaCubeXD remains optional for
all proxy controls and latency probes.

### Development

- GNU Make and Git.
- Qt 6 QML tooling that provides `qmllint`.
- Installed DMS QML sources at `/usr/share/quickshell/dms`; the component test
  also uses the `quickshell` executable.

## Project layout

- `plugin/` contains the DMS widget, settings component, and bundled
  `mihomo-dms` bridge to the local Mihomo API.
- `Makefile` is the public interface for validation, local development, and
  registry checkout management.
- `scripts/plugin-workflow.sh` implements the Make targets.
- `tests/` contains component and interactive diagnostics.
- `dev-imports/qs` links the project tooling to the installed DMS QML sources.

Local development uses this canonical project link:

- `~/.config/DankMaterialShell/plugins/mihomoVpn` → `plugin/`.

## Installation

Install the published plugin from the DMS registry:

```sh
dms plugins install mihomoVpn
```

The registry installation keeps its checkout under the DMS `.repos` directory.
Plugin settings and DankBar placement are stored by the `mihomoVpn` ID and are
shared when switching between the published and local sources.

## Configuration

Open the Mihomo VPN plugin settings in DMS. The settings page loads available
`Selector` groups from the local Mihomo API. Select the groups that belong in
the widget and drag enabled groups to arrange their display order.

`Bar display` selects the three bar variants described above. `Enable VPN on
startup` still runs once per widget load and never starts the service.

Routing rules remain in the Mihomo config directory, `~/.config/mihomo` in this
setup, and its configured rule provider files.

Validate and apply routing changes with:

```sh
mihomo -t -d ~/.config/mihomo -f ~/.config/mihomo/config.yaml
systemctl --user restart mihomo.service
```

## Development workflow

The root `Makefile` is the single public development interface. Its targets
validate the project, hot reload local changes, and switch between the local
source and the registry-managed checkout. The internal workflow script handles
the canonical `mihomoVpn` link and DMS IPC details.

```sh
make status
```

The status command reports the active mode, link target, plugin version, and
project revision.

### Command reference

| Command | Purpose |
| --- | --- |
| `make test` | Run QML linting, manifest and shell validation, and the component self-test without changing the active plugin source. |
| `make local` | Validate the project, switch to the local source, and hot reload `mihomoVpn`. |
| `make reload` | Revalidate and hot reload the local source after a development change. |
| `make store` | Restore the existing registry checkout without a network request and hot reload it. |
| `make update-store` | Validate, download the published update through DMS, activate it, and hot reload it. |
| `make status` | Report the active mode, link target, plugin version, and project revision. |

Normal development does not restart the full shell. The workflow first asks DMS
to reload only this plugin through IPC and restarts `dms.service` once only if
that hot reload fails.

### Fixing a bug locally

Start from the latest public branch and enter local mode:

```sh
git switch main
git pull --ff-only
make local
```

Edit the project and apply each iteration with one command:

```sh
make reload
```

This command runs all automated checks before changing the live component.

Return to the already installed store version at any time, without downloading
anything:

```sh
make store
```

Run `make local` to resume work on the project checkout.

### Publishing a new version

After the fix passes local testing, update `version` in
`plugin/plugin.json` according to [Semantic Versioning](https://semver.org/).
Update the `?v=` suffix in the manifest's `settings` URL to the same version.
DMS caches settings components separately from widgets, so each release needs
a new settings URL. The workflow rescans the plugin manifest before hot reload.
Increment `PATCH` for a compatible bug fix and `MINOR` for new compatible
functionality. For example, the next patch after `1.2.1` is `1.2.2`.

Run the release checks and inspect the final changes:

```sh
make test
git diff --check
git diff
```

Commit, tag, and push the same version:

```sh
git add plugin/plugin.json plugin/MihomoVpnWidget.qml
git commit -m "Fix popout input handling"
git tag -a v1.2.2 -m "Mihomo DMS Widget 1.2.2"
git push origin main
git push origin v1.2.2
```

Include every file belonging to the release in `git add`; the command above is
only an example for a widget-only fix. Once the push is visible, update the
registry-managed checkout and leave the machine in store mode:

```sh
make update-store
make status
```

The plugin is already registered, so regular releases update the existing
repository rather than adding another registry entry.

### Recovering from a release problem

Before `update-store`, `make store` immediately returns to the previously
installed store checkout. After a faulty version has been published and
installed, revert the faulty commit, increment the patch version again, repeat
the tests, and publish a new tag. Preserve public Git history instead of moving
or force-pushing an existing release tag.

## QML tooling

The repository includes `.zed/settings.json` and
`mihomo-dms-widget.qmlproject`. They configure `qmlls6` with the Qt modules and
the `dev-imports/qs` bridge to the installed DMS QML sources.

Create the bridge on another Arch Linux system with:

```sh
mkdir -p dev-imports
ln -sfn /usr/share/quickshell/dms dev-imports/qs
```

Restart the language server in Zed after changing the editor configuration.
Run the complete project validation from the repository root:

```sh
make test
```

## Tests

Run the complete automated test suite. It includes the component checks for
independent group expansion, boundary sizes, long-list interaction, and
scroll-position stability:

```sh
make test
```

### Optional diagnostics

Run an interactive capture to open the widget, allow time for clicks and
scrolling, and capture the screen directly through niri. The direct capture
keeps the popout visible throughout the screenshot:

```sh
./tests/capture-widget-interaction.sh 15 /tmp/mihomo-widget.png
```

## Project goals

- Discover proxy-group names dynamically from the Mihomo API.
- Support any number of user-selected `Selector` groups.
- Honor the user-defined group order throughout the interface.
- Deliver a compact interface with current-node and latency information.
- Keep expansion, scrolling, and input behavior stable during live refreshes.
- Integrate cleanly with the standard DMS plugin and settings APIs.

## Security model

The bridge uses only the local Mihomo API at `127.0.0.1:9090` for routing mode,
provider and proxy operations. It runs as the desktop user and writes only
user-local state (the previous enabled mode and latency history). It never
requests elevation or invokes service management. The optional legacy root
controller under `updater/` is not used by the plugin; existing installations
are left untouched. Subscription downloads and actual node reachability probes
are performed by Mihomo and necessarily access the network. Keep the controller
bound to loopback; this plugin currently expects an empty API secret.

## License

Mihomo DMS Widget is available under the [MIT License](LICENSE).
