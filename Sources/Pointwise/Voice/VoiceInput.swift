import AVFoundation
import Foundation
import Speech

/// One push-to-talk transcription. Audio buffers go in; text comes out on finish.
protocol LiveTranscriptionSession: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async -> String
    func cancel()
}

enum TranscriberFactory {
    /// On macOS 26 and later, Apple's on-device SpeechAnalyzer runs fully
    /// offline and needs no Speech Recognition permission. Older systems use
    /// SFSpeechRecognizer.
    static func makeSession(languageCode: String) async throws -> LiveTranscriptionSession {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return try await SpeechAnalyzerTranscriptionSession(languageCode: languageCode)
        }
        #endif
        guard await LegacySpeechTranscriptionSession.requestAuthorizationIfNeeded() else {
            throw NSError(domain: "Pointwise", code: 3, userInfo: [NSLocalizedDescriptionKey: "Allow Speech Recognition for Pointwise in System Settings → Privacy & Security."])
        }
        return try LegacySpeechTranscriptionSession(languageCode: languageCode)
    }

    /// Downloads the on-device speech model ahead of the first question.
    static func prepareModels(languageCode: String) async {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            await SpeechAnalyzerTranscriptionSession.installAssetsIfNeeded(languageCode: languageCode)
        }
        #endif
    }

}

// MARK: - SpeechAnalyzer (macOS 26+)

#if compiler(>=6.2)
@available(macOS 26.0, *)
final class SpeechAnalyzerTranscriptionSession: LiveTranscriptionSession, @unchecked Sendable {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat?
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let resultsTask: Task<String, Never>
    private let lock = NSLock()
    private var audioConverter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(languageCode: String) async throws {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode)) ?? Locale(identifier: "en-US")
        transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        await Self.installAssetsIfNeeded(transcriber: transcriber)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        let transcriberForResults = transcriber
        resultsTask = Task {
            var transcriptText = ""
            do {
                for try await result in transcriberForResults.results where result.isFinal {
                    transcriptText += String(result.text.characters)
                }
            } catch {
                PointwiseLog.write("speech results ended with error: \(error)")
            }
            return transcriptText
        }
        try await analyzer.start(inputSequence: inputStream)
    }

    static func installAssetsIfNeeded(languageCode: String) async {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: languageCode)) ?? Locale(identifier: "en-US")
        await installAssetsIfNeeded(transcriber: SpeechTranscriber(locale: locale, preset: .transcription))
    }

    private static func installAssetsIfNeeded(transcriber: SpeechTranscriber) async {
        do {
            if await AssetInventory.status(forModules: [transcriber]) != .installed,
               let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await installationRequest.downloadAndInstall()
            }
        } catch {
            PointwiseLog.write("speech model install failed: \(error)")
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let convertedBuffer = convertForAnalyzer(buffer) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
    }

    func finish() async -> String {
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            PointwiseLog.write("speech finalize failed: \(error)")
        }
        return await resultsTask.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        inputContinuation.finish()
        resultsTask.cancel()
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func convertForAnalyzer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let analyzerFormat, buffer.format != analyzerFormat else { return buffer }
        lock.lock(); defer { lock.unlock() }
        if audioConverter == nil || converterInputFormat != buffer.format {
            audioConverter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            converterInputFormat = buffer.format
        }
        guard let audioConverter else { return nil }
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * analyzerFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outputCapacity) else { return nil }
        var hasProvidedInput = false
        var conversionError: NSError?
        audioConverter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if hasProvidedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            hasProvidedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? outputBuffer : nil
    }
}

#endif

// MARK: - SFSpeechRecognizer fallback (macOS 14–15)

