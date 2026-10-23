# Orchard

Local web UI and CLI for Apple's on-device Foundation Model, via `fm serve`. One Go binary, nothing leaves the machine.

```sh
go build -o orchard .
./orchard -open               # UI on http://127.0.0.1:1977
```

Orchard starts `fm serve` (127.0.0.1:1976) if it isn't running and restarts it if it dies; it stops any `fm serve` it started when it exits. Use `-no-fm` to manage `fm serve` yourself. `orchard run` also starts `fm serve` if needed and leaves it running so the next call is fast. Its log is `~/.orchard/fm.log`.

## Menu-bar app

```sh
launcher/build.sh             # builds Orchard.app with the binary bundled inside
open Orchard.app              # or copy to /Applications and add to Login Items
```

A leaf icon in the menu bar shows status (filled = model ready). The menu has Open Orchard, Start/Stop, Edit Tasks and Quit. If Orchard is already running it attaches instead of starting a second copy, and only stops servers it started. Server log: `~/.orchard/orchard.log`.

## CLI

```sh
orchard tasks                                  # list presets
pbpaste | orchard run summarize
git diff --cached | orchard run commit
echo "Invoice from Acme, Mar 3, $1,240" | orchard run extract -o "vendor, date, total"
echo "hey send it asap" | orchard run rewrite -o formal
```

Git hook (`.git/hooks/prepare-commit-msg`, made executable):

```sh
#!/bin/sh
[ -z "$2" ] && git diff --cached | orchard run commit > "$1"
```

## Tasks

Presets live in `~/.orchard/tasks.yaml` (written with defaults on first run, re-read on every request). `{option}` in `system` is replaced by the option value; `json: true` validates output and retries once.

## Guard

Every request goes through `guard.go`: plain string content, no tools, `model: system`, input trimmed to a 3,000-token budget (chars ÷ 4), SSE always parsed. Chat history drops oldest turns to fit.

Env: `ORCHARD_ADDR` (menu-bar app only, default `127.0.0.1:1977`), `ORCHARD_FM_URL` (default `http://127.0.0.1:1976`), `ORCHARD_HOME` (default `~/.orchard`). Binds to loopback only.

## Native Mac app (chat only)

```sh
mac/build.sh                  # builds "Orchard Chat.app" (Command Line Tools are enough, no Xcode)
open "Orchard Chat.app"
```

A SwiftUI chat window that calls Apple's model through `FoundationModels` directly, so it doesn't need `fm serve`. It shares chat history with the web UI (`~/.orchard/orchard.db`). History is trimmed using exact token counts. The native API gives an 8,192-token context, versus 4,096 through `fm serve`.

**Rewrite Selection (⌃⌥R):** select text in any app and press ⌃⌥R. Then pick Fix Grammar, Shorter, Formal or Friendly (⌘1–4), or type your own instruction. Press ⌘Return to replace the selection; your clipboard is restored afterwards. The first use asks for Accessibility permission (System Settings › Privacy & Security › Accessibility). Because the app is ad-hoc signed, macOS may ask again after a rebuild. Selections over 6,000 characters are refused rather than truncated, so nothing gets cut off. The app keeps running after its window closes so the shortcut keeps working.
