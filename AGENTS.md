# Project workflow

- After every repository edit, validate both QML files with:
  `qmllint -I dev-imports -I /usr/lib/qt6/qml plugin/MihomoVpnWidget.qml plugin/MihomoVpnSettings.qml`.
- After validation, always reinstall/reconnect the working plugin and restart DMS with:
  `./install-local.sh`.
- An edit is not complete until both commands succeed. If either command cannot run, report that explicitly.
