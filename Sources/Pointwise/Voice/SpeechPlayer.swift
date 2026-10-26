import AVFoundation
import CoreAudio
import Foundation
import os

/// Audio for one sentence, made before it is needed so the next sentence
/// starts the moment the current one ends.
enum PreparedSpeech {
    /// An ElevenLabs MP3 or a local neural voice WAV.
    case audioFile(URL, alreadyAtSpeechSpeed: Bool)
    /// Apple voice spoken live by the synthesizer.
    case liveAppleVoice(String)
}

/// Speaks text with, in order of preference: an ElevenLabs voice (with a key),
/// the on-device neural voice (when installed), or an Apple voice.
@MainActor
final class SpeechPlayer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var speechFinishedContinuation: CheckedContinuation<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var playbackFinishedContinuation: CheckedContinuation<Void, Never>?
    private var stopGeneration = 0
    private(set) var isSpeaking = false
    /// The last sentence sent to ElevenLabs, so the next one continues its intonation.
    private var previousElevenLabsText: String?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Voices

    /// Apple voices for a language, best quality first.
    static func availableVoices(languageCode: String) -> [AVSpeechSynthesisVoice] {
        let languagePrefix = String(languageCode.prefix(2)).lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(languagePrefix) }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            // Some listed voices (for example Siri voices) cannot be loaded by apps.
            .filter { AVSpeechSynthesisVoice(identifier: $0.identifier) != nil }
            .sorted { firstVoice, secondVoice in
                if firstVoice.quality != secondVoice.quality { return firstVoice.quality.rawValue > secondVoice.quality.rawValue }
                let firstMatchesRegion = firstVoice.language.caseInsensitiveCompare(languageCode) == .orderedSame
                let secondMatchesRegion = secondVoice.language.caseInsensitiveCompare(languageCode) == .orderedSame
                if firstMatchesRegion != secondMatchesRegion { return firstMatchesRegion }
                return firstVoice.name < secondVoice.name
            }
    }

    private func selectedAppleVoice() -> AVSpeechSynthesisVoice? {
        let settings = AppSettings.shared
        if !settings.voiceIdentifier.isEmpty, let chosenVoice = AVSpeechSynthesisVoice(identifier: settings.voiceIdentifier) {
            return chosenVoice
        }
        return Self.availableVoices(languageCode: settings.languageCode).first
    }

    private func makeUtterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = selectedAppleVoice()
        utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * Float(speechSpeedMultiplier), AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        utterance.postUtteranceDelay = 0.05
        return utterance
    }

    private var speechSpeedMultiplier: Double { min(max(AppSettings.shared.speechSpeedMultiplier, 0.5), 1.5) }

    var usesElevenLabs: Bool {
        let settings = AppSettings.shared
        let hasEnvironmentKey = !(ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? "").isEmpty
        return (settings.usesElevenLabs || hasEnvironmentKey) && !(settings.elevenLabsAPIKey ?? "").isEmpty
    }

    var usesNeuralVoice: Bool {
        AppSettings.shared.usesNeuralVoice && LocalNeuralVoice.isInstalled
            && LocalNeuralVoice.kokoroLanguage(for: AppSettings.shared.languageCode) != nil
    }

    /// Short name of the voice engine in use, for Settings.
    var activeEngineDescription: String {
        if usesElevenLabs { return "ElevenLabs" }
        if usesNeuralVoice { return "Natural voice on this Mac" }
        return "Apple voice"
    }

    // MARK: - Preparing and playing

    /// Makes the audio for one sentence without playing it.
    func prepare(_ text: String) async -> PreparedSpeech {
        if usesElevenLabs, let audioURL = await synthesizeWithElevenLabs(text) {
            return .audioFile(audioURL, alreadyAtSpeechSpeed: true)
        }
        if usesNeuralVoice, !Task.isCancelled, let audioURL = await LocalNeuralVoice.shared.synthesize(
            text, voice: AppSettings.shared.neuralVoiceIdentifier, speed: speechSpeedMultiplier, languageCode: AppSettings.shared.languageCode
        ) {
            return .audioFile(audioURL, alreadyAtSpeechSpeed: true)
        }
        return .liveAppleVoice(text)
    }

    /// Plays prepared audio and returns when it has finished (or was stopped).
    func play(_ preparedSpeech: PreparedSpeech) async {
        let generationAtStart = stopGeneration
        isSpeaking = true
        defer { if generationAtStart == stopGeneration { isSpeaking = false } }
        switch preparedSpeech {
        case .audioFile(let audioURL, let alreadyAtSpeechSpeed):
            defer { try? FileManager.default.removeItem(at: audioURL) }
            await playThroughSpeakers(audioURL: audioURL, rate: alreadyAtSpeechSpeed ? 1 : Float(speechSpeedMultiplier))
        case .liveAppleVoice(let text):
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                speechFinishedContinuation = continuation
                synthesizer.speak(makeUtterance(for: text))
            }
        }
    }

    /// Speaks one sentence and returns when it has finished (or was stopped).
    func speak(_ text: String) async {
        let generationAtStart = stopGeneration
        let preparedSpeech = await prepare(text)
        // A stop while the audio was being made must not start it afterwards.
        guard generationAtStart == stopGeneration, !Task.isCancelled else { return }
        await play(preparedSpeech)
    }

    func stop() {
        stopGeneration += 1
        isSpeaking = false
        previousElevenLabsText = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        resumeSpeechContinuation()
        playbackFinishedContinuation?.resume()
        playbackFinishedContinuation = nil
    }

    /// Plays a short sample so the learner can compare voices.
    func previewVoice(identifier: String) {
        stop()
        let utterance = makeUtterance(for: "Hi! I'm Pointwise. Let's learn something together.")
        utterance.voice = AVSpeechSynthesisVoice(identifier: identifier) ?? utterance.voice
        synthesizer.speak(utterance)
    }

    /// Plays a sample of whichever voice engine is active.
    func previewActiveVoice() {
        stop()
        Task { await speak("Hi! I'm Pointwise. Let's learn something together.") }
    }

    private func resumeSpeechContinuation() {
        speechFinishedContinuation?.resume()
        speechFinishedContinuation = nil
    }

    private func synthesizeWithElevenLabs(_ text: String) async -> URL? {
        let previousText = previousElevenLabsText
        previousElevenLabsText = text
        do {
            let audioData = try await ElevenLabsSpeech.synthesize(text, previousText: previousText, speed: speechSpeedMultiplier)
            let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("pointwise-tts-\(UUID().uuidString).mp3")
            try audioData.write(to: audioURL)
            return audioURL
        } catch {
            if !Task.isCancelled { PointwiseLog.write("ElevenLabs speech failed: \(error)") }
            return nil
        }
    }

    private func playThroughSpeakers(audioURL: URL, rate: Float) async {
        guard let player = try? AVAudioPlayer(contentsOf: audioURL) else { return }
        player.enableRate = rate != 1
        player.rate = rate
        player.delegate = self
        audioPlayer = player
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playbackFinishedContinuation = continuation
            if !player.play() {
                playbackFinishedContinuation = nil
                continuation.resume()
            }
        }
    }

    // MARK: - System output

    /// True when the Mac's default output device is muted or at zero volume.
    static func isSystemOutputMuted() -> Bool {
        var outputDeviceIdentifier = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &propertySize, &outputDeviceIdentifier) == noErr else {
            return false
        }
        var isMuted: UInt32 = 0
        propertySize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(outputDeviceIdentifier, &muteAddress, 0, nil, &propertySize, &isMuted) == noErr, isMuted != 0 {
            return true
        }
        var volume: Float32 = 1
        propertySize = UInt32(MemoryLayout<Float32>.size)
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(outputDeviceIdentifier, &volumeAddress, 0, nil, &propertySize, &volume) == noErr {
            return volume < 0.01
        }
        return false
    }
}

