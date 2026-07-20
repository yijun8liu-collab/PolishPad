# PolishPad

**English** | [简体中文](README.zh-CN.md)

A macOS menu bar utility: summon a floating input panel with a global hotkey, and let AI rewrite your rambling, loosely structured input into clear, well-organized text — automatically copied to the clipboard. Not happy with the result? Refine it through multi-round conversation.

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
  "hotkeyPolishSelection": "ctrl+option+r",  // polish selection in place
  "hotkeyPolishAll": "ctrl+option+a",        // select-all and polish
                                             // all three are recordable by keypress in Settings…, apply on save
  "systemPrompt": null,                      // set a string to override the built-in polishing prompt
  "speechLocale": "zh-CN"                    // speech recognition language (zh-CN / en-US / ...)
}
```

Config file path: `~/Library/Application Support/PolishPad/config.json`.
All fields except `hotkey` are re-read on every request — changes take effect immediately, no restart needed.

## Usage

1. Put the cursor in any text field → press `⌃⌥P` to summon the panel (press again to dismiss)
2. Type your raw input, press `Enter` to submit (`Shift+Enter` for newline; pressing Enter while composing with an IME won't accidentally submit)
3. When polishing finishes, the result is **automatically pasted back into the originating app**; the panel stays open with focus back in the feedback box
4. For follow-up input, pick the semantics with the **Add/Edit** capsule next to the box (`Tab` toggles): **Add (default)** treats your input as new content — polished and merged into the right place of the full text without touching what's there; **Edit** treats it as revision feedback ("shorten point two"). Each `Enter` deletes the previously pasted text and replaces it **in place**. Satisfied? Press `Enter` with an empty box, `Esc`, or ✕ to finish; focus stays in your app
5. The **中/EN switch** (top right): EN mode outputs English (using a native English system prompt) and switches the UI language too; the choice is remembered, and polish-in-place mode follows it
6. If a request fails your input is never lost — use "Copy Original" as a fallback; every round's result is also on the clipboard
7. **Voice input**: press `⌘D` or click the mic button to start/stop dictation; recognized text streams into the active input box in real time and long pauses don't lose earlier content. First use requests microphone and speech recognition permissions; uses macOS native recognition — with on-device support your voice never leaves the Mac
8. Don't want auto-paste? Set `autoPaste` to `false` in the config to return to clipboard-only mode

Every summon starts a fresh session — closing the panel ends the previous conversation. While the panel is open, `⌘N` clears and restarts manually.

## Polish in place (no panel)

Polish text directly inside any app without leaving the input field:

- **Polish selection**: select text → `⌃⌥R` → replaced in place with the polished version
- **Select-all polish**: cursor inside a text field → `⌃⌥A` → auto select-all, polish, replace everything
- **Right-click menu**: select text → right-click → **Services** → "PolishPad：润色并替换" / "PolishPad：全选润色并替换"
- **Menu bar entry**: click the ✨ icon → polish-selection / select-all-polish items (the latter needs no prior selection)

While processing, a "Polishing…" toast appears next to the cursor and the menu bar icon turns into an hourglass; on success the toast flashes a green ✓ with a sound. On failure an alert explains what happened and **your original text is never modified**. Capturing/pasting temporarily borrows the clipboard; your previous clipboard content (including images and other non-text data) is restored automatically afterwards.

Notes:

- First use prompts for **Accessibility permission** (required for simulated keystrokes). Enable PolishPad in System Settings → Privacy & Security → Accessibility, then press the hotkey again
- The right-click Services menu works in native apps (Notes, Safari, Xcode, ...); Electron apps like VS Code draw their own context menus and won't show it — use the hotkeys there
- The right-click "select-all polish" item only appears when some text is selected (a limitation of the Services mechanism); the hotkey has no such restriction

## Privacy

Your input is sent to the API endpoint you configure. For sensitive content, point `baseURL` at a local Ollama (`http://localhost:11434/v1`) or an internal company proxy so nothing leaves your network. The API key is stored in plaintext in the config file (migrating to Keychain is planned for v0.2).

## Current scope

Covered: multi-round refinement with in-place replacement, Add/Edit dual input modes (Tab toggles), auto paste-back, polish-in-place (hotkey / right-click Services / menu bar entries), voice input (macOS native recognition, long pauses safe), 中/EN bilingual mode (output language + UI language + separate native prompts), in-app settings window (hotkeys recordable by keypress, apply on save), cursor-side HUD feedback, IME-safe Enter handling, request cancellation, original preserved on failure, full clipboard snapshot restore, truncation warning, hotkey conflict alert, multi-display, works over full-screen Spaces.

Not yet covered (future versions): version switching and rollback, Keychain, native Anthropic protocol, streaming output, launch at login.
