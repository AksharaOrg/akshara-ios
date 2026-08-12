# Akshara for iOS

Native iOS host app and system-wide Custom Keyboard Extension. The keyboard processes transliteration entirely on-device and does not request Full Access.

## Open and test

Open `AksharaKeyboard.xcodeproj` with Xcode 16 or later, select your Development Team for both targets, connect your iPhone, then Run the **Akshara** scheme.

On the phone, enable it at **Settings → General → Keyboard → Keyboards → Add New Keyboard → Akshara**. Hold the globe key in any editable text field to select it.

The initial implementation supports Smart Phonetic typing. It includes local marked-text preview and commit-on-space/return behavior. Porting the full SLS/Wijesekara compositor and native interaction refinements are tracked as the next work.
