<img src="assets/icon-1024.png" width="96" align="right" alt="CC HUD icon">

# CC HUD

A floating macOS HUD that monitors every Claude Code session on your machine in real time — across any terminal, any window.

English · [简体中文](README.zh-CN.md)

## Features

- **Status at a glance** — waiting for permission (with the pending command), working (current activity + elapsed timer), idle, or unresponsive.
- **Usage** — per-session context-window %, account-level 5h / 7d quota with reset countdown, and today's token total.
- **Click to jump** — click a session row to focus the terminal window it runs in (iTerm2 / Terminal down to the tab; Ghostty best-effort).
- **Three layouts** — carousel pill, list, or expanded card. Click to switch; drag to move and reorder.
- **Zero-config** — on first launch it wires itself into `~/.claude/settings.json` (hooks + a statusline wrapper that leaves your own statusline display unchanged). One click in the menu bar uninstalls and restores.

## Requirements

- macOS 15+ (universal binary — Apple Silicon and Intel).
- Claude Code 2.x. The official native binary install works best; npm/node installs still display and monitor sessions but lose the process-level fallback (sessions already open before install appear after a restart; jump degrades to activating the host app).
- The 5h / 7d quota bars require a subscription account (Pro / Max).

## Install

Download the latest `CC-HUD.dmg` from the [**Releases**](https://github.com/shiyaming1994/cc-hud/releases) page, then:

1. Open the DMG and drag **CC HUD.app** into **Applications**.
2. Clear the Gatekeeper quarantine (the app isn't notarized) — **either** run `xattr -cr "/Applications/CC HUD.app"` in Terminal, **or** double-click the app once and click **"Open Anyway"** in **System Settings → Privacy & Security**.

Requires macOS 15+.

## Build from source

```bash
git clone https://github.com/shiyaming1994/cc-hud.git
cd cc-hud
./scripts/build-app.sh && open "dist/CC HUD.app"
```

Package a DMG for distribution:

```bash
./scripts/make-dmg.sh   # → dist/CC-HUD.dmg (drag into Applications)
```

The app ships no machine-specific configuration; every path is derived from `$HOME` and generated on first launch. The build signs with a local Apple Development certificate when one is available, otherwise it falls back to ad-hoc signing. Without a Developer ID certificate and notarization, the first launch on another Mac is gated by Gatekeeper — **right-click → Open → Open** once (or System Settings → Privacy & Security → Open Anyway).

## How it works

Claude Code pushes JSON to a unix domain socket (`~/.claude/cc-hud/hud.sock`) through hooks and the statusline; a state machine inside the app drives the SwiftUI rendering. There is no hot polling path — only a 5s PID-liveness check and a 60s daily-token scan. When the HUD isn't running, the emitter exits silently after a 100ms timeout, so it has zero impact on Claude Code.

## Known limitations

- **tmux** sessions are monitored, but click-to-jump isn't supported yet.
- **CLAUDE_CONFIG_DIR**: a customized Claude config directory isn't supported yet (install writes to the default `~/.claude`).
- Sessions already running when you install appear as "idle" (process-scan fallback); full activity / permission state requires restarting the session.
- npm/node installs of Claude Code: process identification degrades, though the event stream is unaffected.
- SSH and in-container remote sessions are out of scope.

The menu bar shows event-stream health (`event: Ns ago`, with a parse-failure count) for troubleshooting.

## License

[MIT](LICENSE)
