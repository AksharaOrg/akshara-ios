# Akshara for iOS

Native iOS host app and system-wide Custom Keyboard Extension. The keyboard processes transliteration entirely on-device. It requests Full Access to share local preferences with the containing app through its App Group, play haptics, and optionally read the pasteboard for Clipboard History while the keyboard is open. It does not transmit typed text or use the network.

## Prediction data

The bundled next-word, trigram, and sentence-start models contain aggregate
Sinhala counts derived from
[Remeinium CleanSinhalaTextCorpus](https://huggingface.co/datasets/Remeinium/CleanSinhalaTextCorpus),
by Remeinium AI and Kusal Darshana (2025), under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The source corpus is
not included; attribution details are in
`AksharaKeyboard/Resources/SinhalaNextWordModel-ATTRIBUTION.md`.

English completions, next-word counts, correction keys, and emoji tokens ship
in a query-only SQLite index so the keyboard does not parse and expand the
source JSON/TSV files at runtime. Regenerate it after changing either source:

```sh
python3 Scripts/build_english_prediction_db.py \
  --words AksharaKeyboard/Resources/english_wordfreq_25000.json \
  --next-words AksharaKeyboard/Resources/english_next_word_model.tsv \
  --emoji AksharaKeyboard/EmojiSearchIndex.json \
  --output AksharaKeyboard/Resources/EnglishPrediction.sqlite3
```

## Autocorrect dictionary releases

Autocorrect is a separate, opt-in, on-device verified-spelling feature. Its
runtime artifact is not a SQLite database and does not replace the frequency or
n-gram prediction models. `Scripts/SinhalaDictionary.lock` pins the exact
Akshara Dictionary revision and public export profile for a release. The
shipped lexicon is the deterministic top 8,000 ranked entries from its verified
Sinhala spellings; the selection limit is part of the lock file.

Release automation must check out that revision, build its `redistributable`
export with the upstream dictionary tooling, then compile the resulting export:

```sh
zsh Scripts/build_sinhala_autocorrect_index.sh \
  /path/to/akshara-dictionary/exports/release \
  83ba4423ca20784857563cf76ff4648411e3db76
```

The compiler rejects a different revision/profile and writes both the compact
`SinhalaAutocorrect.lexicon` bundle resource and a metadata file containing its
SHA-256, licence, attribution, and word count. Updating the lock and rebuilding
these resources is the only supported way to update the shipped dictionary; the
keyboard never downloads a dictionary at runtime.

## Open and test

Open `AksharaKeyboard.xcodeproj` with Xcode 16 or later, select your Development Team for both targets, connect your iPhone, then Run the **Akshara** scheme.

On the phone, enable it at **Settings → General → Keyboard → Keyboards → Add New Keyboard → Akshara**. Hold the globe key in any editable text field to select it.

To inspect the keyboard in a non–Liquid Glass host, run the **Classic Host** scheme (or sideload `ClassicHost.app` onto the Simulator or a device). That target sets `UIDesignRequiresCompatibility`, so iOS 26 keeps the pre-glass system tray. Set **Keyboard Chrome** to Classic if you also want Akshara’s pre-glass keys and paint; Automatic follows the OS (Liquid Glass on iOS 26) and keeps the canvas clear so the host tray shows through.

## Building with another Apple Developer account

The host app and keyboard extension share preferences through an App Group. The repository's default group, `group.lk.org.akshara.keyboard`, belongs to the original development team, so it cannot be used when signing with another Apple Developer account.

Before building locally, use a unique bundle identifier and create an App Group owned by your team (for example, `group.com.example.akshara`). Enable that same group for both the **Akshara** app target and the **AksharaKeyboard** extension target under **Signing & Capabilities → App Groups**. Then replace `group.lk.org.akshara.keyboard` with your group identifier in:

- `Akshara/Akshara.entitlements`
- `AksharaKeyboard/AksharaKeyboard.entitlements`
- `Shared/KeyboardPreferences.swift`

The group identifier must match exactly in all three places. If it does not, layout and feature settings saved in the app will not reach the keyboard extension. After changing signing or entitlements, clean the build folder, reinstall the app, and remove and re-add the keyboard in iOS Settings.

Do not commit your personal Development Team ID, bundle identifiers, provisioning profiles, or App Group identifier back to the shared repository.

## Crash and performance diagnostics

- TestFlight and App Store distributions report symbolicated crashes through Xcode Organizer and App Store Connect. Keep each release archive and its dSYMs.
- The containing app subscribes to MetricKit and retains up to 24 local crash, hang, CPU, disk-write, and performance payloads. Open **About → Diagnostics**, prepare an export, and share the generated JSON when investigating a report.
- In Xcode, use **Debug → Simulate MetricKit Payloads** while running the containing app to verify the collection and export flow. Simulated payloads contain sample data.
- Diagnostics never include typed text and are never uploaded automatically.

The keyboard supports Wijesekara, Phonetic, and Smart Phonetic input, with local marked-text preview and commit-on-space/return behavior.
