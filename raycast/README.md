# Orchard for Raycast

Rewrite and translate selected text with Apple's on-device model, through the [Orchard](https://github.com/iraosandeep/Orchard) app. Nothing leaves your Mac.

| Command | What it does |
|---|---|
| **Rewrite Selection** | Pick Fix Grammar, Shorter, Formal or Friendly, or type your own instruction. Watch the result, then ↵ to replace the selection or ⌘C to copy. Uses the clipboard when nothing is selected. |
| **Fix Grammar**, **Make Shorter**, **Make Formal**, **Make Friendly** | Rewrite the selection and paste the result over it, with no window. Give them hotkeys in Raycast. |
| **Translate** | Pick a language (recently used first) or type any other, watch the translation, then ↵ to replace the selection or ⌘C to copy. Uses the clipboard when nothing is selected. |
| **Translate Selection** | Translate the selection into your default language (English unless changed in the command's preferences) and paste it over the selection, with no window. |
| **Install Orchard** | Install or update the Orchard app from GitHub. |

The commands talk to the Orchard app's local server (`http://127.0.0.1:1977`, changeable in the extension's preferences). If Orchard is installed but not running they start it; if it isn't installed they offer to install it with:

```sh
curl -fsSL https://github.com/iraosandeep/Orchard/releases/latest/download/install.sh | sh
```

Translation uses the same on-device model, so it's best in languages Apple Intelligence supports; others can come out wrong.

Requires Orchard 0.5.0 or later, on an Apple Silicon Mac with macOS 26.4+ and Apple Intelligence turned on.

## Development

```sh
cd raycast
npm install
npm run dev   # loads the extension into Raycast and rebuilds on save
```
