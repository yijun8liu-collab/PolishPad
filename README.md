<p align="center">
  <img src="Assets/icon.png" width="128" alt="PolishPad">
</p>

# PolishPad

**English** | [简体中文](README.zh-CN.md)

A macOS menu bar utility: summon a floating input panel with a global hotkey, and let AI rewrite your rambling, loosely structured input into clear, well-organized text — automatically copied to the clipboard. Not happy with the result? Refine it through multi-round conversation. With a custom prompt, the same flow handles translation, tone shifts, or any other text transformation.

## Install (download)

1. Download the latest `PolishPad-x.y.z.zip` from [Releases](https://github.com/yijun8liu-collab/PolishPad/releases), unzip, and drag `PolishPad.app` into your Applications folder
2. The app is not signed with an Apple Developer certificate, so macOS will block it on first launch. Either:
   - After the blocked dialog, go to **System Settings → Privacy & Security** and click **"Open Anyway"** at the bottom
   - Or run in Terminal: `xattr -cr /Applications/PolishPad.app`
3. Supports both Apple Silicon and Intel; requires macOS 13+

## Build from source

```sh
./build.sh        # compiles and packages PolishPad.app (requires Xcode Command Line Tools)
open PolishPad.app
```

For development, `swift run` works too (runs as a terminal process, same functionality).

## First-time setup

After launch, click the ✨ menu bar icon → **Open Config File**, then fill in:

```json
{
  "baseURL": "https://api.openai.com/v1",   // any OpenAI-compatible endpoint (DeepSeek/Moonshot/Ollama/internal proxy)
  "apiKey": "sk-...",
  "model": "gpt-4o-mini",
  "temperature": 0.3,
  "maxTokens": 4096,
  "hotkey": "ctrl+option+p",                 // summon the panel
  "hotkeyRefineSelection": "ctrl+option+r",  // refine selection in place
  "hotkeyRefineAll": "ctrl+option+a",        // select-all and refine
                                             // all three are recordable by keypress in Settings…, apply on save
  "promptPreset": "polish",                  // default scenario: polish / slack-english / formal / concise / custom
  "systemPrompt": null,                      // custom prompt, used when preset is "custom"
  "appPresets": {                            // app-aware: auto-select scenario by frontmost app
    "com.tinyspeck.slackmacgap": "slack-english"
  },
  "glossary": ["小流量=canary"],             // glossary: term=translation, or term alone to keep verbatim
  "speechLocale": "zh-CN"                    // speech recognition language (zh-CN / en-US / ...)
}
```

Config file path: `~/Library/Application Support/PolishPad/config.json`.
All fields except `hotkey` are re-read on every request — changes take effect immediately, no restart needed.

## Usage

1. Put the cursor in any text field → press `⌃⌥P` to summon the panel (press again to dismiss)
2. Type your raw input, press `Enter` to submit (`Shift+Enter` for newline; pressing Enter while composing with an IME won't accidentally submit)
3. When refining finishes, the result is **automatically pasted back into the originating app**; the panel stays open with focus back in the feedback box
4. For follow-up input, pick the semantics with the **Add/Edit** capsule next to the box (`Tab` toggles): **Add (default)** treats your input as new content — refined and merged into the right place of the full text without touching what's there; **Edit** treats it as revision feedback ("shorten point two"). Each `Enter` deletes the previously pasted text and replaces it **in place**. Satisfied? Press `Enter` with an empty box, `Esc`, or ✕ to finish; focus stays in your app
5. The **scenario capsule** in the bottom bar switches refine / Slack English / formal / concise / custom per message (summoning from a mapped app like Slack **auto-selects** it, with a hint); quick-feedback **chips** (Shorter / Formal / Casual / Expand) send one-click revisions; `⌘[`/`⌘]` step through versions (clipboard follows), and the **Diff** toggle highlights changes vs the previous version
6. The **中/EN switch** (top right): EN mode outputs English (using a native English system prompt) and switches the UI language too; the choice is remembered, and refine-in-place mode follows it
7. If a request fails your input is never lost — use "Copy Original" as a fallback; every round's result is also on the clipboard
8. **Voice input**: press `⌘D` or click the mic button to start/stop dictation; recognized text streams into the active input box in real time and long pauses don't lose earlier content. First use requests microphone and speech recognition permissions; uses macOS native recognition — with on-device support your voice never leaves the Mac
9. Don't want auto-paste? Replaced the wrong thing? Menu bar ✨ → **Restore last replacement** undoes it; the **History** submenu keeps the last 20 sessions with every version. Set `autoPaste` to `false` in the config to return to clipboard-only mode

Every summon starts a fresh session — closing the panel ends the previous conversation. While the panel is open, `⌘N` clears and restarts manually.

## Refine in place (no panel)

Refine text directly inside any app without leaving the input field:

- **Refine selection**: select text → `⌃⌥R` → replaced in place with the refined version
- **Select-all refine**: cursor inside a text field → `⌃⌥A` → auto select-all, refine, replace everything
- **Right-click menu**: select text → right-click → **Services** → "PolishPad：润色并替换" / "PolishPad：全选润色并替换"
- **Menu bar entry**: click the ✨ icon → refine-selection / select-all-refine items (the latter needs no prior selection)

While processing, a "Refining…" toast appears next to the cursor and the menu bar icon turns into an hourglass; on success the toast flashes a green ✓ with a sound. On failure an alert explains what happened and **your original text is never modified**. Capturing/pasting temporarily borrows the clipboard; your previous clipboard content (including images and other non-text data) is restored automatically afterwards.

Notes:

- First use prompts for **Accessibility permission** (required for simulated keystrokes). Enable PolishPad in System Settings → Privacy & Security → Accessibility, then press the hotkey again
- The right-click Services menu works in native apps (Notes, Safari, Xcode, ...); Electron apps like VS Code draw their own context menus and won't show it — use the hotkeys there
- The right-click "select-all refine" item only appears when some text is selected (a limitation of the Services mechanism); the hotkey has no such restriction

## Privacy

Your input is sent to the API endpoint you configure. For sensitive content, point `baseURL` at a local Ollama (`http://localhost:11434/v1`) or an internal company proxy so nothing leaves your network. **The API key is stored in the macOS Keychain** (existing plaintext configs migrate automatically on launch, leaving only a sentinel in JSON); Settings shows monthly token usage.

## Current scope

Covered: launch at login, scenario presets with in-panel switching, app-aware auto-selection, personal glossary, quick-feedback chips, version rollback (⌘[/⌘]), change diff view, history (last 20 sessions), one-click replacement restore, Keychain key storage, token usage stats, update checker, streaming output (results render token-by-token; refine-in-place shows live progress), multi-round refinement with in-place replacement, Add/Edit dual input modes (Tab toggles), auto paste-back, refine-in-place (hotkey / right-click Services / menu bar entries), voice input (macOS native recognition, long pauses safe), 中/EN bilingual mode (output language + UI language + separate native prompts), in-app settings window (hotkeys recordable by keypress, apply on save), cursor-side HUD feedback, IME-safe Enter handling, request cancellation, original preserved on failure, full clipboard snapshot restore, truncation warning, hotkey conflict alert, multi-display, works over full-screen Spaces.

Not yet covered (future versions): native Anthropic protocol, Sparkle in-app auto-update.
