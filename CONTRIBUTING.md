# Contributing to Orchard

Everything you need to build, change and release Orchard. For what Orchard does and how to use it, see the [README](README.md).

## Build from source

```sh
./build.sh          # builds Orchard.app (needs Go + Xcode Command Line Tools; full Xcode not required)
open Orchard.app    # or drag it to /Applications and add it to Login Items
```

A local build and an installed copy share the same bundle ID, server port and shortcut, so run one at a time: quit the other first (`osascript -e 'quit app id "local.orchard"'`). **About Orchard** shows `0.0.0-dev` for local builds.

## What happens at launch

1. Orchard checks that Apple Intelligence is on, and that the `fm` tool is installed with its license agreed.
2. It starts the bundled Orchard server (web Tasks UI and API on `http://127.0.0.1:1977`).
3. That server starts `fm serve` (`127.0.0.1:1976`) and restarts it if it ever dies.
4. Orchard registers the Rewrite Selection shortcut (⌃⌥R), the right-click Services items and the 🍃 menu-bar item.

If anything needs attention, **Settings** (⌘,) opens automatically:

| Check | If it fails |
| --- | --- |
| Apple Intelligence | **Open Settings…** goes straight to Apple Intelligence & Siri. macOS doesn't let apps turn it on. Orchard notices within a few seconds once the model has downloaded. |
| `fm` tool | Ships with macOS 26 and later at `/usr/bin/fm`. |
| `fm` license | **Review & Agree…** opens `fm license` in Terminal. `fm serve` won't run until it's agreed. |
| Orchard server | Running/Stopped with a **Start/Restart** button. Log: `~/.orchard/orchard.log`. |
| Accessibility | Needed only for Rewrite Selection. **Allow…** opens the right System Settings pane. |
| Command line | **Install** links `orchard` into `/opt/homebrew/bin`, `/usr/local/bin` or `~/.local/bin`. |

Quitting Orchard (⌘Q or from the menu bar) stops the server and any `fm serve` it started. Closing the window doesn't quit; the app keeps running in the menu bar so the shortcut keeps working.

## How it fits together

```
Orchard.app (Swift)
├─ Chat window ──────────────────────┐
├─ Rewrite window (⌃⌥R, 🍃, Services) ┴─ FoundationModels (on-device, 8K context)
├─ Menu bar + Settings
└─ Resources/orchard (Go) ── serve ── web Tasks UI + API ─┐
                             run   ── CLI ────────────────┴─ guard ── fm serve (4K context)
```

Chat and Rewrite call `FoundationModels` directly, so they work even when `fm serve` is down, and get an 8,192-token context (versus 4,096 through `fm serve`). Chat history is trimmed from the oldest turn using exact token counts. Rewrite uses Apple's permissive guardrails for transforming text the user supplies, and refuses selections over 6,000 characters rather than cutting them off.

The Go **guard** (`guard.go`) makes every `fm serve` request safe: plain string content, no tools, input trimmed to a 3,000-token budget (chars ÷ 4), and SSE parsed whether or not streaming was requested.

| Path | What |
| --- | --- |
| `main.go`, `server.go`, `guard.go`, `tasks.go`, `store.go`, `fm.go` | Go server, CLI, guard, presets, SQLite, fm serve supervisor |
| `defaults.yaml` | Default task presets, written to `~/.orchard/tasks.yaml` on first run |
| `web/` | Embedded web UI (plain HTML/CSS/JS, no build step) |
| `mac/` | SwiftUI app: chat, Rewrite window, selection button, Services menu, menu bar, Settings, updater |
| `build.sh` | Builds `Orchard.app` with the Go binary bundled inside, and declares the Services menu items |
| `mac/icon/make-icon.swift` | Draws the app icon (`AppIcon.icns`, `docs/logo.png`, `web/icon.png`); run `swift mac/icon/make-icon.swift` after editing |

Chats live in `~/.orchard/orchard.db`, shared by the native app and the web UI.

## CLI and tasks reference

```sh
orchard tasks                                  # list presets
orchard tasks --json                           # the same as JSON (the chat window reads this for / tasks)
pbpaste | orchard run summarize
git diff --cached | orchard run commit
echo "Invoice from Acme, Mar 3, $1,240" | orchard run extract -o "vendor, date, total"
echo "hey send it asap" | orchard run rewrite -o formal
```

`orchard run` starts `fm serve` if it isn't running and leaves it up, so the next call is fast. The binary also runs standalone, without the app: `orchard serve [-addr 127.0.0.1:1977] [-open] [-no-fm]`.

Git hook (`.git/hooks/prepare-commit-msg`, made executable):

```sh
#!/bin/sh
[ -z "$2" ] && git diff --cached | orchard run commit > "$1"
```

Task fields in `~/.orchard/tasks.yaml` (re-read on every request):

| Field | Meaning |
| --- | --- |
| `name` | Used in the URL and CLI: `orchard run <name>` |
| `label` | Shown in the UI |
| `system` | Instructions; `{option}` is replaced with the option value |
| `option` | Optional extra input: `label`, `default`, `choices` |
| `json` | Validate the output as JSON; retry once, else return the raw text |
| `max_input_chars` | Cap on input length (always also capped to the token budget) |

Input over budget is truncated, with a visible warning in the web UI.

## Configuration

| Env var | Default | Used by |
| --- | --- | --- |
| `ORCHARD_HOME` | `~/.orchard` | DB, `tasks.yaml`, logs |
| `ORCHARD_FM_URL` | `http://127.0.0.1:1976` | Go server/CLI |
| `ORCHARD_ADDR` | `127.0.0.1:1977` | App (server address) |

Everything binds to loopback only.

## Code signing and Accessibility

`build.sh` signs with a stable local certificate, "Orchard Local Code Signing", created once in your login keychain. An ad-hoc signature changes every build, which silently invalidates the Accessibility grant; the stable certificate keeps it across rebuilds. Set `ORCHARD_SIGN_ID` to use your own Developer ID instead. To remove it, delete "Orchard Local Code Signing" in Keychain Access.

If ⌃⌥R keeps asking for Accessibility although Orchard looks switched on, that toggle belongs to a build signed differently: click **Reset Permission** and switch Orchard on again.

## Releasing

```sh
./release.sh v0.3.0 --dry-run   # build + zip into dist/
./release.sh v0.3.0             # also tag and publish a GitHub release (Orchard.zip, install.sh, SHA256SUMS)
```

Always release from a Mac that has the "Orchard Local Code Signing" identity, or set `ORCHARD_SIGN_ID`, so users keep their Accessibility grant across updates. The in-app updater refuses an update not signed by the same certificate as the installed copy. Back up that certificate (Keychain Access › export .p12).

## Planning and issues

Work is tracked in [GitHub Issues](https://github.com/iraosandeep/Orchard/issues), grouped into [milestones](https://github.com/iraosandeep/Orchard/milestones) and shown on the Orchard Roadmap project board (Backlog → Todo → In Progress → In Review → Done). Labels carry priority (`P1`–`P3`), size (`size:XS`–`size:XL`) and type. Reference the issue in your PR with `Closes #N`.
