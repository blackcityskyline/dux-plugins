# Mihomo DMS Widget

A compact [DankMaterialShell (DMS)](https://github.com/AvengeMedia/DankMaterialShell)
widget built with [Quickshell](https://quickshell.org/) for the system
[Mihomo](https://github.com/MetaCubeX/mihomo/tree/Alpha) service. It presents
selected proxy groups, supports quick node switching, runs latency probes, and
opens a configured [MetaCubeXD](https://github.com/MetaCubeX/metacubexd)
dashboard.

![Mihomo VPN widget with an expanded proxy group](assets/mihomo-vpn.png)

## Features

- Select and order any number of Mihomo `Selector` groups.
- Expand multiple groups at the same time.
- Display the active node, recent latency history, and probe status.
- Scroll long node lists while keeping the popout within the screen bounds.
- Switch nodes, probe all visible groups, and restart Mihomo through its
  controller API.
- Open a configured MetaCubeXD dashboard directly from the widget.
- Preserve expanded groups and scroll positions across periodic API refreshes.

## Requirements

### Runtime

- [DankMaterialShell (DMS)](https://github.com/AvengeMedia/DankMaterialShell)
  1.5.0 or newer. DMS provides the Quickshell and Qt 6 runtime used by the
  widget.
- A running [Mihomo](https://github.com/MetaCubeX/mihomo/tree/Alpha) instance.
- Mihomo's
  [external controller REST API](https://wiki.metacubex.one/en/config/general/#external-control-api)
  reachable at `http://127.0.0.1:9090` with an empty API secret:

  ```yaml
  external-controller: 127.0.0.1:9090
  secret: ""
  ```

- `curl` and `jq` available on `PATH`.

The external controller is built into Mihomo. This widget and MetaCubeXD are
independent clients of that API: the widget connects directly to Mihomo, while
MetaCubeXD provides the optional full dashboard.

The **Restart Mihomo** action sends `POST /restart` to this API. Mihomo responds
and re-executes its running process with the same arguments and environment.
Latency probes ask Mihomo to fetch `https://www.gstatic.com/generate_204`
through each selected node.

### Optional dashboard

The **Open MetaCubeXD** action opens `http://127.0.0.1:9090/ui/` through Qt.
Configure MetaCubeXD assets with Mihomo's
[`external-ui`](https://wiki.metacubex.one/en/config/general/#external-user-interface)
setting to serve the dashboard at that address. MetaCubeXD remains optional for
all proxy controls and latency probes.

### Development

- Qt 6 QML tooling that provides `qmllint`.
- Installed DMS QML sources at `/usr/share/quickshell/dms`; the component test
  also uses the `quickshell` executable.

## Project layout

- `plugin/` contains the DMS widget, settings component, and bundled
  `mihomo-dms` bridge to the local Mihomo API.
- `tests/` contains component and interactive diagnostics.
- `dev-imports/qs` links the project tooling to the installed DMS QML sources.

The local installation uses this project link:

- `~/.config/DankMaterialShell/plugins/MihomoVpn` → `plugin/`.

## Installation

Run the local installer from the repository root:

```sh
./install-local.sh
```

The installer refreshes the links above and restarts the `dms.service` systemd
user unit. Run it after every project change.

## Configuration

Open the Mihomo VPN plugin settings in DMS. The settings page loads available
`Selector` groups from the local Mihomo API. Select the groups that belong in
the widget and use the arrow controls to arrange their display order.

Routing rules remain in `/etc/mihomo/config.yaml` and its configured rule
provider files. For example, domain suffixes routed through the Russia proxy
group live in `/etc/mihomo/rules/russia-sites.yaml`:

```yaml
payload:
  - "+.example.com"
```

Validate and apply routing changes with:

```sh
sudo mihomo -t -d /etc/mihomo -f /etc/mihomo/config.yaml
plugin/mihomo-dms restart
```

## QML development

The repository includes `.zed/settings.json` and
`mihomo-dms-widget.qmlproject`. They configure `qmlls6` with the Qt modules and
the `dev-imports/qs` bridge to the installed DMS QML sources.

Create the bridge on another Arch Linux system with:

```sh
mkdir -p dev-imports
ln -sfn /usr/share/quickshell/dms dev-imports/qs
```

Restart the language server in Zed after changing the editor configuration.
Run the static QML validation from the repository root:

```sh
qmllint -I dev-imports -I /usr/lib/qt6/qml plugin/MihomoVpnWidget.qml plugin/MihomoVpnSettings.qml
```

## Tests

The component test uses the standard project dependencies. Interactive capture
uses niri, while pointer calibration uses `ydotool`; both tools are optional and
only support the diagnostic scripts below.

Run the component self-test to cover independent group expansion, boundary
sizes, long-list interaction, and scroll-position stability:

```sh
./tests/run-component-selftest.sh
```

Run an interactive capture to open the widget, allow time for clicks and
scrolling, and capture the screen directly through niri. The direct capture
keeps the popout visible throughout the screenshot:

```sh
./tests/capture-widget-interaction.sh 15 /tmp/mihomo-widget.png
```

Measure the effective `ydotool` movement under the current niri pointer
acceleration before building automated pointer tests. The calibrator performs
pointer movement only:

```sh
./tests/calibrate-pointer.sh 800 54
```

## Project goals

- Discover proxy-group names dynamically from the Mihomo API.
- Support any number of user-selected `Selector` groups.
- Honor the user-defined group order throughout the interface.
- Deliver a compact interface with current-node and latency information.
- Keep expansion, scrolling, and input behavior stable during live refreshes.
- Integrate cleanly with the standard DMS plugin and settings APIs.

## Security model

The bundled bridge connects exclusively to the local Mihomo API at
`127.0.0.1:9090`. Mihomo keeps subscription data, credentials, and routing
configuration under the system service configuration in `/etc/mihomo`.

## License

Mihomo DMS Widget is available under the [MIT License](LICENSE).
