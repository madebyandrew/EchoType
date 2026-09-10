# EchoType 🎙️

**Private, fully-local push-to-talk dictation for macOS.** Hold a key anywhere,
speak, release — your words appear at the cursor in whatever app you're using.

**[echotype website & download →](https://madebyandrew.github.io/EchoType/)**

A free, open-source alternative to Wispr Flow with one crucial difference:
**everything runs on your Mac.** Speech is transcribed on-device by
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) (Metal-accelerated on
Apple Silicon). No cloud, no account, no subscription, no screenshots of your
screen, no telemetry. The app makes **zero network calls**.

## How it works

The same pipeline as commercial dictation apps, minus the cloud:

```
global event tap ──▶ mic capture ──▶ local Whisper ASR ──▶ cleanup ──▶ inject at cursor
 (CGEventTap,        (AVAudioEngine,   (whisper.cpp +       (regex, or   (synthetic key
  any key you         16 kHz mono)      ggml-base.en,        a local     events, or ⌘V
  assign)                               Metal on GPU)        LLM)        paste mode)
```

The whole app is a handful of small, readable Swift files in [src/](src/) — no
frameworks beyond Apple's own.

## Requirements

- Apple Silicon Mac (M1 or later), macOS 13 (Ventura) or newer
- **Nothing else.** The whisper.cpp speech engine (`whisper-cli` /
  `whisper-server` and their libraries) and the `ggml-base.en` model (~148 MB)
  are **bundled inside the app**. No Homebrew, no separate download.
