import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var memory: MemoryStore
    @ObservedObject var companion: CompanionController
    @State private var elevenLabsKeyDraft = ""

    private static let languageOptions: [(code: String, name: String)] = [
        ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("es-MX", "Español (México)"), ("es-ES", "Español (España)"),
        ("fr-FR", "Français"), ("de-DE", "Deutsch"), ("it-IT", "Italiano"), ("pt-BR", "Português (Brasil)"),
        ("hi-IN", "हिन्दी"), ("zh-CN", "中文 (简体)"), ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("ar-SA", "العربية"), ("vi-VN", "Tiếng Việt"),
    ]

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            voiceTab.tabItem { Label("Voice", systemImage: "waveform") }
            learnerTab.tabItem { Label("About me", systemImage: "graduationcap") }
            memoryTab.tabItem { Label("Memory", systemImage: "brain") }
            advancedTab.tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .padding(20)
        .frame(width: 560, height: 470)
    }

    private var generalTab: some View {
        Form {
            Section {
                Picker("Teacher model", selection: $settings.modelIdentifier) {
                    ForEach(ClaudeModelOption.all) { option in Text("\(option.displayName) — \(option.detail)").tag(option.id) }
                }
                Picker("Thinking depth", selection: $settings.reasoningEffort) {
                    Text("Quick").tag("low")
                    Text("Balanced").tag("medium")
                    Text("Deep").tag("high")
                }
                Toggle("Think before answering (slower, for hard problems)", isOn: $settings.thinksBeforeAnswering)
            } footer: {
                Text("Pointwise uses your Claude Code login. Nothing to paste in. Sonnet answers fastest; Opus explains best.").font(.caption).foregroundColor(.secondary)
            }
            Section {
            ColorPicker("Cursor color", selection: Binding(
                get: { settings.cursorColor },
                set: { settings.cursorColorHex = $0.hexString }
            ), supportsOpacity: false)
            Toggle("Always show Pointwise next to my cursor", isOn: $settings.alwaysShowsCursorBuddy)
            } footer: {
                Text("When off, Pointwise appears only while you talk to it.").font(.caption).foregroundColor(.secondary)
            }
            Section {
            Toggle("Pointwise can click and type for me (\"show me by doing it\")", isOn: $settings.actionsEnabled)
            Toggle("Do not ask before each lesson", isOn: $settings.actionsAlwaysAllowed).disabled(!settings.actionsEnabled)
            } footer: {
                Text("Pointwise never deletes, sends, buys, or posts anything for you.").font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var voiceTab: some View {
        Form {
            Toggle("Speak answers aloud", isOn: $settings.speaksAloud)
            Toggle("Show captions", isOn: $settings.captionsEnabled)
            Picker("Language", selection: $settings.languageCode) {
                ForEach(Self.languageOptions, id: \.code) { option in Text(option.name).tag(option.code) }
            }
            HStack {
                Picker("Voice", selection: $settings.voiceIdentifier) {
                    Text("Best available").tag("")
                    ForEach(SpeechPlayer.availableVoices(languageCode: settings.languageCode), id: \.identifier) { voice in
                        Text("\(voice.name)\(voice.quality == .premium ? " (Premium)" : voice.quality == .enhanced ? " (Enhanced)" : "")").tag(voice.identifier)
                    }
                }
                Button("Preview") {
                    let previewIdentifier = settings.voiceIdentifier.isEmpty
                        ? SpeechPlayer.availableVoices(languageCode: settings.languageCode).first?.identifier ?? ""
                        : settings.voiceIdentifier
                    companion.speechPlayer.previewVoice(identifier: previewIdentifier)
                }
            }
            HStack {
                Text("Speed")
                Slider(value: $settings.speechSpeedMultiplier, in: 0.5...1.5, step: 0.1)
                Text(String(format: "%.1f×", settings.speechSpeedMultiplier)).monospacedDigit().frame(width: 40)
            }
            LabeledContent("Speaking with") {
                HStack {
                    Text(companion.speechPlayer.activeEngineDescription).foregroundColor(.secondary)
                    Button("Preview") { companion.speechPlayer.previewActiveVoice() }
                }
            }
            Section("Natural voice on this Mac (free)") {
                if LocalNeuralVoice.isInstalled {
                    Toggle("Use the natural voice", isOn: $settings.usesNeuralVoice)
                    Picker("Natural voice", selection: $settings.neuralVoiceIdentifier) {
                        ForEach(LocalNeuralVoice.englishVoices) { voice in Text(voice.displayName).tag(voice.id) }
                    }
                    Text("Runs on your Mac with no account. Speaks English, Spanish, French, Italian, Portuguese, and Hindi.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Install a free neural voice that sounds human and runs on your Mac (about 280 MB):")
                        .font(.caption).foregroundColor(.secondary)
                    Text("~/…/Pointwise.app/Contents/Resources/voice/install-local-voice.sh")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section("ElevenLabs voice (optional)") {
            Toggle("Use ElevenLabs voice", isOn: $settings.usesElevenLabs)
            if settings.usesElevenLabs {
                HStack {
                    SecureField(settings.elevenLabsAPIKey == nil ? "ElevenLabs API key" : "Key saved in Keychain", text: $elevenLabsKeyDraft)
                    Button("Save") {
                        settings.elevenLabsAPIKey = elevenLabsKeyDraft
                        elevenLabsKeyDraft = ""
                    }
                    .disabled(elevenLabsKeyDraft.isEmpty)
                }
                TextField("Voice ID", text: $settings.elevenLabsVoiceIdentifier)
                Picker("Model", selection: $settings.elevenLabsModel) {
                    Text("Flash (starts fastest)").tag("eleven_flash_v2_5")
                    Text("Multilingual v2 (richest)").tag("eleven_multilingual_v2")
                }
            }
            }
        }
        .formStyle(.grouped)
    }

    private var learnerTab: some View {
        Form {
            TextField("Name", text: $settings.learnerName)
            TextField("Grade or level (for example: 7th grade, college, adult beginner)", text: $settings.gradeLevel)
            TextField("Interests (Pointwise uses them in examples)", text: $settings.learnerInterests)
            TextField("How I learn best (for example: go slow, dyslexia-friendly, more pictures)", text: $settings.learningNeeds, axis: .vertical)
                .lineLimit(2...4)
            Text("Pointwise adapts its words, pace, and examples to this profile.").font(.caption).foregroundColor(.secondary)
        }
        .formStyle(.grouped)
    }

    private var memoryTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Pointwise remembers about you").font(.headline)
            Text("Only short text notes are kept. Screenshots are never saved.").font(.caption).foregroundColor(.secondary)
            List {
                if memory.rememberedFacts.isEmpty {
                    Text("Nothing yet. Pointwise saves goals, interests, and what you find hard as you learn.").foregroundColor(.secondary)
                }
                ForEach(memory.rememberedFacts, id: \.self) { fact in
                    HStack {
                        Text(fact)
                        Spacer()
                        Button(role: .destructive) { memory.forget(fact) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Forget everything", role: .destructive) { memory.forgetEverything() }
            }
        }
    }

    private var advancedTab: some View {
        Form {
            LabeledContent("Claude") { Text(companion.brainStatusText).foregroundColor(.secondary) }
            LabeledContent("Claude Code CLI") { Text(companion.brain.resolvedClaudePath ?? "Not found").foregroundColor(.secondary).textSelection(.enabled) }
            LabeledContent("Node.js") { Text(companion.brain.resolvedNodePath ?? "Not found").foregroundColor(.secondary).textSelection(.enabled) }
            TextField("Custom Claude Code path", text: $settings.claudeExecutablePathOverride)
            TextField("Custom Node.js path", text: $settings.nodeExecutablePathOverride)
            Button("Restart Claude connection") {
                companion.brain.stop()
                companion.startBrain()
            }
            Text("Logs: ~/Library/Logs/Pointwise.log").font(.caption).foregroundColor(.secondary)
        }
        .formStyle(.grouped)
    }
}