extension SpeechPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeSpeechContinuation() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resumeSpeechContinuation() }
    }
}

extension SpeechPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playbackFinishedContinuation?.resume()
            self.playbackFinishedContinuation = nil
        }
    }
}

/// Optional premium voice. Used only when the learner adds their own ElevenLabs key.
enum ElevenLabsSpeech {
    /// Friendly premade voices to fall back on if the chosen voice is not in the account.
    /// Premade voices work on every plan; library voices need a paid plan.
    static let fallbackVoiceIdentifiers = ["cgSgspJ2msm6clMCkdW9", "EXAVITQu4vr4xnSDxMaL", "Xb7hH8MSUJpSbSDYk0k2"]

    struct RequestFailure: Error, CustomStringConvertible {
        let statusCode: Int
        let body: String
        var description: String { "HTTP \(statusCode): \(body.prefix(200))" }

        /// The account cannot use this voice (missing, or a library voice on a free plan).
        var voiceIsUnavailable: Bool {
            statusCode == 404 || statusCode == 402 || body.contains("voice_not_found") || body.contains("paid_plan_required")
        }

        /// Too many requests at once (free plans allow few); worth a short retry.
        var isRateLimited: Bool { statusCode == 429 }
    }

    /// Voices that failed once, so later sentences go straight to a working voice
    /// instead of paying for a failed request each time.
    private static let unavailableVoiceIdentifiers = OSAllocatedUnfairLock(initialState: Set<String>())

