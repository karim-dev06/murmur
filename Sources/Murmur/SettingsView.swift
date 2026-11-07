import AVFoundation
import Combine
import FoundationModels
import ServiceManagement
import Speech
import SwiftUI

struct SettingsView: View {
    @AppStorage(Pref.locale) private var locale = "en-US"
    @AppStorage(Pref.cleanup) private var cleanup = true
    @AppStorage(Pref.trigger) private var trigger = "fn"
    @AppStorage(Pref.vocabulary) private var vocabulary = ""
    @AppStorage(Pref.sounds) private var sounds = false
    @AppStorage(Pref.shortcuts) private var savedShortcuts = "[]"
    @State private var shortcuts = Shortcuts.all

    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var trusted = AXIsProcessTrusted()
    @State private var globeOK = Permissions.globeKeyDoesNothing
    @State private var wisprRunning = Permissions.wisprFlow != nil
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var locales: [Locale] = []
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let intelligence = SystemLanguageModel.default.isAvailable
    private static let phraseWidth: CGFloat = 170

    var body: some View {
        Form {
            Section("Setup") {
                check("Microphone", ok: mic == .authorized) {
                    if mic == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } } else { Permissions.open(Permissions.microphoneURL) }
                }
                check("Accessibility, so Murmur can type for you", ok: trusted) { Permissions.open(Permissions.accessibilityURL) }
                if trigger == "fn" {
                    check("Keyboard: “Press 🌐 key to” set to Do Nothing", ok: globeOK) { Permissions.open(Permissions.keyboardURL) }
                }
                if wisprRunning {
                    HStack {
                        Label("Wispr Flow is running and also uses fn", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Quit it") { Permissions.wisprFlow?.terminate() }
                    }
                }
            }

            Section {
                Picker("Talk key", selection: $trigger) {
                    Text("Hold fn (🌐)").tag("fn")
                    Text("Hold right Option").tag("rightOption")
                }
            } footer: {
                Text("Hold to talk, let go to type. Double-tap for hands-free, tap again to stop. Esc cancels. ⌥⌘V types the last one again.")
            }

            Section {
                Picker("Accent", selection: $locale) {
                    ForEach(locales, id: \.self) { l in Text(name(l)).tag(l.identifier(.bcp47)) }
                }
            } header: {
                Text("Speech")
            } footer: {
                Text("Uses Apple's speech recognition, on this Mac. Pick the English closest to how you speak.")
            }

            Section {
                Toggle("Tidy up with Apple Intelligence", isOn: $cleanup)
                    .disabled(!intelligence)
            } footer: {
                Text(!intelligence ? "Apple Intelligence is off on this Mac, so Murmur types exactly what you said."
                     : cleanup ? "Removes ums, repeats and self-corrections, and fixes punctuation. Your words stay yours."
                     : "Types exactly what you said.")
            }

            Section {
                TextEditor(text: $vocabulary)
                    .font(.body)
                    .frame(minHeight: 70)
            } header: {
                Text("Your words")
            } footer: {
                Text("Names and terms to spell right, one per line. For example: Kubernetes")
            }

            Section {
                if shortcuts.isEmpty {
                    Text("No shortcuts yet. Add one for each email or address you type often.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Text("When I say").frame(width: Self.phraseWidth, alignment: .leading)
                        Color.clear.frame(width: 14)
                        Text("Murmur types")
                        Spacer()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach($shortcuts) { $shortcut in
                        HStack(alignment: .top, spacing: 8) {
                            TextField("", text: $shortcut.phrase, prompt: Text("add my office email"))
                                .frame(width: Self.phraseWidth)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                                .padding(.top, 4)
                            TextField("", text: $shortcut.text, prompt: Text("you@company.com"), axis: .vertical)
                                .lineLimit(1 ... 5)
                            Button {
                                shortcuts.removeAll { $0.id == shortcut.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this shortcut")
                            .padding(.top, 3)
                        }
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    }
                }
                Button {
                    shortcuts.append(Shortcut(phrase: "", text: ""))
                } label: {
                    Label("Add shortcut", systemImage: "plus")
                }
            } header: {
                Text("Voice shortcuts")
            } footer: {
                Text("Say the phrase on the left and Murmur types the text on the right, on its own or inside a sentence. Pick phrases you wouldn't say by accident. For an address on several lines, paste it in.")
            }

            Section {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                Toggle("Sound when listening starts", isOn: $sounds)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 660)
        .task {
            let all = await SpeechTranscriber.supportedLocales
            locales = all.filter { $0.language.languageCode?.identifier == "en" }.sorted { name($0) < name($1) }
        }
        .onChange(of: shortcuts) { savedShortcuts = Shortcuts.encode(shortcuts) }
        .onReceive(tick) { _ in
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
            trusted = AXIsProcessTrusted()
            globeOK = Permissions.globeKeyDoesNothing
            wisprRunning = Permissions.wisprFlow != nil
        }
    }

    private func check(_ title: String, ok: Bool, fix: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title)
            Spacer()
            if !ok { Button("Fix", action: fix) }
        }
    }

    private func name(_ l: Locale) -> String {
        Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}
