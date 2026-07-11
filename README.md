# EchoType 🎙️

**Private, fully-local push-to-talk dictation for macOS.** Hold a key anywhere,
speak, release — your words appear at the cursor in whatever app you're using.

A free, open-source alternative to Wispr Flow with one crucial difference:
**everything runs on your Mac.** Speech is transcribed on-device by
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) (Metal-accelerated on
Apple Silicon). No cloud, no account, no subscription, no screenshots of your
screen, no telemetry. The app makes **zero network calls**.

## How it works

The same pipeline as commercial dictation apps, minus the cloud:

```
global event tap ──▶ mic capture ──▶ local Whisper ASR ──▶ cleanup ──▶ inject at cursor
 (CGEventTap,        (AVAudioEngine,   (whisper-cli +        (filler     (synthetic key
  any key you         16 kHz mono)      ggml-base.en,         removal,    events, or ⌘V
  assign)                               Metal on GPU)         trim)       paste mode)
```

The whole app is a single Swift file — [src/main.swift](src/main.swift).

## Requirements

- Apple Silicon Mac (M1 or later), macOS 13+

## Install

One command — installs Homebrew and whisper-cpp if you don't already have
them, downloads EchoType, and launches it:

```sh
curl -fsSL https://raw.githubusercontent.com/madebyandrew/EchoType/main/install.sh | bash
```

### Build from source instead

```sh
git clone https://github.com/madebyandrew/EchoType.git
cd EchoType
brew install whisper-cpp
curl -L -o models/ggml-base.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin
./build.sh
open EchoType.app
```

## First run — grant two permissions

1. **Accessibility** — System Settings → Privacy & Security → Accessibility →
   enable **EchoType**. (Needed to hear your push-to-talk key and to type
   text into other apps.) The menu bar icon shows **🎙️⚠️** until this is
   granted, then switches to **🎙️** — no relaunch needed.
2. **Microphone** — prompted the first time you record.

> **Note on rebuilding:** `./build.sh` signs the app with your Apple
> Development / Developer ID certificate when one is available. That signature's
> identity is stable across rebuilds, so macOS keeps the Accessibility grant.
> Without a certificate it falls back to ad-hoc signing, where the signature
> changes with every build and macOS invalidates the grant each time. To
> re-grant: System Settings → Accessibility → toggle EchoType back on. If the
> toggle doesn't take, run `tccutil reset Accessibility local.echotype.app`
> to clear the stale grant, then toggle it on again.

## Usage

- **Hold Right ⌥ (Option)** — the default key — speak, then release.
  🔴 while recording, ✍️ while transcribing, then the text types itself
  wherever your cursor is.
- **Assign any key:** menu bar 🎙️ → *Set Push-to-Talk Key…* → press the key
  you want. Normal keys, F-keys, and modifiers (Fn, Right ⌘, …) all work.
  Esc cancels.

### Menu options

| Option | What it does |
|---|---|
| Toggle Mode | Press once to start, again to stop (instead of holding) |
| Insert by Pasting | Uses ⌘V instead of typing — faster for long dictations; your old clipboard is restored |
| Remove Filler Words | Strips um/uh/hmm |
| Sound Feedback | Pop on start, bottle on stop |
| Open Config File | All settings live in `~/Library/Application Support/EchoType/config.json` |

## Better accuracy (optional)

`base.en` is fast and good. For higher accuracy, download a bigger model and
point `modelPath` in the config at it:

```sh
curl -L -o models/ggml-small.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
```

For languages other than English, use a multilingual model (e.g.
`ggml-small.bin`) and set `"language"` in the config.

## Start at login (optional)

System Settings → General → Login Items → add **EchoType.app**.

## Privacy

- Audio is captured only while your push-to-talk key is held, transcribed
  locally, and the temporary WAV file is deleted immediately after.
- No network access, no analytics, no crash reporting, no accounts.
- Don't take my word for it — it's one readable Swift file. Audit it.

## License

[MIT](LICENSE)
