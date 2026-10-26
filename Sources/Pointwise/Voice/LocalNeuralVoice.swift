import Foundation

/// A natural-sounding voice that runs on the Mac: Kokoro-82M through a small
/// Python sidecar (`voice/kokoro_server.py`). Free, private, and no account.
/// Installed on demand by `scripts/install-local-voice.sh` (about 280 MB).
@MainActor
final class LocalNeuralVoice {
    static let shared = LocalNeuralVoice()

    /// A Kokoro voice for the learner to pick.
    struct VoiceOption: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    static let englishVoices: [VoiceOption] = [
        VoiceOption(id: "af_heart", displayName: "Heart (warm, US)"),
        VoiceOption(id: "af_bella", displayName: "Bella (bright, US)"),
        VoiceOption(id: "af_nicole", displayName: "Nicole (soft, US)"),
        VoiceOption(id: "am_michael", displayName: "Michael (calm, US)"),
        VoiceOption(id: "am_fenrir", displayName: "Fenrir (deep, US)"),
        VoiceOption(id: "bf_emma", displayName: "Emma (UK)"),
        VoiceOption(id: "bm_george", displayName: "George (UK)"),
    ]

    static var voiceDirectory: URL {
        if let overrideDirectory = ProcessInfo.processInfo.environment["POINTWISE_VOICE_DIR"] {
            return URL(fileURLWithPath: overrideDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pointwise/voice")
    }

    private static var pythonURL: URL { voiceDirectory.appendingPathComponent("venv/bin/python") }

    static var isInstalled: Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: pythonURL.path)
            && fileManager.fileExists(atPath: voiceDirectory.appendingPathComponent("kokoro-v1.0.int8.onnx").path)
            && fileManager.fileExists(atPath: voiceDirectory.appendingPathComponent("voices-v1.0.bin").path)
            && serverScriptURL != nil
    }

    private static var serverScriptURL: URL? {
        Bundle.main.url(forResource: "kokoro_server", withExtension: "py", subdirectory: "voice")
    }

    /// Kokoro's language code and a default voice for a BCP-47 code, or nil when Kokoro cannot speak it.
    static func kokoroLanguage(for languageCode: String) -> (code: String, defaultVoice: String)? {
        let lowercasedCode = languageCode.lowercased()
        if lowercasedCode.hasPrefix("en-gb") { return ("en-gb", "bf_emma") }
        if lowercasedCode.hasPrefix("en") { return ("en-us", "af_heart") }
        if lowercasedCode.hasPrefix("es") { return ("es", "ef_dora") }
        if lowercasedCode.hasPrefix("fr") { return ("fr-fr", "ff_siwis") }
        if lowercasedCode.hasPrefix("it") { return ("it", "if_sara") }
        if lowercasedCode.hasPrefix("pt") { return ("pt-br", "pf_dora") }
        if lowercasedCode.hasPrefix("hi") { return ("hi", "hf_alpha") }
        return nil
    }

    private var process: Process?
    private var standardInputHandle: FileHandle?
    private var unparsedOutputData = Data()
    private var isReady = false
    private var readinessWaiters: [CheckedContinuation<Bool, Never>] = []
    private var pendingRequests: [String: CheckedContinuation<URL?, Never>] = [:]
    private var nextRequestNumber = 1
    private let outputDirectory: URL

