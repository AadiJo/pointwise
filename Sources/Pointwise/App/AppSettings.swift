import Foundation
import Security
import SwiftUI

/// A Claude model the learner can pick. All models run through the local
/// Claude Code login, so there is no API key to manage.
struct ClaudeModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let detail: String

    static let all: [ClaudeModelOption] = [
        ClaudeModelOption(id: "claude-opus-5-5", displayName: "Opus 5.5", detail: "Smartest teacher"),
        ClaudeModelOption(id: "claude-sonnet-5-5", displayName: "Sonnet 5.5", detail: "Fast and smart"),
        ClaudeModelOption(id: "claude-haiku-5-5", displayName: "Haiku 5.5", detail: "Fastest replies"),
    ]
}

/// Every learner-facing preference, persisted in UserDefaults. The
/// ElevenLabs key is the one secret and lives in the Keychain instead.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var modelIdentifier: String { didSet { defaults.set(modelIdentifier, forKey: "modelIdentifier") } }
    @Published var reasoningEffort: String { didSet { defaults.set(reasoningEffort, forKey: "reasoningEffort") } }
    /// Off by default: thinking first adds seconds of silence before Pointwise speaks.
    @Published var thinksBeforeAnswering: Bool { didSet { defaults.set(thinksBeforeAnswering, forKey: "thinksBeforeAnswering") } }

    // Voice
    @Published var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") } }
    /// 0.5x to 1.5x of the normal speaking rate.
    @Published var speechSpeedMultiplier: Double { didSet { defaults.set(speechSpeedMultiplier, forKey: "speechSpeedMultiplier") } }
    @Published var languageCode: String { didSet { defaults.set(languageCode, forKey: "languageCode") } }
    @Published var captionsEnabled: Bool { didSet { defaults.set(captionsEnabled, forKey: "captionsEnabled") } }
    @Published var speaksAloud: Bool { didSet { defaults.set(speaksAloud, forKey: "speaksAloud") } }
    @Published var elevenLabsVoiceIdentifier: String { didSet { defaults.set(elevenLabsVoiceIdentifier, forKey: "elevenLabsVoiceIdentifier") } }
    @Published var usesElevenLabs: Bool { didSet { defaults.set(usesElevenLabs, forKey: "usesElevenLabs") } }
    /// "eleven_flash_v2_5" starts fastest; "eleven_multilingual_v2" sounds richest.
    @Published var elevenLabsModel: String { didSet { defaults.set(elevenLabsModel, forKey: "elevenLabsModel") } }
    /// Use the on-device neural voice (Kokoro) when it is installed and speaks the language.
    @Published var usesNeuralVoice: Bool { didSet { defaults.set(usesNeuralVoice, forKey: "usesNeuralVoice") } }
    @Published var neuralVoiceIdentifier: String { didSet { defaults.set(neuralVoiceIdentifier, forKey: "neuralVoiceIdentifier") } }

    // Cursor
    @Published var cursorColorHex: String { didSet { defaults.set(cursorColorHex, forKey: "cursorColorHex") } }
    /// When off, the buddy only appears while you talk to it.
    @Published var alwaysShowsCursorBuddy: Bool { didSet { defaults.set(alwaysShowsCursorBuddy, forKey: "alwaysShowsCursorBuddy") } }

    // Learner profile
    @Published var learnerName: String { didSet { defaults.set(learnerName, forKey: "learnerName") } }
    @Published var gradeLevel: String { didSet { defaults.set(gradeLevel, forKey: "gradeLevel") } }
    @Published var learnerInterests: String { didSet { defaults.set(learnerInterests, forKey: "learnerInterests") } }
    @Published var learningNeeds: String { didSet { defaults.set(learningNeeds, forKey: "learningNeeds") } }

    // Safety and control
    @Published var actionsEnabled: Bool { didSet { defaults.set(actionsEnabled, forKey: "actionsEnabled") } }
    @Published var actionsAlwaysAllowed: Bool { didSet { defaults.set(actionsAlwaysAllowed, forKey: "actionsAlwaysAllowed") } }

    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") } }

    // Advanced
    @Published var claudeExecutablePathOverride: String { didSet { defaults.set(claudeExecutablePathOverride, forKey: "claudeExecutablePathOverride") } }
    @Published var nodeExecutablePathOverride: String { didSet { defaults.set(nodeExecutablePathOverride, forKey: "nodeExecutablePathOverride") } }

    private init() {
        modelIdentifier = defaults.string(forKey: "modelIdentifier") ?? ClaudeModelOption.all[0].id
        reasoningEffort = defaults.string(forKey: "reasoningEffort") ?? "low"
        thinksBeforeAnswering = defaults.object(forKey: "thinksBeforeAnswering") as? Bool ?? false
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier") ?? ""
        speechSpeedMultiplier = defaults.object(forKey: "speechSpeedMultiplier") as? Double ?? 1.0
        languageCode = defaults.string(forKey: "languageCode") ?? (Locale.current.identifier(.bcp47))
        captionsEnabled = defaults.object(forKey: "captionsEnabled") as? Bool ?? true
        speaksAloud = defaults.object(forKey: "speaksAloud") as? Bool ?? true
        // Jessica, a premade voice: free ElevenLabs plans cannot use library voices through the API.
        elevenLabsVoiceIdentifier = defaults.string(forKey: "elevenLabsVoiceIdentifier") ?? "cgSgspJ2msm6clMCkdW9"
        usesElevenLabs = defaults.object(forKey: "usesElevenLabs") as? Bool ?? false
        elevenLabsModel = defaults.string(forKey: "elevenLabsModel") ?? "eleven_flash_v2_5"
        usesNeuralVoice = defaults.object(forKey: "usesNeuralVoice") as? Bool ?? true
        neuralVoiceIdentifier = defaults.string(forKey: "neuralVoiceIdentifier") ?? "af_heart"
        cursorColorHex = defaults.string(forKey: "cursorColorHex") ?? "#3380FF"
        alwaysShowsCursorBuddy = defaults.object(forKey: "alwaysShowsCursorBuddy") as? Bool ?? true
        learnerName = defaults.string(forKey: "learnerName") ?? ""
        gradeLevel = defaults.string(forKey: "gradeLevel") ?? ""
        learnerInterests = defaults.string(forKey: "learnerInterests") ?? ""
        learningNeeds = defaults.string(forKey: "learningNeeds") ?? ""
        actionsEnabled = defaults.object(forKey: "actionsEnabled") as? Bool ?? false
        actionsAlwaysAllowed = defaults.object(forKey: "actionsAlwaysAllowed") as? Bool ?? false
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        claudeExecutablePathOverride = defaults.string(forKey: "claudeExecutablePathOverride") ?? ""
        nodeExecutablePathOverride = defaults.string(forKey: "nodeExecutablePathOverride") ?? ""
    }

    var cursorColor: Color { Color(hex: cursorColorHex) }

    /// Markdown profile sent to Claude so it can match the learner's level.
    var learnerProfileMarkdown: String {
        var lines: [String] = []
        if !learnerName.isEmpty { lines.append("- Name: \(learnerName)") }
        if !gradeLevel.isEmpty { lines.append("- Grade or level: \(gradeLevel)") }
        if !learnerInterests.isEmpty { lines.append("- Interests: \(learnerInterests)") }
        if !learningNeeds.isEmpty { lines.append("- Learning needs: \(learningNeeds)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - ElevenLabs key (Keychain)

    private static let keychainService = "com.aadijo.pointwise"
    private static let elevenLabsKeychainAccount = "elevenlabs-api-key"

    var elevenLabsAPIKey: String? {
        get {
            if let environmentKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !environmentKey.isEmpty {
                return environmentKey
            }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
                kSecAttrAccount as String: Self.elevenLabsKeychainAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
                kSecAttrAccount as String: Self.elevenLabsKeychainAccount,
            ]
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else {
                objectWillChange.send()
                return
            }
            var attributes = query
            attributes[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(attributes as CFDictionary, nil)
            objectWillChange.send()
        }
    }
}
