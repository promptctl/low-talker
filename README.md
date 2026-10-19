<img align="right" src="docs/images/low-talker.svg" alt="A man in a ruffled shirt pressing a hand to his forehead, level bars pulsing beside him, and the name LOW TALKER" width="300">

# LowTalker

Hold a key, speak, release, and your words appear at the cursor. LowTalker is push-to-talk dictation for macOS that runs entirely on your Mac: the speech model lives inside the app, and your audio never leaves the machine.

LowTalker is in alpha. The latest build is on the [releases page](https://github.com/promptctl/low-talker/releases).

## Using it

LowTalker lives in the menu bar and has no window to keep open. The default chord is Right Option.

- **Hold** the chord while you speak and release it to finish. Words are typed as the model confirms them, so most of the text is already in place when you let go.
- **Tap** the chord (a press under a quarter of a second) to start listening, and tap again to stop.
- **Modes** pair a chord with a vocabulary of your own words and names. The vocabulary is handed to the model before you speak, so it spells "Brynleigh Fryslie" where it otherwise hears "Brynley Frisley".

The text goes in wherever the cursor is, in any app that accepts typing: TextEdit, Safari, Chrome, iTerm2 and VS Code have all been checked. It is not inserted into password fields or other fields that macOS protects with Secure Event Input.

When a dictation, the model, the hotkey, the microphone, the server or a config save fails, the menu says why. Click that line to copy its full text.

## Install

You need macOS 15 or later.

1. Install it with Homebrew, `brew install --cask promptctl/tap/low-talker`, or download `LowTalker-offline.pkg` from the [latest release](https://github.com/promptctl/low-talker/releases) and open it. The package is Developer ID signed and notarized.
2. Open LowTalker. It walks you through the two things it needs: permission to use the microphone, and switching on its input method.
3. Wait for the first launch to finish preparing the model. The menu bar icon is an hourglass until then. macOS compiles the model for your Neural Engine once, which took 1.5 to 4.5 minutes in our measurements, and launches after that take a few seconds, until an app update or a macOS update makes it compile again.

The release also offers `LowTalker-network.pkg`. It is identical except that it may accept connections, for the transcription server below. Install only one: they replace each other.

## Private by construction

- **Local.** The Whisper model ships inside the app bundle. LowTalker downloads nothing.
- **Sandboxed.** The offline build carries no network entitlement, so macOS refuses any connection it tries to make. That is a property of the build, not a promise. `scripts/wire-check` verifies it by watching both processes during a dictation.
- **No special access.** Words reach the cursor through LowTalker's own macOS input method, the way a Japanese or Chinese input method commits text. It needs no Accessibility or Input Monitoring grant and no administrator approval, so it works on a managed work Mac. It never posts keystrokes and never touches the clipboard.

## Speed

On an M2 Max with the default model, the transcript lands 0.3 to 0.6 seconds after release when you stop speaking before you let go of the key, and 0.6 to 0.9 seconds when speech runs right up to the release. The [engineering notes](docs/engineering.md#the-latency-harness) hold the full table, the models compared, and what the bench measures. The target is under 300 ms for a short utterance. Whisper's encoder puts a floor of about 0.4 seconds under any pass, so reaching it takes a different engine; Parakeet is planned as the second one.

<br clear="right">

## Configuration

One TOML file, read at launch and again on every save, so edits apply without a relaunch. It lives at `~/Library/Containers/ai.promptctl.low-talker/Data/.config/low-talker/config.toml`. With no file, LowTalker dictates on Right Option with the default model.

```toml
model = "base.en"

[[modes]]
name = "dictation"
chord = { modifiers = ["rightOption"] }

[[modes]]
name = "notes"
chord = { modifiers = ["leftCommand", "leftShift"] }
vocabulary = ["Kubernetes", "Anthropic"]
```

A chord is one or more modifier keys, including Fn (`"function"`). A file LowTalker cannot read is never silently replaced by the defaults: the menu names the problem, and a bad save leaves the app on the last config that worked. The [engineering notes](docs/engineering.md#the-config-file) cover the rest: the microphone's resting state and the options for the server.

## Transcription server

The network build can share the model it already holds. Turn on **Serve Transcription** in the menu and it answers OpenAI's `POST /v1/audio/transcriptions` and its Realtime transcription socket on port 8610, on loopback unless you configure an interface and a token. Any client that speaks the OpenAI speech-to-text API, such as a Pipecat pipeline, can point at it. It is off until you switch it on.

## Building from source

You need Xcode 16 or later, plus `xcodegen` and `jq` from Homebrew.

```sh
make app                # builds LowTalker.app and its input method
make test               # the test suite and the license gates
make install            # builds the installer package and installs it
```

Signing, notarization, the release process and the installer are documented in the [engineering notes](docs/engineering.md). [PROJECT.md](PROJECT.md) explains the design decisions behind the app.