    private init() {
        outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("pointwise-voice", isDirectory: true)
        try? FileManager.default.removeItem(at: outputDirectory)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    /// Starts the sidecar early so the first sentence does not wait for the model to load.
    func warmUp() {
        guard Self.isInstalled else { return }
        startIfNeeded()
    }

    /// Writes the sentence to a WAV file and returns it, or nil if the voice is unavailable.
    func synthesize(_ text: String, voice: String, speed: Double, languageCode: String) async -> URL? {
        guard Self.isInstalled, let kokoroLanguage = Self.kokoroLanguage(for: languageCode) else { return nil }
        startIfNeeded()
        guard await waitUntilReady() else { return nil }
        let requestIdentifier = String(nextRequestNumber)
        nextRequestNumber += 1
        let outputURL = outputDirectory.appendingPathComponent("speech-\(requestIdentifier).wav")
        // A voice from another language would mispronounce everything; use that language's default.
        // Kokoro voice names start with their language letter ("a" US English, "b" UK English, "e" Spanish...).
        let acceptedLanguageLetters: Set<Character> = kokoroLanguage.code.hasPrefix("en") ? ["a", "b"] : [kokoroLanguage.defaultVoice.first ?? "a"]
        let voiceForLanguage = voice.first.map(acceptedLanguageLetters.contains) == true ? voice : kokoroLanguage.defaultVoice
        let request: [String: Any] = [
            "id": requestIdentifier, "text": text, "voice": voiceForLanguage,
            "speed": min(max(speed, 0.5), 1.8), "lang": kokoroLanguage.code, "out": outputURL.path,
        ]
        guard let standardInputHandle, var requestData = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        requestData.append(0x0A)
        return await withCheckedContinuation { continuation in
            pendingRequests[requestIdentifier] = continuation
            do {
                try standardInputHandle.write(contentsOf: requestData)
            } catch {
                pendingRequests.removeValue(forKey: requestIdentifier)?.resume(returning: nil)
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        standardInputHandle = nil
        failEverything()
    }

    // MARK: - Process

    private func startIfNeeded() {
        guard process == nil, let serverScriptURL = Self.serverScriptURL else { return }
        let newProcess = Process()
        newProcess.executableURL = Self.pythonURL
        newProcess.arguments = ["-u", serverScriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["POINTWISE_VOICE_DIR"] = Self.voiceDirectory.path
        newProcess.environment = environment
        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        newProcess.standardInput = standardInputPipe
        newProcess.standardOutput = standardOutputPipe
        newProcess.standardError = FileHandle.nullDevice
        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let newData = handle.availableData
            guard !newData.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consumeOutput(newData) }
        }
        newProcess.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard let self, self.process === terminatedProcess else { return }
                PointwiseLog.write("local voice exited with status \(terminatedProcess.terminationStatus)")
                self.process = nil
                self.standardInputHandle = nil
                self.failEverything()
            }
        }
        do {
            try newProcess.run()
            process = newProcess
            standardInputHandle = standardInputPipe.fileHandleForWriting
            isReady = false
        } catch {
            PointwiseLog.write("could not start the local voice: \(error)")
        }
    }

    private func waitUntilReady() async -> Bool {
        if isReady { return true }
        guard process != nil else { return false }
        return await withCheckedContinuation { continuation in readinessWaiters.append(continuation) }
    }

    private func consumeOutput(_ newData: Data) {
        unparsedOutputData.append(newData)
        while let newlineIndex = unparsedOutputData.firstIndex(of: 0x0A) {
            let lineData = unparsedOutputData[unparsedOutputData.startIndex..<newlineIndex]
            unparsedOutputData.removeSubrange(unparsedOutputData.startIndex...newlineIndex)
            guard let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if message["ready"] as? Bool == true {
                isReady = true
                readinessWaiters.forEach { $0.resume(returning: true) }
                readinessWaiters.removeAll()
                continue
            }
            guard let requestIdentifier = message["id"] as? String,
                  let continuation = pendingRequests.removeValue(forKey: requestIdentifier) else { continue }
            if message["ok"] as? Bool == true, let path = message["path"] as? String {
                continuation.resume(returning: URL(fileURLWithPath: path))
            } else {
                PointwiseLog.write("local voice failed: \(message["error"] as? String ?? "unknown error")")
                continuation.resume(returning: nil)
            }
        }
    }

    private func failEverything() {
        isReady = false
        readinessWaiters.forEach { $0.resume(returning: false) }
        readinessWaiters.removeAll()
        pendingRequests.values.forEach { $0.resume(returning: nil) }
        pendingRequests.removeAll()
    }
}
