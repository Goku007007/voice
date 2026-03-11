# voice

`voice` is a macOS dictation utility with a global hotkey and cross-app text insertion.

## What it does

- Starts/stops dictation with `Option + Space`.
- Supports both `Toggle` and `Push-to-Talk` hotkey behavior.
- Streams speech recognition from your microphone.
- Includes selectable transcription profiles (`Apple Automatic` and `Apple On-Device Preferred`).
- Cleans transcripts with configurable options (filler removal, capitalization, punctuation).
- Inserts dictated text into the active app, with automatic clipboard fallback when direct paste is unavailable.
- Shows a floating status panel (`Listening`, `Processing`, `Inserted`).
- Runs as a menu bar utility.
- Includes a lightweight settings window (`Settings...` from the menu bar).

## Build

```bash
swift build
```

## Run

```bash
swift run
```

For stable macOS permission prompts (Microphone/Speech/Accessibility), run the packaged app instead of `swift run`:

```bash
open dist/voice.app
```

## Permissions (required)

- Microphone
- Speech Recognition
- Dictation enabled (`System Settings > Keyboard > Dictation`)
- Accessibility (for inserting text into other apps)

You can request permissions from the menu bar items after launch (`Grant Accessibility Access`, `Re-check Accessibility Status`).

## Insertion Troubleshooting (TCC / Environment)

If synthetic paste/typing does not reach other apps, verify environment state before changing code:

1. Quit `voice`.
2. Ensure there is only one installed copy of `voice.app` (remove old copies from `/Applications` and prior test folders).
3. In `System Settings > Privacy & Security > Accessibility`, remove old `voice` entries.
4. Relaunch one stable app copy (for example `dist/voice.app`) and re-grant Accessibility.
5. Test insertion in `Notes` or `TextEdit` first.

Use menu actions for diagnostics:

- `Log Environment Diagnostics`
- `Run Notes/TextEdit Insertion Probe`
- `Copy TCC Log Command`
- `Re-check Accessibility Status`

TCC log stream command format:

```bash
log stream --debug --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "ai.gokul.voice"'
```

If running local/dev builds and events are still blocked, also check:

- `System Settings > Privacy & Security > Developer Tools`

## Fallback behavior

- If insertion mode is `Clipboard Only`, dictated text is copied to clipboard by design.
- If insertion mode is `Direct Paste` but Accessibility is missing or paste injection fails, `voice` automatically copies text to clipboard and shows a clear status message.

## Phase 1 controls

- `Settings...` -> `Transcription profile`:
  - `Apple Speech (Automatic)`
  - `Apple Speech (On-Device Preferred)`
- `Settings...` -> `Hotkey behavior`:
  - `Toggle (Press Once)`
  - `Push-to-Talk (Hold)`

## Logs

- App logs are written to:
  - `~/Library/Logs/voice/voice.log`
- You can open the logs folder from the menu bar:
  - `Open Logs Folder`

## Package as a `.app`

```bash
./scripts/package-app.sh
```

This creates `dist/voice.app`.

## Notes

- `voice` currently uses Apple's Speech framework with automatic or on-device-preferred recognition profiles.
- If accessibility permission is missing, dictation still works and output falls back to clipboard.
- This is an MVP foundation intended for further hardening (settings UI, per-app privacy controls, local/offline mode, signed distribution).
