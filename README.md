<p align="center">
  <img src="Assets/icon.png" width="128" alt="PolishPad">
</p>

# PolishPad

**English** | [简体中文](README.zh-CN.md)

A macOS menu bar utility: summon a floating glass panel with a global hotkey, type (or dictate) your rambling thoughts, press Enter — AI rewrites them into clear, well-organized text and **pastes the result straight back into the app you came from**. Refine through multi-round conversation, watch your draft *transmute character-by-character* into the polished version, and switch scenarios (polish / Slack English / formal / concise / your own) on the fly.

## Install (download)

1. Download the latest `PolishPad-x.y.z.zip` from [Releases](https://github.com/yijun8liu-collab/PolishPad/releases), unzip, and drag `PolishPad.app` into Applications
2. The app is not signed with an Apple Developer certificate, so macOS blocks it on first launch. Either:
   - **System Settings → Privacy & Security** → click **"Open Anyway"**
   - or run `xattr -cr /Applications/PolishPad.app` in Terminal
3. Universal binary (Apple Silicon + Intel); requires macOS 13+
4. Grant **Accessibility** permission when prompted (required for paste-back and refine-in-place)

Existing users: **Settings → Check for Updates** compares against the latest release here; download the new zip and replace the app.

## Build from source

```sh
./build.sh              # release build + package PolishPad.app
UNIVERSAL=1 ./build.sh  # universal (arm64 + x86_64) build
open PolishPad.app
```

## First-time setup

Menu bar icon → **Settings…** → fill in the API section (any OpenAI-compatible endpoint: DeepSeek / Moonshot / Ollama / internal proxy):

- **Base URL** — e.g. `https://api.deepseek.com/v1`
- **API Key** — stored locally in the config file with `0600` permissions (no Keychain, no password prompts)
- **Model** — e.g. `deepseek-chat`

Everything else has sensible defaults. The config lives at `~/Library/Application Support/PolishPad/config.json` and is re-read on every request — hand edits apply instantly.

## The panel workflow

| Key | Action |
|---|---|
| `⌃⌥P`* | Summon / dismiss the panel (fresh session each time) |
| `↩` | Polish the draft → result streams in → **auto-pastes back** into the originating app |
| type + `↩` | **Add** mode (default): polish the new content and merge it in; **Edit** mode (`⇥` toggles): revise per your feedback — both replace the previous paste in place |
| empty `↩` | Done — close the panel (re-pastes if you rolled back to an older version) |
| `⌘[` / `⌘]` | Walk versions · `⌘D` diff view · `⌘N` restart |
| `Esc` | Stop dictation → cancel request → close (layered) |

\* the default; record any combo in Settings by pressing it directly (hotkeys apply on save, held modifiers are echoed live while recording).

While waiting, your draft **floats and transmutes character-by-character into the result** as it streams — the pace is the model's real generation speed. Enable **Idle prefetch** (Settings → Behavior) and a round is silently pre-run while you pause typing: press Enter without further edits and the result appears instantly (bolt icon in the status bar; extra token cost noted in Settings).

Also in the panel: quick chips (Shorter / Formal / Casual / Expand), in-place editing of the result text, voice dictation, a 中/EN switch (UI + output language, the whole app follows), a sun/moon theme toggle, and a top-right gear for Settings.

## Scenarios

- **Built-ins** — Polish (default), Slack English, Formal, Concise. Their full prompts are **visible and editable** in Settings (your edits become an override; restore the default anytime)
- **Your own** — create any number of named scenarios, each with independent Chinese/English prompts and names; or just **describe the scenario in one sentence and let AI generate it** (panel scenario menu → "Describe a new scenario…", or Settings → "AI generate"). The multi-round protocol is appended locally, so generated scenarios can never break refinement
- **App-aware** — map bundle IDs to scenarios: summoning from Slack auto-selects Slack English
- **Glossary** — pin translations (`term=translation`) or protect terms verbatim, enforced in every scenario

## Refine in place (no panel)

- `⌃⌥R` — refine the current selection and replace it in place (also in the menu bar and the right-click **Services** menu)
- `⌃⌥A` — select-all + refine the focused field
- If you switch windows while the request is running, the result stays on the clipboard instead of pasting blindly
- The replaced original is saved to **History** (menu bar, last 20 records, persists across restarts); **Restore last replacement** undoes the most recent one

While processing, a toast follows your cursor with live progress; on failure your original text is never modified, and your previous clipboard content (including images) is always restored.

## More

- Dark glass / light glass themes; panel resizable by dragging edges, with Small / Medium / Large presets in Settings
- Menu bar menu, HUD, and Settings all follow the 中/EN language switch
- Monthly token usage stats · launch at login · update checker
- [`FEATURES.md`](FEATURES.md) is the full feature checklist used for regression testing

## Privacy

Your text goes only to the endpoint **you** configure — point it at local Ollama (`http://localhost:11434/v1`) or an internal proxy and nothing leaves your network. The API key stays on your machine (config file, `0600`). No analytics, no third-party services.