    static func synthesize(_ text: String, previousText: String? = nil, speed: Double = 1, voiceIdentifier: String? = nil, model: String? = nil) async throws -> Data {
        let settings = await AppSettings.shared
        guard let apiKey = await settings.elevenLabsAPIKey else { throw URLError(.userAuthenticationRequired) }
        let savedVoiceIdentifier = await settings.elevenLabsVoiceIdentifier
        let savedModel = await settings.elevenLabsModel
        let chosenVoiceIdentifier = voiceIdentifier ?? savedVoiceIdentifier
        let modelIdentifier = model ?? savedModel
        let skippedVoiceIdentifiers = unavailableVoiceIdentifiers.withLock { $0 }
        let candidateVoiceIdentifiers = ([chosenVoiceIdentifier] + fallbackVoiceIdentifiers.filter { $0 != chosenVoiceIdentifier })
            .filter { !skippedVoiceIdentifiers.contains($0) }
        var lastError: Error = URLError(.badServerResponse)
        for candidateVoiceIdentifier in candidateVoiceIdentifiers {
            do {
                return try await requestRetryingWhenBusy(text: text, previousText: previousText, speed: speed, voiceIdentifier: candidateVoiceIdentifier, model: modelIdentifier, apiKey: apiKey)
            } catch let failure as RequestFailure where failure.voiceIsUnavailable {
                unavailableVoiceIdentifiers.withLock { _ = $0.insert(candidateVoiceIdentifier) }
                PointwiseLog.write("ElevenLabs voice \(candidateVoiceIdentifier) is not available (\(failure)); trying the next voice")
                lastError = failure
                continue
            }
        }
        throw lastError
    }

    private static func requestRetryingWhenBusy(text: String, previousText: String?, speed: Double, voiceIdentifier: String, model: String, apiKey: String) async throws -> Data {
        let retryDelaysInSeconds = [0.4, 0.8, 1.6]
        for retryDelay in retryDelaysInSeconds {
            do {
                return try await request(text: text, previousText: previousText, speed: speed, voiceIdentifier: voiceIdentifier, model: model, apiKey: apiKey)
            } catch let failure as RequestFailure where failure.isRateLimited {
                try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
        }
        return try await request(text: text, previousText: previousText, speed: speed, voiceIdentifier: voiceIdentifier, model: model, apiKey: apiKey)
    }

    private static func request(text: String, previousText: String?, speed: Double, voiceIdentifier: String, model: String, apiKey: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceIdentifier)?output_format=mp3_44100_128")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "style": 0.15, "use_speaker_boost": true, "speed": min(max(speed, 0.7), 1.2)],
        ]
        if let previousText { body["previous_text"] = previousText }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard statusCode == 200 else {
            throw RequestFailure(statusCode: statusCode, body: String(data: responseData, encoding: .utf8) ?? "")
        }
        return responseData
    }
}
