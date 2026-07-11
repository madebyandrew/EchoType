# Setting up EchoType

Thanks for trying this out! It's a local dictation app — hold a key, talk, it
types what you said. Nothing is sent over the network.

## 1. Install Homebrew (if you don't have it)

Open **Terminal** and paste:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## 2. Install whisper-cpp

```sh
brew install whisper-cpp
```

This gives EchoType the speech-to-text engine it needs to run.

## 3. Install the app

- Open `EchoType.dmg`
- Drag **EchoType** into the **Applications** folder shortcut in the same window

## 4. First launch (macOS will complain — that's expected)

This build isn't notarized by Apple yet, so macOS blocks it by default. To open it anyway:

- **Right-click** (or Control-click) `EchoType.app` in Applications → choose **Open**
- Click **Open Anyway** in the dialog that appears

(You only need to do this once.)

## 5. Grant two permissions

- **Accessibility** — System Settings → Privacy & Security → Accessibility →
  turn on **EchoType**. (Needed so it can hear your push-to-talk key and type
  into other apps.) The menu bar icon shows a warning until this is granted.
- **Microphone** — you'll get a normal popup the first time you record; click **Allow**.

## 6. Use it

- Hold **Right ⌥ (Option)**, speak, let go — your words appear wherever your
  cursor is.
- Click the menu bar icon to change the key, tweak settings, or see what's happening.

## Something not working?

- **Hotkey doesn't respond** → double check Accessibility is toggled on for EchoType.
- **"whisper-cli not found" or similar** → make sure step 2 finished (`brew install whisper-cpp`) without errors.
- Anything else — just message me.
