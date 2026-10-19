# low-talker

Local push-to-talk dictation for macOS.

## The atom

Hold a key, speak, release, and the words appear where the cursor is. That is the entire product for milestone 1, and it stays the thing every later feature is judged against. If a feature makes that loop slower or less trustworthy, the feature is wrong, not the loop.

Everything runs on the machine. Audio never leaves it. The app lives in the menu bar and has no window you need to look at.

## The one design rule

The chord you hold picks the mode. Your voice supplies the words.

Each mode seeds the model with its own vocabulary, your own words and names, so the recognizer is told what to expect before you speak. The biasing is measured: told three names, the default model spells all three where it got all three wrong unaided, at about a tenth of a second more per pass, with the other fixtures unchanged (docs/engineering.md, "The latency harness").

## The pipeline

Every invocation flows through the same two types:

- **Context** is everything known before you speak: which chord was held, whether it was a tap or a hold, and the frontmost app's bundle id.
- **Transcript** is what the engine produced, with word timings and confidence attached. It is never a bare string.

What becomes of a transcript is one thing: its text is inserted at the cursor of the app in front.

Configuration is one TOML file, `.config/low-talker/config.toml` in the app's sandbox container: chords to modes, and each mode's vocabulary.

## Decisions already made

**Native Swift, not a web shell.** Latency and the text input system both need direct access to the OS, and Electron or Tauri would put a bridge in the hottest path.

**The engine sits behind a `Transcriber` protocol, and WhisperKit goes in first.** It runs Whisper on the Neural Engine, streams, and is Swift. NVIDIA Parakeet via FluidAudio goes in second, and it is expected to win for English push-to-talk on both latency and accuracy. Apple's SpeechAnalyzer, present on macOS 26, is the zero-dependency third option. The protocol boundary exists so that switching is a config change.

**The words reach the cursor through the app's own input method, and nothing else.** The input method is this app's own macOS input source, kept selected; it commits the words at the cursor through the text input system, the way a Japanese or Chinese input method commits a candidate — the client that terminals, browsers, Electron apps and native text views all implement — so nothing is posted as a key, the pasteboard is never touched, and no administrator is asked. That is what a managed work Mac can run, where macOS asks for an administrator to grant Accessibility or Input Monitoring. A virtual keyboard driven through a driver extension and a root helper was the first delivery and then an alternative, and was removed on 2026-09-27 along with the event-tap and registered-hot-key hearings, leaving the input method the only path. Two other grant-free routes were weighed and ranked below the input method, and neither is planned: a pasteboard promise the user resolves with their own ⌘V, which clipboard managers defeat by reading the promise early, and a macOS Service acting as the stop, which reaches only the apps that carry text Services.

**Latency is designed for, not tuned for.** The microphone stays open into a ring buffer so key-down costs nothing. The model stays resident. Decoding streams during the hold so key-up only finalizes the last chunk. Target: under 300 ms from key-up to inserted text for a short utterance. Measured against that target with WhisperKit large-v3-turbo on an M2 Max (docs/engineering.md, "The latency harness"): batch decodes land 0.6 to 0.9 s after key-up; streaming lands 0.3 to 0.6 s when the speaker stops before releasing the key and 0.6 to 0.9 s when speech runs to key-up, with the same words either way, except when a pass falls into temperature-fallback retries, which took one recording's streamed median to 3.7 s. It cannot go lower on this engine, because Whisper's encoder costs 0.39 s per pass over a window padded to 30 s whatever the tail's length, so the target needs an engine whose encoder is off the key-up path. That is the case the Parakeet engine has to make.

**The hotkey is heard through the same input method.** While it is the selected source, macOS hands it every change of the modifier keys and it tells the app, so the chord is modifier keys alone — Right Option by default — and needs no grant of the app's. A press is not heard while another input source is selected, where the app in front takes no typing, or under Secure Event Input, and the menu says so when that is where things stand. A press shorter than about 250 ms is a tap and toggles listening, and anything longer is push-to-talk. A press during which another key is typed was that key's modifier, not dictation, and ends as the chord comes up.

**It needs the microphone and its own input method switched on, and nothing an administrator approves.** Switching the input method on is a macOS dialog naming the app, which the person allows. The app is Developer ID signed, notarized, and distributed outside the App Store.

**Feedback is minimal.** The menu bar icon shows state. A small HUD shows listening state and partial text while you speak. Nothing else appears unless something went wrong.

## Shape of the repo

- `LowTalkerCore` is a SwiftPM library with no AppKit UI: audio capture, the `Transcriber` protocol and its engines, and config parsing. It is unit-tested against wav fixtures.
- `LowTalker.app` is the menu bar agent (`LSUIElement`), generated with XcodeGen so the project file stays diffable.

## Build order

1. **Dictation end to end.** Hotkey, audio, WhisperKit, the input method.
2. **Parakeet.** Second engine behind the protocol.

## Open questions

Which Whisper model to default to is answered. The latency harness (the bench) measured large-v3-turbo, the distilled models, small.en, and base.en over the same twelve fixtures on an M2 Max, and the default is large-v3-turbo in the whisperkit `_turbo` variant: it heard the same words as the plain variant on every fixture while decoding 25 to 30 percent sooner, and the distilled models mishear proper nouns, only their turbo variant being faster. The numbers are in docs/engineering.md under "The latency harness". Whether tap-to-toggle needs voice activity detection to auto-stop, or whether a second tap is enough, is still open, and gets answered by using milestone 1, not by deciding now.
