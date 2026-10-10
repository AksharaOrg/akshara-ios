# Public release checks

## Implemented in the working tree

- Privacy manifests for app and extension: local/App Group UserDefaults; local diagnostic file timestamps in app; gesture timing uptime in extension.
- Sinhala autocorrect and learning honor prediction-disabled/structured fields, matching English.
- Setup confirmation explicitly comes from the user; Full Access is optional for basic typing.
- Clear Learned Words deletes Sinhala and English learning, invalidates caches, and serializes deletion against persistence.
- Numeric field traits select the number layer; decimal fields use the locale's separator.
- Sinhala prediction chips stay empty without an active word.

## Verification completed on 27 September 2026

- `Scripts/test_sinhala_predictions.sh` passes, including live-cache reset, pending-save cancellation, and learning after reset.
- Release archive built successfully at `/tmp/Akshara-Release-Fixes.xcarchive`; both privacy manifests and both dSYMs are present.
- Simulator build/install passed. Visual/runtime checks remain incomplete because Simulator was stuck booting.
- Physical-device discovery and USB inspection did not detect an iPhone during this run.

## Required physical-device acceptance checks — not yet verified

- iPhone X / iOS 16: fresh install, Full Access OFF, type Sinhala, Backspace, Return, globe switching.
- Full Access ON: settings propagate; all three Sinhala layouts and English work.
- Repeated Apple → Akshara → Apple switching, including supported non-secure Lock Screen reply fields. Secure/passcode fields must use Apple's keyboard.
- Type සිං and select සිංහල rapidly; every intentional tap should apply once.
- Space acceptance OFF/ON: fresh/stale candidates, one/three candidates, exact word, completion, rapid typing, all three Sinhala layouts, autocorrect ON, second Space produces period, Backspace, middle-of-word caret, selected text, disabled predictions, emoji, Space trackpad, English-for-one-word.
- No autocorrect or learning in fields with autocorrection disabled or structured input traits.
- Numeric/decimal fields and transitions back to ordinary text, including comma-decimal locale.
- Clear Learned Words while providers are warm, switch back, and restart: old personal words must not reappear from caches or delayed saves.
- iOS 17/18/26, iPad compact/full-width, portrait/landscape, dark/light, long typing sessions; inspect extension crashes and memory pressure.

## Typing performance gate — not yet verified

- Follow [Typing performance validation](Typing-Performance.md): three Release runs of at least 500 events per mode on older/current iPhones, including native and messaging-app fields.
- Verify correctness, accessibility, retained preview/label rendering, Full Access/secure-field clipboard behavior, rapid emoji search and overlapping touches.
- Record CPU, memory, first-key time and queue delays; compare host waits separately. Target 30% lower affected-scenario p95, no more than 10% regression elsewhere and 8 ms extension-owned main-thread p95. Desktop provider timings do not satisfy this gate.
- Complete this gate before TestFlight distribution of the typing optimizations.

## Submission checks — not yet performed

- Validate the final archive in Xcode Organizer / App Store Connect; a local archive build is not submission validation.
- Publish Docs/PrivacyPolicy.md at a stable public URL, then set the App Store Connect privacy-policy URL and verify the page is reachable.
- Complete App Privacy answers against actual distribution behavior, review notes explaining keyboard setup and optional Full Access, support URL, screenshots, age rating, and export compliance.
- Keep source-data redistribution permissions and attribution evidence with release records.
- Commit reviewed changes, tag the release, and retain the exact archive and both dSYMs.
