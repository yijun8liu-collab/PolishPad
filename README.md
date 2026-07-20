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
  "hotkey": "option+space",                  // requires app restart after change
  "hotkeyPolishSelection": "ctrl+option+r",  // polish-selection-in-place hotkey (restart required)
  "hotkeyPolishAll": "ctrl+option+a",        // select-all-and-polish hotkey (restart required)
  "systemPrompt": null,                      // set a string to override the built-in polishing prompt
  "speechLocale": "zh-CN"                    // speech recognition language (zh-CN / en-US / ...)
}
```

Config file path: `~/Library/Application Support/PolishPad/config.json`.
All fields except `hotkey` are re-read on every request — changes take effect immediately, no restart needed.

## Usage

1. Press `⌥ + Space` to summon the input panel (press again to dismiss)
2. Type your raw input, press `Enter` to submit (`Shift+Enter` for newline; pressing Enter while composing with an IME won't accidentally submit)
3. The result is **automatically copied to the clipboard** — switch back to your app and `⌘V`
4. Not satisfied? Describe what to change in the feedback box below, press `Enter`, and the new version is copied automatically again
5. `Esc` closes the panel (stops dictation first if recording, cancels the request first if one is in flight); `⌘N` clears the session and starts over
6. If a request fails, your input is never lost — use the "Copy Original" button as a fallback
7. **Voice input**: press `⌘D` or click the mic button at the bottom left to start/stop dictation. Recognized text streams into the active input box (draft or feedback) in real time; when you're done, just press `Enter` to polish — the missing punctuation and structure in your speech is exactly what the polishing step fixes. First use will request microphone and speech recognition permissions. Uses macOS native recognition; on machines with on-device recognition support, your voice never leaves the Mac

Every summon starts a fresh session — closing the panel ends the previous conversation. While the panel is open, `⌘N` clears and restarts manually.

## Polish in place (no panel)

Polish text directly inside any app without leaving the input field:

- **Polish selection**: select text → `⌃⌥R` → replaced in place with the polished version
- **Select-all polish**: cursor inside a text field → `⌃⌥A` → auto select-all, polish, replace everything
- **Right-click menu**: select text → right-click → **Services** → "PolishPad：润色并替换" / "PolishPad：全选润色并替换"

While processing, the menu bar icon turns into an hourglass; on success it briefly shows ✓ with a sound. On failure an alert explains what happened and **your original text is never modified**. Capturing/pasting temporarily borrows the clipboard; your previous clipboard content (including images and other non-text data) is restored automatically afterwards.

Notes:

- First use prompts for **Accessibility permission** (required for simulated keystrokes). Enable PolishPad in System Settings → Privacy & Security → Accessibility, then press the hotkey again
- The right-click Services menu works in native apps (Notes, Safari, Xcode, ...); Electron apps like VS Code draw their own context menus and won't show it — use the hotkeys there
- The right-click "select-all polish" item only appears when some text is selected (a limitation of the Services mechanism); the hotkey has no such restriction

## Privacy

Your input is sent to the API endpoint you configure. For sensitive content, point `baseURL` at a local Ollama (`http://localhost:11434/v1`) or an internal company proxy so nothing leaves your network. The API key is stored in plaintext in the config file (migrating to Keychain is planned for v0.2).

## v0.1 scope

Covered: multi-round refinement, auto-copy on every round, voice input (macOS native recognition), IME-safe Enter handling, request cancellation, original text preserved on failure, truncation warning, hotkey conflict alert, multi-display support (panel appears on the screen with the mouse), works over full-screen Spaces.

Not yet covered (future versions): version switching and rollback, settings UI, Keychain, native Anthropic protocol, streaming output, multiple prompt presets, polish-selected-text mode, launch at login.