final class LegacySpeechTranscriptionSession: LiveTranscriptionSession, @unchecked Sendable {
    /// SFSpeechRecognizer needs Speech Recognition permission (SpeechAnalyzer on macOS 26 does not).
    static func requestAuthorizationIfNeeded() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
            }
        default: return false
        }
    }

    /// Kept alive for the whole session; a recognizer that is released stops its task.
    private let recognizer: SFSpeechRecognizer
    private let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var finalTranscriptContinuation: CheckedContinuation<String, Never>?
    private let lock = NSLock()

    init(languageCode: String) throws {
        guard let availableRecognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode)) ?? SFSpeechRecognizer(), availableRecognizer.isAvailable else {
            throw NSError(domain: "Pointwise", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is not available."])
        }
        recognizer = availableRecognizer
        recognitionRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { recognitionRequest.requiresOnDeviceRecognition = true }
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            if let result { self.latestTranscript = result.bestTranscription.formattedString }
            let isDone = (result?.isFinal ?? false) || error != nil
            let continuation = isDone ? self.finalTranscriptContinuation : nil
            if isDone { self.finalTranscriptContinuation = nil }
            let transcript = self.latestTranscript
            self.lock.unlock()
            continuation?.resume(returning: transcript)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest.append(buffer)
    }

    func finish() async -> String {
        recognitionRequest.endAudio()
        return await withCheckedContinuation { continuation in
            lock.lock()
            finalTranscriptContinuation = continuation
            lock.unlock()
            // Safety net in case the recognizer never reports a final result.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let pendingContinuation = self.finalTranscriptContinuation
                self.finalTranscriptContinuation = nil
                let transcript = self.latestTranscript
                self.lock.unlock()
                pendingContinuation?.resume(returning: transcript)
            }
        }
    }

    func cancel() {
        recognitionTask?.cancel()
    }
}

// MARK: - Microphone

/// Holds microphone audio until the transcriber is ready, then streams to it.
/// The speech model takes a moment to start, and the learner's first words
/// should not be lost while it does.
final class AudioBufferRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var bufferedAudio: [AVAudioPCMBuffer] = []
    private var transcriptionSession: LiveTranscriptionSession?

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let transcriptionSession {
            transcriptionSession.append(buffer)
        } else if let bufferCopy = Self.copy(buffer) {
            bufferedAudio.append(bufferCopy)
        }
    }

    func attach(_ session: LiveTranscriptionSession) {
        lock.lock()
        defer { lock.unlock() }
        for buffer in bufferedAudio { session.append(buffer) }
        bufferedAudio.removeAll()
        transcriptionSession = session
    }

    func detachSession() -> LiveTranscriptionSession? {
        lock.lock()
        defer { lock.unlock() }
        let session = transcriptionSession
        transcriptionSession = nil
        bufferedAudio.removeAll()
        return session
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let bufferCopy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        bufferCopy.frameLength = buffer.frameLength
        let channelCount = Int(buffer.format.channelCount)
        if let source = buffer.floatChannelData, let destination = bufferCopy.floatChannelData {
            for channel in 0..<channelCount { destination[channel].update(from: source[channel], count: Int(buffer.frameLength)) }
        } else if let source = buffer.int16ChannelData, let destination = bufferCopy.int16ChannelData {
            for channel in 0..<channelCount { destination[channel].update(from: source[channel], count: Int(buffer.frameLength)) }
        }
        return bufferCopy
    }
}

/// Captures the microphone while push-to-talk is held and reports loudness for the waveform.
@MainActor
final class MicrophoneCapture {
    var onAudioLevel: ((CGFloat) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var audioRelay = AudioBufferRelay()
    private(set) var isCapturing = false

    /// Starts listening right away; audio waits in a buffer until `attach` gives it a transcriber.
    func start() throws {
        guard !isCapturing else { return }
        let relay = AudioBufferRelay()
        audioRelay = relay
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // With no microphone connected the format is empty, and installing a tap would crash.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Pointwise", code: 4, userInfo: [NSLocalizedDescriptionKey: "No microphone was found. Connect one, or double-tap Control to type instead."])
        }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            relay.append(buffer)
            let audioLevel = Self.rootMeanSquareLevel(of: buffer)
            Task { @MainActor [weak self] in self?.onAudioLevel?(audioLevel) }
        }
        audioEngine.prepare()
        try audioEngine.start()
        isCapturing = true
    }

    func attach(_ session: LiveTranscriptionSession) {
        audioRelay.attach(session)
    }

    /// Stops the microphone and returns the session so the caller can finish it.
    func stop() -> LiveTranscriptionSession? {
        guard isCapturing else { return nil }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false
        onAudioLevel?(0)
        return audioRelay.detachSession()
    }

    nonisolated private static func rootMeanSquareLevel(of buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelSamples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for sampleIndex in 0..<Int(buffer.frameLength) {
            sumOfSquares += channelSamples[sampleIndex] * channelSamples[sampleIndex]
        }
        return CGFloat(sqrt(sumOfSquares / Float(buffer.frameLength)))
    }
}
