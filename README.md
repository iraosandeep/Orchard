<p align="center"><img src="docs/logo.png" width="128" alt="Orchard logo"></p>

# Orchard

**Apple's on-device AI, everywhere on your Mac.** Fix, shorten, rewrite and translate text in any app, chat with the model, and run quick text tasks from the terminal. It all runs on your Mac with Apple Intelligence: no account, no cloud, nothing leaves your Mac.

## What you can do

### Rewrite anywhere
Select text in any app, then:
- press **⌃⌥R**, or
- hover the **🍃 Orchard** button that appears next to your selection, or
- right-click › **Services** › **Rewrite with Orchard…**, **Fix Grammar with Orchard** or **Translate with Orchard**.

Pick **Fix Grammar ⌘1 · Shorter ⌘2 · Formal ⌘3 · Friendly ⌘4 · Translate ⌘5**, or describe your own change. You can edit the text first. Press **⌘Return** to replace your selection, or **Copy** the result. Your clipboard is left as it was.

### Translate
One click translates into your default language (choose it in Settings), or pick another from the Translate menu.

### Chat
A native chat window with streaming replies, markdown and per-chat instructions. **⌘N** starts a new chat. Chats are saved on your Mac.

### Tasks and the command line
Summarize, extract fields, classify, or write a commit message from a diff:

```sh
pbpaste | orchard run summarize
git diff --cached | orchard run commit
echo "Invoice from Acme, Mar 3, $1,240" | orchard run extract -o "vendor, date, total"
```

Add your own tasks to `~/.orchard/tasks.yaml`; changes apply immediately:

```yaml
- name: classify
  label: Classify
  system: Classify the text into exactly one of these labels: {option}. Output only the label.
  option: { label: Labels, default: "bug, feature, question" }
```

Install the `orchard` command from Settings. Tasks also run in the browser: **Open Tasks in Browser** in the menu bar.

## Install

```sh
curl -fsSL https://github.com/iraosandeep/Orchard/releases/latest/download/install.sh | sh
```

You need an Apple Silicon Mac on macOS 26.4 or later with Apple Intelligence turned on. The command installs Orchard into Applications, sets up the `orchard` command and opens the app.

Orchard isn't notarized by Apple. If you download `Orchard.zip` in a browser instead, the first launch needs System Settings › Privacy & Security › **Open Anyway**.

## First launch

Orchard lives in the menu bar (🍃). If something needs your attention, **Settings** (⌘,) opens and shows a one-click fix for each item:
- **Apple Intelligence:** turn it on in System Settings and wait for the model to download.
- **`fm` license:** read and agree to Apple's terms for the Foundation Models tool.
- **Accessibility:** needed so Rewrite can replace text in other apps.

Closing the window keeps Orchard running in the menu bar so the shortcut keeps working. Quit from the menu bar or with ⌘Q.

## Privacy

Everything runs on your Mac through Apple's on-device model. Orchard has no account and sends nothing anywhere. The only network request is the daily update check against GitHub, which you can turn off in Settings.

## Updates

Orchard checks for a new version on launch and once a day. When one is available it asks once, then keeps an **Update to …** item in the menu bar. Updates are only installed if they're signed by the same certificate as your copy. Running the install command again also updates.

## Troubleshooting

- **"Apple Intelligence is off":** Settings › Open Settings…, turn it on, and wait for the download.
- **The Services items are missing:** apps load the Services menu when they start, so quit and reopen the app. You can also turn them on in System Settings › Keyboard › Keyboard Shortcuts › Services, and give them shortcuts there.
- **⌃⌥R keeps asking for Accessibility although Orchard is switched on:** click **Reset Permission** (in the prompt or in Settings) and switch Orchard on again.
- **The 🍃 button stopped showing in an app:** you may have chosen "Don't Show in …". Settings › **Show in All Apps Again**.
- **"Safety filter declined this":** Apple's guardrails blocked the request. Try rephrasing.

## Feedback

[Report a bug](https://github.com/iraosandeep/Orchard/issues/new?labels=bug) · [Request a feature](https://github.com/iraosandeep/Orchard/issues/new?labels=enhancement) · [Release notes](https://github.com/iraosandeep/Orchard/releases)

Need help? Email [iraosandeep.dev@gmail.com](mailto:iraosandeep.dev@gmail.com).

You can also use **Settings › Help & Feedback**, which fills in your Orchard and macOS versions for you. Building from source or contributing? See [CONTRIBUTING.md](CONTRIBUTING.md).