- *(Optional)* [Ollama](https://ollama.com) — only if you want the AI cleanup /
  writing styles / "rewrite selection" features. Dictation works fully without it.

## Install

### Option A — one command (recommended)

Downloads the latest release, moves it to `/Applications`, clears the quarantine
flag so macOS opens it without the "unverified developer" prompt, and launches
it:

```sh
curl -fsSL https://raw.githubusercontent.com/madebyandrew/EchoType/main/install.sh | bash
```

### Option B — download the app

1. Download **[EchoType.zip](https://github.com/madebyandrew/EchoType/releases/latest/download/EchoType.zip)**
   from the [latest release](https://github.com/madebyandrew/EchoType/releases/latest).
2. Unzip it and drag **EchoType.app** to your **Applications** folder.
3. **Right-click the app → Open → Open.** macOS asks once because EchoType is
   distributed outside the App Store and isn't notarized; after the first open it
   launches normally. (See [First launch & Gatekeeper](#1-launch-it) if the
   dialog only offers *Done* / *Move to Trash*.)
4. Grant two permissions when asked — see [Running EchoType](#running-echotype).

### Option C — build from source

```sh
git clone https://github.com/madebyandrew/EchoType.git
cd EchoType
brew install whisper-cpp          # build machine only — gets bundled into the .app
curl -L -o models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
./build.sh
open EchoType.app
```

`build.sh` compiles `src/*.swift`, bundles the model, runs
[`vendor-whisper.sh`](vendor-whisper.sh) to copy the whisper.cpp binaries + their
dylibs into `EchoType.app/Contents/Resources/whisper/` (install names rewritten to
`@rpath` so they're relocatable), and code-signs the bundle.

### Cutting a release (maintainers)

- **`./notarize.sh`** — Developer ID–signed, Apple-notarized, stapled
  `EchoType.zip`. Downloads open with a plain double-click, no Gatekeeper
  warning. One-time setup (a Developer ID certificate + `notarytool
  store-credentials`) is documented at the top of the script.
- **`./release.sh`** — ad-hoc `EchoType.zip` (fallback until notarization is set
  up). The [one-command installer](#option-a--one-command-recommended) opens it
  cleanly; a manual download needs a one-time *Open Anyway* in System Settings.

Then `gh release create vX.Y.Z EchoType.zip …`. The website and installer both
pull `releases/latest/download/EchoType.zip`, so they pick up new releases
automatically.

---

## Running EchoType

### 1. Launch it

Open **EchoType** from Applications (or Spotlight, or `open -a EchoType`).

- **First launch from a manual download** is blocked by Gatekeeper ("Apple could
  not verify EchoType is free of malware…"). EchoType is a free open-source app
  that isn't notarized by Apple, so:
  - **First try:** right-click (or Control-click) the app in Finder → **Open** →
    **Open**.
  - **On macOS Sequoia (15)** the right-click dialog often only shows *Done* /
    *Move to Trash*. Click **Done**, then open **System Settings → Privacy &
    Security**, scroll to the bottom, and click **Open Anyway** next to
    "EchoType was blocked". Enter your password, then **Open**.
  - **Or, in Terminal**, clear the quarantine flag and just open it:
    ```sh
    xattr -dr com.apple.quarantine /Applications/EchoType.app
    open /Applications/EchoType.app
    ```
  You only do this once. The [one-command installer](#option-a--one-command-recommended)
  clears the flag for you, so it never shows this dialog.
- EchoType is a **menu bar app** — it has no Dock icon. Look for the EchoType
  icon in your menu bar, near the clock.
- The main window opens automatically the first time. Close it any time; the app
  keeps running in the menu bar. Reopen it from the menu bar icon → **Open
  EchoType**.

### 2. Grant two permissions (one time)

EchoType needs exactly two macOS permissions and nothing else. It prompts for
both on first launch:

| Permission | Why | Where to grant it |
|---|---|---|
| **Accessibility** | To detect your push-to-talk key anywhere, and to type text into other apps | System Settings → Privacy & Security → **Accessibility** → turn on **EchoType** |
| **Microphone** | To hear you while the key is held | Approve the system prompt the first time you record (or System Settings → Privacy & Security → **Microphone**) |

The menu bar icon shows a **⚠︎** until Accessibility is granted. Once you flip
the switch it **starts working immediately — no relaunch needed**.

> If the Accessibility toggle won't stick (common with ad-hoc-signed builds after
> a rebuild), clear the stale grant and re-add it:
> ```sh
> tccutil reset Accessibility com.echotype.app
> ```
> then toggle EchoType back on.

### 3. Your first dictation

1. Click into any text field — a note, the address bar, a chat box, this is fine
   anywhere.
2. **Press and hold Right ⌥ (Option)** — the default key.
3. The menu bar icon turns into a red **●** and (if enabled) a live preview pill
   appears near the bottom of the screen. **Speak normally.**
4. **Release the key.** The icon shows **…** while Whisper transcribes on your
   GPU (typically under a second for a sentence).
5. Your text types itself in at the cursor.

That's the whole loop. No wake word, no "start/stop", no menus.

### 4. The menu bar menu

Click the EchoType icon for:

- **Status line** — tells you the current push-to-talk key and state.
- **Style: …** — quick-switch the active writing style (Raw, Clean up, Email,
  Slack, Notes, Markdown, or your own).
- **Open EchoType** — the main window.
- **Quit EchoType** — fully exits.

### 5. The main window

| Tab | What it's for |
|---|---|
| **Home** | Live status of the speech engine and (optional) AI, and your current shortcut. |
| **History** | Every transcript, searchable. Stored locally in a SQLite file; delete any entry or clear all. |
| **Styles** | The writing modes. Edit the built-ins or add your own with a custom prompt and an optional spoken trigger word. |
| **Dictionary** | Names, jargon, and spellings Whisper should get right (e.g. product names, colleagues). |
| **Snippets** | Say a trigger phrase, get a block of text — "meeting notes" → your full template. |
| **Settings** | Shortcuts, local AI on/off, insertion mode, language, voice commands, filler removal, sound, theme, and a link to the raw config file. |

### 6. Rewrite / command selected text (optional, needs Ollama)

Select some text in any app and **hold Right ⌘**, then speak an instruction —
"make this more formal", "turn this into bullet points", "fix the grammar". The
selection is replaced with the result. This one feature requires the local AI
layer (below); plain dictation does not.

### 7. Optional: the local AI layer

By default EchoType gives you Whisper's transcript with light regex cleanup
(punctuation, capitalization, filler removal). Turn on **Settings → Local AI** to
also run each transcript through a small language model **running entirely on
your Mac** via [Ollama](https://ollama.com), for grammar fixes and the writing
styles (Email, Slack, Notes, …).

```sh
brew install ollama
```

EchoType launches `ollama serve` for you and pulls the default model
(`llama3.2:3b`, ~2 GB) on first use — watch progress in **Settings → Local AI →
Status**. Still zero network calls to anyone but `127.0.0.1`. If the model isn't
ready or the AI is off, EchoType silently falls back to the raw transcript, so
dictation never breaks.

### 8. Change the push-to-talk key

**Settings → Shortcuts → Dictate → Change…**, then press the key you want. Normal
keys, F-keys, and modifiers (Fn, Right ⌘, Caps Lock, …) all work. Esc cancels the
capture. Prefer press-to-start / press-to-stop over holding? Turn on **Toggle
mode** in the same section.

### 9. Start at login (optional)

**System Settings → General → Login Items → +** → add **EchoType.app**.

### 10. Quit

Menu bar icon → **Quit EchoType**. It leaves nothing running — the bundled
Whisper server and any `ollama serve` it started are shut down with it.

---

## Better accuracy or other languages (optional)

`base.en` is fast and accurate for English. For higher accuracy, download a
bigger model and set `modelPath` in `config.json` to its full path:

```sh
curl -L -o ~/Library/Application\ Support/EchoType/ggml-small.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
# then edit config.json:  "modelPath": "/Users/you/Library/Application Support/EchoType/ggml-small.en.bin"
```

For non-English, set **Settings → Transcription → Language → Auto-detect** —
EchoType switches to a multilingual model and detects the language you speak.
Drop a `ggml-small.bin` (the multilingual build) into the config folder above and
it's picked up automatically; otherwise set `multilingualModelPath` in
`config.json`.

All settings — model paths, Ollama model, ports, recording limits — live in
`~/Library/Application Support/EchoType/config.json` (**Settings → Advanced →
Open config file**).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Menu bar icon has a **⚠︎**, nothing happens on the key | Accessibility not granted. System Settings → Privacy & Security → Accessibility → turn on EchoType. If it's already on, toggle it off/on, or run `tccutil reset Accessibility com.echotype.app` and re-add it. |
| "Apple could not verify EchoType is free of malware…" (only *Done* / *Move to Trash*) | Not notarized (free app). Click Done, then **System Settings → Privacy & Security → Open Anyway**. Or run `xattr -dr com.apple.quarantine /Applications/EchoType.app`. Once only. See [First launch & Gatekeeper](#1-launch-it). |
| Recording works but no text appears | The target field must have keyboard focus. Some secure fields (passwords) reject synthetic input by design. Try **Settings → Insertion → Insert by pasting**. |
| **Settings → Engine** shows an error | The bundled `whisper-server` failed to start. Quit and reopen EchoType. If it persists, the app still transcribes via the bundled `whisper-cli` (slightly slower cold start) — check Console for `EchoType: whisper` logs. |
| Styles/rewrite do nothing | Local AI is off or Ollama isn't installed — `brew install ollama`, then check **Settings → Local AI → Status**. Plain dictation is unaffected. |
| First dictation after a fresh install pauses a few seconds | One-time model load into RAM; subsequent dictations are instant. |

## Privacy

- Audio is captured only while your push-to-talk key is held, transcribed
  locally, and the temporary WAV file is deleted immediately after.
- No network access, no analytics, no crash reporting, no accounts. Unplug your
  Wi-Fi and it works exactly the same.
- The optional AI layer talks only to `127.0.0.1` (a local Ollama). Nothing
  leaves the machine.
- Don't take my word for it — it's a few readable Swift files. Audit it.

## License

[MIT](LICENSE)
