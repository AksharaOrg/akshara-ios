import SwiftUI
import UIKit

private enum AksharaLinks {
    static let github = URL(string: "https://github.com/AksharaOrg/akshara-ios")!
    static let website = URL(string: "https://akshara.org.lk")!
    static let appleKeyboardGuide = URL(string: "https://support.apple.com/guide/iphone/add-or-change-keyboards-iph73b71eb/ios")!
}

struct OnboardingView: View {
    @State private var mode = KeyboardPreferences.selectedMode()

    var body: some View {
        NavigationStack {
            Form {
                Section("Installed Keyboard Layout") {
                    Picker("Layout", selection: $mode) {
                        ForEach(SinhalaEngine.Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                    Text("This choice is used by the system keyboard the next time it appears.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Akshara Keyboard") {
                    Text("A private, on-device Sinhala keyboard.")
                    Text("To enable: Settings → General → Keyboard → Keyboards → Add New Keyboard → Akshara.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Apple: Add a third-party keyboard", destination: AksharaLinks.appleKeyboardGuide)
                }

                Section {
                    NavigationLink("Keyboard Settings") {
                        KeyboardSettingsView()
                    }
                }

                Section {
                    Link("Visit Website", destination: AksharaLinks.website)
                    Link("View on GitHub", destination: AksharaLinks.github)
                    Text("© 2026 Lahiru Himesh Madusanka · MIT License")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                
                Section("Keyboard Preview") {
                    VStack(spacing: 0) {
                        TextField("Type here...", text: .constant(""))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                            .opacity(0.7)
                            .padding([.horizontal, .top])
                        // Simulated keyboard area
                        Color.gray.opacity(0.25)
                            .frame(height: 260)
                            .overlay(Label("Simulated Keyboard", systemImage: "keyboard.fill").font(.footnote).foregroundStyle(.secondary), alignment: .top)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Akshara")
            .onChange(of: mode) { KeyboardPreferences.setSelectedMode($0) }
        }
    }
}

private struct KeyboardSettingsView: View {
    @State private var emojiEnabled = KeyboardPreferences.emojiEnabled()

    var body: some View {
        Form {
            Section("Keyboard Features") {
                Toggle("Emoji", isOn: $emojiEnabled)
                NavigationLink("Haptics") {
                    HapticsSettingsView()
                }
                Toggle("Suggestions", isOn: .constant(false))
                    .disabled(true)
                Text("Suggestions are temporarily disabled while the full Sinhala prediction dictionary is added.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Keyboard Settings")
        .onChange(of: emojiEnabled) { KeyboardPreferences.setEmojiEnabled($0) }
    }
}

private struct HapticsSettingsView: View {
    @State private var hapticsEnabled = KeyboardPreferences.hapticsEnabled()
    @State private var fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()

    var body: some View {
        Form {
            Section("Haptics") {
                Toggle("Key Haptics", isOn: $hapticsEnabled)
                    .disabled(!fullAccessConfirmed)
                Text(fullAccessConfirmed
                    ? "Light haptic feedback plays when you touch a key."
                    : "Full Access must be enabled before key haptics can be used.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard Full Access") {
                Label(
                    fullAccessConfirmed ? "Full Access confirmed" : "Full Access required",
                    systemImage: fullAccessConfirmed ? "checkmark.circle.fill" : "lock.fill"
                )
                .foregroundStyle(fullAccessConfirmed ? .green : .secondary)
                Text("Settings → General → Keyboard → Keyboards → Akshara → Allow Full Access. Then open the Akshara keyboard once and return here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Open Akshara Settings") {
                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(settingsURL)
                }
            }
        }
        .navigationTitle("Haptics")
        .onChange(of: hapticsEnabled) { KeyboardPreferences.setHapticsEnabled($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            fullAccessConfirmed = KeyboardPreferences.fullAccessConfirmed()
        }
    }
}

#Preview {
    NavigationStack { OnboardingView() }
}
