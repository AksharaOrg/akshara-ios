# Akshara for iOS

Native iOS host app and system-wide Custom Keyboard Extension. The keyboard processes transliteration entirely on-device. It requests Full Access only to share local preferences with the containing app through its App Group; it does not transmit typed text or use the network.

## Prediction data

The bundled next-word, trigram, and sentence-start models contain aggregate
Sinhala counts derived from
[Remeinium CleanSinhalaTextCorpus](https://huggingface.co/datasets/Remeinium/CleanSinhalaTextCorpus),
by Remeinium AI and Kusal Darshana (2025), under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The source corpus is
not included; attribution details are in
`AksharaKeyboard/Resources/SinhalaNextWordModel-ATTRIBUTION.md`.

## Open and test

Open `AksharaKeyboard.xcodeproj` with Xcode 16 or later, select your Development Team for both targets, connect your iPhone, then Run the **Akshara** scheme.

On the phone, enable it at **Settings → General → Keyboard → Keyboards → Add New Keyboard → Akshara**. Hold the globe key in any editable text field to select it.

## Building with another Apple Developer account

The host app and keyboard extension share preferences through an App Group. The repository's default group, `group.lk.org.akshara.keyboard`, belongs to the original development team, so it cannot be used when signing with another Apple Developer account.

Before building locally, use a unique bundle identifier and create an App Group owned by your team (for example, `group.com.example.akshara`). Enable that same group for both the **Akshara** app target and the **AksharaKeyboard** extension target under **Signing & Capabilities → App Groups**. Then replace `group.lk.org.akshara.keyboard` with your group identifier in:

- `Akshara/Akshara.entitlements`
- `AksharaKeyboard/AksharaKeyboard.entitlements`
- `Shared/KeyboardPreferences.swift`

The group identifier must match exactly in all three places. If it does not, layout and feature settings saved in the app will not reach the keyboard extension. After changing signing or entitlements, clean the build folder, reinstall the app, and remove and re-add the keyboard in iOS Settings.

Do not commit your personal Development Team ID, bundle identifiers, provisioning profiles, or App Group identifier back to the shared repository.

The keyboard supports Wijesekara, Phonetic, and Smart Phonetic input, with local marked-text preview and commit-on-space/return behavior.
