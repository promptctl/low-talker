<!-- BEGIN LIT INTEGRATION -->
## lit Agent-Native Workflow

This repository uses `lit` for agent-native issue tracking.

Start by running `lit quickstart` to load the workflow instructions. It prints how tickets are found, created, updated, and closed here, so running it first means the rest of your work follows the conventions this repo expects. It's a quick, read-only command — no need to check in before running it.

<!-- END LIT INTEGRATION -->

## Logging out or restarting is never a requirement

No change, install, upgrade, or verification may require logging out and back in, or restarting — on this Mac, on a test Mac, or on a user's Mac. Never ask for one, never write one into a handoff, ticket, doc, or installer, and never count on one that happens anyway.

Done correctly, nothing here needs one. If a step seems to need a logout, we have broken a macOS rule: entitlements, input method registration or placement, or Info.plist / package manifest configuration. Fix that violation. A check that only passes after a logout or restart has failed.

## The input method follows the IMK guidelines

Brandon adopted vChewing's "macOS Input Method Development Guidelines for 2026" on 2026-09-29. They bind every change to code the input method process runs (`Sources/lowtalker-inputmethod` and every library it links, directly or not: today `InputMethod`, `Insertion`, `Identity`, `DarwinCalls`) and to the input method targets in `project.yml`:

1. **Connection name.** `InputMethodConnectionName` is the input method's bundle identifier plus `_Connection`, and no other string. `AppIdentity.inputMethodConnectionName` derives it.
2. **Always sandboxed.** The sandbox is what stops a process that is handed the keyboard from reaching anything else. Each entitlement must name the failure that needed it. The guide's sample list (network client, user-selected files, bookmarks) belongs to vChewing, which uses those things. Copying it here grants access nothing uses. If the input method ever reads its own `UserDefaults` and the sandbox refuses the read, the guide's fix is the `shared-preference.read-only` and preferences-plist exceptions for its own identifier.
3. **Main actor.** Every `IMKInputController` callback and every call on its client runs on the main actor. The overrides are `nonisolated` and move their arguments onto the main actor through one hop: inline when already on the main thread, `DispatchQueue.main.sync` otherwise. `InputMethod` and `lowtalker-inputmethod` default to main-actor isolation (`Package.swift`). `Insertion` and `Identity` do not: the app links them too, and they make no IMK callback or client call. The insert port runs on its own queue, and reaches the main actor through `Committer`.
4. **Client calls.** Any client call may be dispatched async onto the main actor, except `insertText` and `setMarkedText`, which run on it synchronously. No client call runs on another thread.
5. **Controller lifetime.** The guide says IMKServer orphans a controller, and leaks the client connection it holds, at every Caps Lock toggle. On macOS 15.0.1 (studious, low-imk-rules-w3g.41q), 5,000 toggles and 500 reactivations left the live controllers and connections where they started. macOS 26 is not measured yet. `sudo heap <pid>` counts `DictationInputController` and `NSXPCConnection` without a debugger. A toggle is Caps Lock held 200 ms: `vhid press` is too short to toggle it. Where the counts climb with toggles, the input method prunes its orphaned controllers and tears down their connections.
6. **Logic lives in libraries.** A breakpoint in a running input method freezes every app that has touched it, and then the desktop. Never attach a debugger to it. Put behavior in the `InputMethod` library, test it there against mock clients, and read the running process through the unified log.
7. **Memory ceiling.** At each `activateServer` the input method reads its own footprint. Over 1024 MB it tells the person, through the app's Hotkey line, and exits (`Notices`).
8. **No windows.** Every NSWindow costs memory macOS 26 never reclaims. The input method has none. If it ever needs one, one NSPanel serves every purpose.
9. **No IMKCandidates.**

Rule 5 waits on macOS 26. Epic `low-imk-rules-w3g` holds its ticket, and the ticket that brings it into line deletes this line. Until then, treat the code that breaks a rule as an exception to fix. Do not copy it as precedent.
