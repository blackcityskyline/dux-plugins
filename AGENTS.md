# Project workflow

- After documentation-only or workflow-only edits, run `make test`.
- After runtime plugin, manifest, bridge, or component-test edits, run `make reload`.
  It includes all static and component checks, activates the local source, and
  hot reloads only `mihomoVpn`.
- Use `make store` only when the user asks to return to the registry-managed
  build or after a published update is ready.
- A full DMS restart is a fallback handled by the workflow; do not restart the
  shell directly during the normal edit loop.
- An edit is not complete until the applicable command succeeds. Report any
  validation, reload, or restoration failure explicitly.

# UI preferences

- Keep the widget compact: no inline subscription, success, progress, or error
  cards, and no error-text tooltip overlays on the bar or buttons.
- Show error details in notifications; use compact indicators for persistent
  status. Button tooltips should contain only short action labels.
- Keep all widget labels and messages in English. Translate provider/group
  names for display only, without changing their underlying API identifiers.
- Do not add a Restart Mihomo button to the widget.
