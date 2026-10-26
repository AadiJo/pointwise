import AppKit
import AVFoundation
import Combine
import SwiftUI

/// The central state machine. It turns push-to-talk or typed questions into
/// Claude turns, speaks and draws the answers, and runs the teaching tools
/// (walkthroughs, whiteboard, quizzes, memory, and showing by doing).
@MainActor
final class CompanionController: ObservableObject {
    enum Activity: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case waitingForLearner
    }

    // MARK: Dependencies

    let settings = AppSettings.shared
    let memory = MemoryStore.shared
    let overlayState = OverlayState()
    let panels = TeachingPanelsController()
    let brain = BrainClient()
    let speechPlayer = SpeechPlayer()
    private(set) lazy var speechQueue = SpeechQueue(speechPlayer: speechPlayer)
    private(set) lazy var overlayWindows = OverlayWindowManager(state: overlayState)
    private let microphone = MicrophoneCapture()
    let hotkeys = HotkeyMonitor()
    private let clickMonitor = GlobalClickMonitor()

    /// Injectable, so another screen, pointer, or action source can stand in for the real Mac.
    var screenSource: ScreenSource = SystemScreenSource()
    var actionPerformer: ComputerActionPerformer = SystemActionPerformer()
    var pointerLocationProvider: () -> CGPoint = { NSEvent.mouseLocation } {
        didSet {
            overlayState.pointerLocationProvider = pointerLocationProvider
            panels.pointerLocationProvider = pointerLocationProvider
        }
    }
    /// Opens URLs for `open_url`.
    var urlOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Context line describing the front app, its window, and any page URL.
    var frontAppDescriptionProvider: () async -> String = {
        await FrontWindowInspector.currentDetails().contextDescription
    }

    // MARK: Published state for the UI

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var brainStatusText = "Starting Claude…"
    @Published private(set) var isBrainReady = false
    @Published private(set) var conversation: [ConversationEntry] = []
    @Published private(set) var lastErrorText: String?
    @Published private(set) var studyNotesMarkdown: String?
    @Published private(set) var hasHotkeyAccess = false

    // MARK: Turn state

    private var currentTurnId: String?
    private var responseParser = StreamingResponseParser()
    private var latestScreens: [CapturedScreen] = []
    private var currentLessonIdentifier = UUID()
    private var currentLessonStartedAt = Date()
    private var actionsAllowedThisLesson = false
    private var heldSegmentsWhileLearnerTalks: [SpokenSegment]?
    private var pendingTranscriptionSessionTask: Task<LiveTranscriptionSession?, Never>?
    private var paintTrailTimer: Timer?
    private var idleCleanupTask: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?
    private var hotkeyRetryTimer: Timer?
    private var pendingSummaryRequestId: String?

    /// The last few sentences Pointwise spoke, used to describe the current step.
    private(set) var recentSpokenSentences: [String] = []
    /// Sentences spoken since the last walkthrough wait, so a step is never silent.
    private var sentencesSpokenSinceLastStepWait = 0
    /// Sentences spoken since the last action, so Pointwise says what it does before doing it.
    private var sentencesSpokenSinceLastAction = 0
    /// Sentences spoken since the whiteboard appeared this turn (nil when it did not).
    private var sentencesSpokenSinceWhiteboard: Int?

    /// A walkthrough step that is waiting for the learner.
    private struct StepWait {
        let stepIndex: Int
        let targetGlobalPoint: CGPoint?
        let expectation: String
        let baselineFingerprint: [UInt8]?
        /// The display the baseline came from; changes are only compared on the same display.
        let baselineDisplayFrame: CGRect?
        let identifier = UUID()
        let continuation: CheckedContinuation<String, Never>
        var offTargetClickCount = 0
    }
    private var activeStepWait: StepWait?

    /// A click quiz waiting for the learner's answer click.
    private struct ClickQuizWait {
        let identifier = UUID()
        let continuation: CheckedContinuation<CGPoint?, Never>
    }
    private var activeClickQuiz: ClickQuizWait?
    /// The tool running now; the next tool call waits for it.
    private var toolQueueTail: Task<Void, Never>?
    /// What the learner circled with the pointer this turn, so panels can open somewhere else.
    private var lastPaintTrailBounds: CGRect?

    // MARK: - Startup

    func start() {
        overlayState.cursorColor = settings.cursorColor
        overlayState.isBuddyAlwaysVisible = settings.alwaysShowsCursorBuddy
        overlayWindows.showOverlay()

        panels.askBarModel.onSubmit = { [weak self] question in
            self?.panels.hideAskBar()
            self?.handleLearnerInput(question, inputMode: "typed")
        }
        panels.askBarModel.onCancel = { [weak self] in self?.panels.hideAskBar() }
        panels.walkthroughModel.onContinue = { [weak self] in self?.resolveStepWait(with: "The learner pressed Continue.") }
        panels.walkthroughModel.onStop = { [weak self] in self?.stopEverything() }

        speechQueue.onSegmentStart = { [weak self] segment in self?.beginSegment(segment) }

        hotkeys.onPushToTalkPressed = { [weak self] in self?.pushToTalkPressed() }
        hotkeys.onPushToTalkReleased = { [weak self] in self?.pushToTalkReleased() }
        hotkeys.onPushToTalkCancelled = { [weak self] in self?.pushToTalkCancelled() }
        hotkeys.onControlDoubleTapped = { [weak self] in self?.showAskBar() }
        hotkeys.onEscapePressed = { [weak self] in self?.escapePressed() }
        startHotkeysWhenPermitted()

        clickMonitor.onClick = { [weak self] clickLocation in self?.handleLearnerClick(at: clickLocation) }
        clickMonitor.start()

        brain.onEvent = { [weak self] event in self?.handleBrainEvent(event) }
        startBrain()

        settingsObservation = settings.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applySettingsChanges() }

        Task { await TranscriberFactory.prepareModels(languageCode: settings.languageCode) }
        // Load the on-device voice now, so the first answer does not wait for it.
        if speechPlayer.usesNeuralVoice && !speechPlayer.usesElevenLabs { LocalNeuralVoice.shared.warmUp() }
    }

    func startBrain() {
        do {
            try brain.start()
            sendBrainConfiguration()
            brainStatusText = "Connecting to Claude…"
        } catch {
            brainStatusText = error.localizedDescription
            lastErrorText = error.localizedDescription
        }
    }

    private func startHotkeysWhenPermitted() {
        hasHotkeyAccess = hotkeys.start()
        guard !hasHotkeyAccess, hotkeyRetryTimer == nil else { return }
        hotkeyRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if self.hotkeys.start() {
                    self.hasHotkeyAccess = true
                    timer.invalidate()
                    self.hotkeyRetryTimer = nil
                }
            }
        }
    }

    private func sendBrainConfiguration() {
        brain.configure(
            model: settings.modelIdentifier,
            effort: settings.reasoningEffort,
            learnerProfile: settings.learnerProfileMarkdown,
            memory: memory.memoryMarkdown,
            language: settings.languageCode,
            actionsEnabled: settings.actionsEnabled,
            thinksBeforeAnswering: settings.thinksBeforeAnswering
        )
    }

    private func applySettingsChanges() {
        overlayState.cursorColor = settings.cursorColor
        overlayState.isBuddyAlwaysVisible = settings.alwaysShowsCursorBuddy
        sendBrainConfiguration()
    }

    // MARK: - Activity

    /// True from push-to-talk press to release. While true, nothing else may
    /// change the listening state, or the release would be ignored.
    private var isPushToTalkActive = false

    private func updateActivity(_ newActivity: Activity) {
        guard !isPushToTalkActive || newActivity == .listening else { return }
        activity = newActivity
    }

    private func updateVoiceState(_ newVoiceState: OverlayState.VoiceState) {
        guard !isPushToTalkActive || newVoiceState == .listening else { return }
        overlayState.voiceState = newVoiceState
    }

    /// What to show while a turn is open but Pointwise is not speaking.
    private var restingActivityDuringTurn: Activity {
        activeStepWait != nil || panels.isQuizWaitingForAnswer ? .waitingForLearner : .thinking
    }

    // MARK: - Push to talk

    func pushToTalkPressed() {
        guard !isPushToTalkActive else { return }
        idleCleanupTask?.cancel()
        panels.hideAskBar()
        // Hold back speech while the learner talks; decide what to do on release.
        heldSegmentsWhileLearnerTalks = []
        speechQueue.stopAll()
        overlayState.isInteractionActive = true
        overlayState.voiceState = .listening
        overlayState.captionText = ""
        activity = .listening
        isPushToTalkActive = true
        startPaintTrail()

        pendingTranscriptionSessionTask = Task { [weak self] in
            guard let self else { return nil }
            guard await self.ensureMicrophoneAccess() else {
                self.showProblem("Pointwise needs microphone access. Open Settings → Privacy & Security → Microphone.")
                return nil
            }
            do {
                // Start the microphone first so no words are lost while the speech model loads.
                self.microphone.onAudioLevel = { [weak self] audioLevel in self?.overlayState.audioLevel = audioLevel }
                try self.microphone.start()
                let session = try await TranscriberFactory.makeSession(languageCode: self.settings.languageCode)
                self.microphone.attach(session)
                return session
            } catch {
                _ = self.microphone.stop()
                self.showProblem("Pointwise could not start listening: \(error.localizedDescription)")
                return nil
            }
        }
    }

    func pushToTalkReleased() {
        guard isPushToTalkActive else { return }
        isPushToTalkActive = false
        stopPaintTrailSampling()
        overlayState.voiceState = .thinking
        activity = .thinking
        let sessionTask = pendingTranscriptionSessionTask
        pendingTranscriptionSessionTask = nil
        Task { [weak self] in
            guard let self else { return }
            _ = await sessionTask?.value
            guard let session = self.microphone.stop() else {
                self.finishWithoutQuestion()
                return
            }
            let transcript = await session.finish()
            self.handleLearnerInput(transcript, inputMode: "voice")
        }
    }

    /// Control+Option plus another key is someone else's shortcut: stop listening and drop the audio.
    func pushToTalkCancelled() {
        guard isPushToTalkActive else { return }
        isPushToTalkActive = false
        stopPaintTrailSampling()
        let sessionTask = pendingTranscriptionSessionTask
        pendingTranscriptionSessionTask = nil
        Task { [weak self] in
            guard let self else { return }
            _ = await sessionTask?.value
            self.microphone.stop()?.cancel()
            self.finishWithoutQuestion(showsHint: false)
        }
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func finishWithoutQuestion(showsHint: Bool = true) {
        overlayState.clearPaintTrail()
        if let heldSegments = heldSegmentsWhileLearnerTalks, !heldSegments.isEmpty {
            heldSegmentsWhileLearnerTalks = nil
            speechQueue.enqueue(heldSegments)
            return
        }
        heldSegmentsWhileLearnerTalks = nil
        if currentTurnId == nil {
            overlayState.voiceState = .idle
            activity = activeStepWait == nil ? .idle : .waitingForLearner
            if showsHint { overlayState.flashBubble("I didn't catch that", duration: 1.5) }
            scheduleIdleCleanup()
        } else {
            let restingActivity = restingActivityDuringTurn
            overlayState.voiceState = restingActivity == .waitingForLearner ? .idle : .thinking
            activity = restingActivity
        }
    }

    // MARK: - Paint trail (circle things while talking)

    private func startPaintTrail() {
        overlayState.startPaintTrail()
        paintTrailTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.overlayState.appendPaintTrailPoint(self.pointerLocationProvider())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        paintTrailTimer = timer
    }

    private func stopPaintTrailSampling() {
        paintTrailTimer?.invalidate()
        paintTrailTimer = nil
    }

    /// True when the pointer moved enough while talking to count as a drawing.
    private var meaningfulPaintTrail: [CGPoint]? {
        let trail = overlayState.paintTrail
        guard trail.count > 8 else { return nil }
        let xValues = trail.map(\.x)
        let yValues = trail.map(\.y)
        let span = max((xValues.max() ?? 0) - (xValues.min() ?? 0), (yValues.max() ?? 0) - (yValues.min() ?? 0))
        return span > 40 ? trail : nil
    }

    // MARK: - Typed questions

    func showAskBar() {
        guard activity != .listening else { return }
        panels.showAskBar()
    }

    // MARK: - Routing learner input

    /// Decides what a spoken or typed message means given what Pointwise is doing.
    func handleLearnerInput(_ rawText: String, inputMode: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            finishWithoutQuestion()
            return
        }

        if panels.isQuizWaitingForAnswer, let choiceIndex = Self.quizChoiceIndex(from: text, choices: panels.quizModel.choices) {
            heldSegmentsWhileLearnerTalks = nil
            conversation.append(ConversationEntry(speaker: .learner, text: text))
            panels.answerQuiz(choiceIndex: choiceIndex)
            overlayState.voiceState = .thinking
            activity = .thinking
            overlayState.clearPaintTrail()
            return
        }

        if activeStepWait != nil {
            conversation.append(ConversationEntry(speaker: .learner, text: text))
            heldSegmentsWhileLearnerTalks = nil
            overlayState.clearPaintTrail()
            overlayState.voiceState = .thinking
            activity = .thinking
            if Self.isContinueCommand(text) {
                resolveStepWait(with: "The learner said \"\(text)\" to continue.")
            } else {
                resolveStepWait(with: "The learner asked a question instead of finishing the step: \"\(text)\". Answer it briefly, then continue the walkthrough from this step.")
            }
            return
        }

        startTurn(question: text, inputMode: inputMode)
    }

    static func isContinueCommand(_ text: String) -> Bool {
        let normalizedText = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let continueWords = ["continue", "next", "done", "ok", "okay", "i did it", "did it", "got it", "go on", "ready", "next step", "finished", "keep going"]
        return continueWords.contains { normalizedText == $0 || normalizedText.hasPrefix($0 + " ") || normalizedText.hasSuffix(" " + $0) }
    }

    static func quizChoiceIndex(from text: String, choices: [String]) -> Int? {
        let normalizedText = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        let letters = ["a", "b", "c", "d", "e"]
        for (letterIndex, letter) in letters.enumerated() where letterIndex < choices.count {
            if normalizedText == letter || normalizedText == "\(letter)." || normalizedText.hasSuffix(" \(letter)") || normalizedText.hasPrefix("\(letter) ")
                || normalizedText.contains("answer \(letter)") || normalizedText.contains("option \(letter)") || normalizedText.contains("choice \(letter)") {
                return letterIndex
            }
        }
        let ordinals = ["first", "second", "third", "fourth", "fifth"]
        if let ordinalIndex = ordinals.firstIndex(where: { normalizedText.contains($0) }), ordinalIndex < choices.count { return ordinalIndex }
        return choices.firstIndex { normalizedText.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
    }

    // MARK: - Turns

    private func startTurn(question: String, inputMode: String) {
        guard brain.isRunning else {
            conversation.append(ConversationEntry(speaker: .learner, text: question))
            showProblem(lastErrorText ?? "Pointwise's Claude connection is not running. Open Settings → Advanced and choose Restart Claude connection.")
            return
        }
        if currentTurnId != nil {
            brain.cancel()
        }
        // Nothing from an earlier turn may act after a new question.
        resolveStepWait(with: "The learner asked something new.")
        endClickQuiz(answer: nil)
        panels.dismissAll()
        speechQueue.stopAll()
        heldSegmentsWhileLearnerTalks = nil
        idleCleanupTask?.cancel()
        responseParser.reset()
        recentSpokenSentences = []
        sentencesSpokenSinceLastStepWait = 0
        sentencesSpokenSinceLastAction = 0
        sentencesSpokenSinceWhiteboard = nil
        overlayState.returnToPointer()
        overlayState.clearAnnotations()
        overlayState.isInteractionActive = true
        overlayState.voiceState = .thinking
        overlayState.captionText = ""
        overlayState.activityText = nil
        activity = .thinking
        lastErrorText = nil
        conversation.append(ConversationEntry(speaker: .learner, text: question))

        let turnId = UUID().uuidString
        currentTurnId = turnId
        let paintTrail = meaningfulPaintTrail
        lastPaintTrailBounds = paintTrail.map { trail in
            trail.dropFirst().reduce(CGRect(origin: trail[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        overlayState.clearPaintTrail()

        Task { [weak self] in
            guard let self else { return }
            var screens: [CapturedScreen] = []
            var captureProblem: String?
            do {
                screens = try await self.screenSource.captureScreens(pointerLocation: self.pointerLocationProvider())
                if let paintTrail { screens = screens.map { ScreenAnnotator.drawTrail(paintTrail, on: $0) } }
            } catch {
                captureProblem = "Screen capture is unavailable (\(error.localizedDescription)). Answer without seeing the screen and mention that Screen Recording permission is needed to see it."
            }
            let frontAppDescription = await self.frontAppDescriptionProvider()
            let simulationValues = await self.panels.whiteboard.currentSimulationValues()
            guard self.currentTurnId == turnId else { return }
            self.latestScreens = screens
            let context = self.buildTurnContext(screens: screens, paintTrail: paintTrail, captureProblem: captureProblem, frontAppDescription: frontAppDescription, simulationValues: simulationValues)
            self.brain.ask(turnId: turnId, text: question, screens: screens, context: context, inputMode: inputMode)
        }
    }

    private func buildTurnContext(screens: [CapturedScreen], paintTrail: [CGPoint]?, captureProblem: String?, frontAppDescription: String, simulationValues: [String: Double]) -> String {
        var lines = ["Front app: \(frontAppDescription)"]
        let pointerLocation = pointerLocationProvider()
        if let cursorScreen = screens.first(where: { $0.displayFrame.contains(pointerLocation) }) {
            let pointerInPixels = cursorScreen.screenshotPoint(fromGlobal: pointerLocation)
            lines.append("Mouse pointer: (\(Int(pointerInPixels.x)), \(Int(pointerInPixels.y))) on screen \(cursorScreen.screenNumber)")
        }
        if let paintTrail, let cursorScreen = screens.first(where: { $0.displayFrame.contains(paintTrail[0]) }) ?? screens.first {
            let trailPixels = paintTrail.map { cursorScreen.screenshotPoint(fromGlobal: $0) }
            let minX = Int(trailPixels.map(\.x).min() ?? 0), maxX = Int(trailPixels.map(\.x).max() ?? 0)
            let minY = Int(trailPixels.map(\.y).min() ?? 0), maxY = Int(trailPixels.map(\.y).max() ?? 0)
            lines.append("While talking, the learner drew with the pointer (shown as a translucent stroke on screen \(cursorScreen.screenNumber)) around x \(minX)–\(maxX), y \(minY)–\(maxY). They probably mean what they circled or traced.")
        }
        if panels.isWalkthroughActive {
            lines.append("A walkthrough is in progress: \"\(panels.walkthroughModel.title)\", on step \(panels.walkthroughModel.currentStepIndex + 1).")
        }
        if let openSimulation = panels.whiteboard.openSimulation, panels.whiteboard.isVisible {
            let valueList = simulationValues.keys.sorted().map { "\($0)=\(String(format: "%g", simulationValues[$0] ?? 0))" }.joined(separator: ", ")
            lines.append("The simulation \"\(openSimulation.title)\" (\(openSimulation.kind)) is open next to the cursor. Current values: \(valueList.isEmpty ? "unknown" : valueList). Use [SIM:...] tags to change them.")
        } else if panels.whiteboard.isVisible {
            lines.append("The whiteboard panel is open.")
        }
        if let captureProblem { lines.append(captureProblem) }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .full
        lines.append("Today is \(dateFormatter.string(from: Date())).")
        return lines.joined(separator: "\n")
    }

    // MARK: - Brain events

    private func handleBrainEvent(_ event: BrainEvent) {
        switch event {
        case .ready(let model, let authSource):
            isBrainReady = true
            let modelName = ClaudeModelOption.all.first { model.hasPrefix($0.id) }?.displayName ?? model
            brainStatusText = authSource == "none" ? "Ready · \(modelName) via your Claude Code login" : "Ready · \(modelName)"
        case .textDelta(let turnId, let text):
            guard turnId == currentTurnId else { return }
            enqueueSegments(responseParser.append(text))
        case .textBlockEnd(let turnId):
            guard turnId == currentTurnId else { return }
            enqueueSegments(responseParser.finish())
        case .activity(let turnId, let text):
            guard turnId == currentTurnId else { return }
            overlayState.activityText = text
        case .toolCall(let turnId, let callId, let name, let input):
            guard turnId == currentTurnId else {
                brain.sendToolResult(callId: callId, text: "This turn was cancelled.", isError: true)
                return
            }
            // Run tools one at a time, in order: Claude may send several in one message
            // (click, then type, then press Return) and they must not overlap.
            let previousTool = toolQueueTail
            toolQueueTail = Task { [weak self] in
                await previousTool?.value
                await self?.runTool(callId: callId, name: name, input: input)
            }
        case .turnDone(let turnId, let text, let wasCancelled):
            guard turnId == currentTurnId else { return }
            enqueueSegments(responseParser.finish())
            finishTurn(spokenText: text, wasCancelled: wasCancelled)
        case .turnError(let turnId, let message):
            guard turnId == currentTurnId else { return }
            showProblem(message)
        case .summary(let requestId, let markdown):
            guard requestId == pendingSummaryRequestId else { return }
            pendingSummaryRequestId = nil
            studyNotesMarkdown = markdown
            saveCurrentLesson()
        case .log(let level, let message):
            if level != "info" || message.contains("error") { PointwiseLog.write("brain \(level): \(message)") }
        case .processExited(let status):
            isBrainReady = false
            brainStatusText = "Claude restarting…"
            PointwiseLog.write("brain exited with status \(status)")
            if currentTurnId != nil { showProblem("Pointwise's connection to Claude restarted. Please ask again.") }
        }
    }

    private func enqueueSegments(_ incomingSegments: [SpokenSegment]) {
        // Keep drawing commands, but never read Claude's pixel-coordinate notes aloud.
        let segments = incomingSegments.map { segment in
            segment.looksLikeInternalNote ? SpokenSegment(text: "", commands: segment.commands) : segment
        }
        guard !segments.isEmpty else { return }
        if heldSegmentsWhileLearnerTalks != nil {
            heldSegmentsWhileLearnerTalks?.append(contentsOf: segments)
        } else {
            speechQueue.enqueue(segments)
        }
    }

    /// Runs when a sentence starts: show the caption and perform its drawings.
    private func beginSegment(_ segment: SpokenSegment) {
        if segment.hasSpeech {
            updateVoiceState(.speaking)
            overlayState.activityText = nil
            overlayState.captionText = segment.text
            recentSpokenSentences = Array((recentSpokenSentences + [segment.text]).suffix(4))
            sentencesSpokenSinceLastStepWait += 1
            sentencesSpokenSinceLastAction += 1
            if let spokenCount = sentencesSpokenSinceWhiteboard { sentencesSpokenSinceWhiteboard = spokenCount + 1 }
            if activity != .waitingForLearner { updateActivity(.speaking) }
        }
        for command in segment.commands { perform(command) }
    }

    private func perform(_ command: ScreenAnnotationCommand) {
        if command.kind == .simulation {
            panels.whiteboard.setSimulationValues(command.simulationValues)
            return
        }
        guard let screen = screenForCommand(command) else {
            if command.kind == .clear { overlayState.clearAnnotations() }
            return
        }
        let numbers = command.numbers
        func globalPoint(_ xIndex: Int) -> CGPoint {
            screen.globalPoint(fromScreenshotX: numbers[xIndex], screenshotY: numbers[xIndex + 1])
        }
        switch command.kind {
        case .point:
            overlayState.point(at: globalPoint(0), label: command.label)
        case .circle:
            let center = globalPoint(0)
            let radius = screen.points(fromScreenshotLength: numbers[2])
            overlayState.addCircle(center: center, radius: radius, label: command.label)
            overlayState.visit(CGPoint(x: center.x + radius * 1.4, y: center.y - radius * 0.35))
        case .box:
            let firstCorner = globalPoint(0)
            let secondCorner = globalPoint(2)
            overlayState.addBox(from: firstCorner, to: secondCorner, label: command.label)
            overlayState.visit(CGPoint(x: max(firstCorner.x, secondCorner.x) + 6, y: min(firstCorner.y, secondCorner.y) - 6))
        case .underline:
            // Claude often gives the middle of the text line; sit just below it so it never reads as a strikethrough.
            let underlineDrop = screen.points(fromScreenshotLength: 7)
            let underlineStart = globalPoint(0).applying(CGAffineTransform(translationX: 0, y: -underlineDrop))
            let underlineEnd = globalPoint(2).applying(CGAffineTransform(translationX: 0, y: -underlineDrop))
            overlayState.addUnderline(from: underlineStart, to: underlineEnd)
            overlayState.visit(underlineEnd)
        case .arrow:
            overlayState.addArrow(from: globalPoint(0), to: globalPoint(2), label: command.label)
            overlayState.visit(globalPoint(2))
        case .spotlight:
            let firstCorner = globalPoint(0)
            let secondCorner = globalPoint(2)
            overlayState.showSpotlight(around: CGRect(x: min(firstCorner.x, secondCorner.x), y: min(firstCorner.y, secondCorner.y), width: abs(secondCorner.x - firstCorner.x), height: abs(secondCorner.y - firstCorner.y)), label: command.label)
            overlayState.visit(CGPoint(x: max(firstCorner.x, secondCorner.x) + 10, y: max(firstCorner.y, secondCorner.y) + 6))
        case .simulation:
            break
        case .clear:
            overlayState.clearAnnotations()
        }
    }

    private func screenForCommand(_ command: ScreenAnnotationCommand) -> CapturedScreen? {
        if let screenNumber = command.screenNumber, let numberedScreen = latestScreens.first(where: { $0.screenNumber == screenNumber }) {
            return numberedScreen
        }
        return latestScreens.first(where: \.isCursorScreen) ?? latestScreens.first
    }

    private func finishTurn(spokenText: String, wasCancelled: Bool) {
        let finishedTurnId = currentTurnId
        PointwiseLog.write("turn finished: \(spokenText.count) characters\(wasCancelled ? ", cancelled" : "")")
        if !wasCancelled, !spokenText.isEmpty {
            let readableText = Self.removingTags(from: spokenText)
            conversation.append(ConversationEntry(speaker: .pointwise, text: readableText))
            if !settings.speaksAloud || SpeechPlayer.isSystemOutputMuted() {
                // Muted Mac: put the answer on the clipboard so it is not lost.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(readableText, forType: .string)
            }
            saveCurrentLesson()
        }
        Task { [weak self] in
            guard let self else { return }
            await self.speechQueue.waitUntilIdle()
            guard self.currentTurnId == finishedTurnId else { return }
            self.currentTurnId = nil
            self.updateVoiceState(.idle)
            self.overlayState.activityText = nil
            self.updateActivity(.idle)
            self.scheduleIdleCleanup()
        }
    }

    /// After a quiet moment: fade captions and drawings, and fly the buddy home.
    private func scheduleIdleCleanup() {
        idleCleanupTask?.cancel()
        idleCleanupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.currentTurnId == nil else { return }
            self.overlayState.captionText = ""
            self.overlayState.returnToPointer()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, self.currentTurnId == nil else { return }
            self.overlayState.clearAnnotations()
            self.overlayState.isInteractionActive = false
        }
    }

    private func showProblem(_ message: String) {
        lastErrorText = message
        PointwiseLog.write("problem: \(message)")
        speechQueue.stopAll()
        currentTurnId = nil
        updateVoiceState(.idle)
        overlayState.captionText = message
        overlayState.activityText = nil
        updateActivity(.idle)
        overlayState.flashBubble("Something went wrong", duration: 2)
        scheduleIdleCleanup()
    }

    /// Turns an action description such as "Click the search box" into "Watch: I'll click the search box."
    static func narration(forAction actionDescription: String) -> String {
        let trimmedDescription = actionDescription.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let firstCharacter = trimmedDescription.first else { return "Watch this." }
        return "Watch: I'll \(firstCharacter.lowercased())\(trimmedDescription.dropFirst())."
    }

    static func removingTags(from text: String) -> String {
        text.replacingOccurrences(of: #"\[(POINT|CIRCLE|BOX|UNDERLINE|ARROW|SPOTLIGHT|SIM|CLEAR)[^\]]*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Stop and escape

    func escapePressed() {
        if panels.isAskBarVisible {
            panels.hideAskBar()
            return
        }
        stopEverything()
    }

    func stopEverything() {
        isPushToTalkActive = false
        if currentTurnId != nil { brain.cancel() }
        currentTurnId = nil
        speechQueue.stopAll()
        resolveStepWait(with: "The learner stopped the lesson.")
        endClickQuiz(answer: nil)
        panels.dismissAll()
        panels.hideWalkthrough()
        _ = microphone.stop()
        stopPaintTrailSampling()
        overlayState.voiceState = .idle
        overlayState.captionText = ""
        overlayState.activityText = nil
        overlayState.returnToPointer()
        overlayState.clearAnnotations()
        activity = .idle
        scheduleIdleCleanup()
    }

    // MARK: - Lessons

    func startNewLesson() {
        stopEverything()
        saveCurrentLesson()
        conversation.removeAll()
        studyNotesMarkdown = nil
        currentLessonIdentifier = UUID()
        currentLessonStartedAt = Date()
        actionsAllowedThisLesson = false
        panels.whiteboard.hide()
        brain.reset()
    }

    /// Opens the lesson's website, then asks Pointwise to teach its goal as a walkthrough.
    func startLesson(_ lesson: LessonPlan) {
        startNewLesson()
        Task { [weak self] in
            guard let self else { return }
            if let websiteURL = URL(string: lesson.websiteURL), ["http", "https"].contains(websiteURL.scheme?.lowercased() ?? "") {
                self.urlOpener(websiteURL)
                self.overlayState.flashBubble("opening \(lesson.title.lowercased())…", duration: 2)
                // Give the page time to load before Pointwise looks at it.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            self.handleLearnerInput(lesson.openingRequest, inputMode: "typed")
        }
    }

    func makeStudyNotes() {
        guard !conversation.isEmpty else { return }
        let requestId = UUID().uuidString
        pendingSummaryRequestId = requestId
        studyNotesMarkdown = nil
        let transcript = conversation.map { "\($0.speaker == .learner ? "Learner" : "Pointwise"): \($0.text)" }.joined(separator: "\n")
        brain.summarize(requestId: requestId, transcript: transcript)
    }

    private func saveCurrentLesson() {
        guard !conversation.isEmpty else { return }
        let firstQuestion = conversation.first { $0.speaker == .learner }?.text ?? "Lesson"
        memory.saveLesson(SavedLesson(
            id: currentLessonIdentifier,
            startedAt: currentLessonStartedAt,
            title: String(firstQuestion.prefix(60)),
            entries: conversation,
            studyNotesMarkdown: studyNotesMarkdown
        ))
    }

    // MARK: - Clicks during walkthroughs

    func handleLearnerClick(at globalLocation: CGPoint) {
        guard var stepWait = activeStepWait, stepWait.expectation == "click_target" else { return }
        guard let targetGlobalPoint = stepWait.targetGlobalPoint else {
            resolveStepWait(with: "The learner clicked.", afterDelay: 0.9)
            return
        }
        let distance = hypot(globalLocation.x - targetGlobalPoint.x, globalLocation.y - targetGlobalPoint.y)
        if distance <= 70 {
            resolveStepWait(with: "The learner clicked the target.", afterDelay: 0.9)
        } else {
            stepWait.offTargetClickCount += 1
            activeStepWait = stepWait
            if stepWait.offTargetClickCount >= 2 {
                resolveStepWait(with: "The learner clicked somewhere else, about \(Int(distance)) points away from the target. Check the screen and guide them again.", afterDelay: 0.9)
            }
        }
    }

    private func resolveStepWait(with outcome: String, afterDelay delaySeconds: Double = 0) {
        guard let stepWait = activeStepWait else { return }
        activeStepWait = nil
        Task { [weak self] in
            if delaySeconds > 0 { try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000)) }
            stepWait.continuation.resume(returning: outcome)
            self?.updateVoiceState(.thinking)
            if self?.activity == .waitingForLearner { self?.updateActivity(.thinking) }
        }
    }

    // MARK: - Tools

    /// Tools check this after every wait, so nothing from a stopped or
    /// replaced turn can speak, open, or click.
    private func isStale(_ toolTurnId: String?) -> Bool { toolTurnId == nil || toolTurnId != currentTurnId }

    private static let staleTurnResult: (text: String, screens: [CapturedScreen], isError: Bool) =
        ("The learner stopped or changed the subject. Do nothing more for this request.", [], true)

    private func runTool(callId: String, name: String, input: [String: Any]) async {
        PointwiseLog.write("tool: \(name)")
        let toolTurnId = currentTurnId
        let result: (text: String, screens: [CapturedScreen], isError: Bool)
        switch name {
        case "look_at_screen":
            result = await toolLookAtScreen()
        case "start_walkthrough":
            let steps = (input["steps"] as? [String]) ?? []
            // A streamed "say" is already being spoken: show the checklist while it plays.
            if !Self.sayWasStreamed(input) { await speechQueue.waitUntilIdle() }
            guard !isStale(toolTurnId) else { return brain.sendToolResult(callId: callId, text: Self.staleTurnResult.text, isError: true) }
            panels.startWalkthrough(title: input["title"] as? String ?? "Walkthrough", steps: steps)
            await speakToolSay(input)
            result = ("The checklist is showing with \(steps.count) steps. Now call wait_for_step for step 1 with its spoken instruction in \"say\".", [], false)
        case "wait_for_step":
            result = await toolWaitForStep(input, toolTurnId: toolTurnId)
        case "finish_walkthrough":
            await speechQueue.waitUntilIdle()
            panels.finishWalkthrough(recap: input["recap"] as? String ?? "All done!")
            await speakToolSay(input)
            result = ("The walkthrough is marked complete.", [], false)
        case "show_whiteboard":
            if !Self.sayWasStreamed(input) { await speechQueue.waitUntilIdle() }
            guard !isStale(toolTurnId) else { return brain.sendToolResult(callId: callId, text: Self.staleTurnResult.text, isError: true) }
            await panels.whiteboard.show(
                title: input["title"] as? String ?? "Whiteboard",
                markdown: input["markdown"] as? String ?? "",
                near: pointerLocationProvider(),
                avoiding: learnerAttentionRect,
                screenFrames: screenSource.displayFrames
            )
            // A streamed explanation is already under way, so the board counts as explained.
            sentencesSpokenSinceWhiteboard = Self.sayWasStreamed(input) ? 1 : 0
            await speakToolSay(input)
            await speechQueue.waitUntilIdle()
            result = ("The whiteboard is showing and your explanation was spoken.", [], false)
        case "show_simulation":
            result = await toolShowSimulation(input, toolTurnId: toolTurnId)
        case "click_quiz":
            result = await toolClickQuiz(input, toolTurnId: toolTurnId)
        case "quiz":
            result = await toolQuiz(input, toolTurnId: toolTurnId)
        case "remember":
            let fact = input["fact"] as? String ?? ""
            memory.remember(fact)
            result = ("Saved to memory.", [], false)
        case "open_url":
            result = await toolOpenURL(input, toolTurnId: toolTurnId)
        case "do_action":
            result = await toolDoAction(input, toolTurnId: toolTurnId)
        default:
            result = ("Unknown tool \(name).", [], true)
        }
        brain.sendToolResult(callId: callId, text: result.text, screens: result.screens, isError: result.isError)
    }

    /// Where the learner is looking: what they circled, Pointwise's marks, and the spotlight.
    private var learnerAttentionRect: CGRect? {
        var attentionRect = lastPaintTrailBounds
        func include(_ rect: CGRect) { attentionRect = attentionRect.map { $0.union(rect) } ?? rect }
        for annotation in overlayState.annotations where annotation.fadeOutStartedAt == nil {
            for stroke in annotation.strokes {
                for point in stroke { include(CGRect(origin: point, size: .zero)) }
            }
        }
        if let spotlight = overlayState.spotlight, spotlight.fadeOutStartedAt == nil { include(spotlight.rect) }
        return attentionRect
    }

    /// True when the brain already streamed this tool's "say" into the speech queue.
    static func sayWasStreamed(_ input: [String: Any]) -> Bool {
        (input["say_streamed"] as? Bool) == true
    }

    /// Speaks a tool's "say" text (drawing tags included) and waits until it is done.
    /// Claude's words between tool calls are not delivered as text, so tools carry them.
    /// Usually the brain has streamed it already; then this only waits for it to finish.
    private func speakToolSay(_ input: [String: Any]) async {
        if Self.sayWasStreamed(input) {
            await speechQueue.waitUntilIdle()
            return
        }
        guard let sayText = input["say"] as? String, !sayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var sayParser = StreamingResponseParser()
        enqueueSegments(sayParser.append(sayText) + sayParser.finish())
        await speechQueue.waitUntilIdle()
    }

    private func toolLookAtScreen() async -> (text: String, screens: [CapturedScreen], isError: Bool) {
        do {
            let screens = try await screenSource.captureScreens(pointerLocation: pointerLocationProvider())
            latestScreens = screens
            return ("Here is the screen right now.", screens, false)
        } catch {
            return ("Could not capture the screen: \(error.localizedDescription)", [], true)
        }
    }

    private func toolWaitForStep(_ input: [String: Any], toolTurnId: String?) async -> (text: String, screens: [CapturedScreen], isError: Bool) {
        await speechQueue.waitUntilIdle()
        await speakToolSay(input)
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        let stepIndex = (input["step_index"] as? NSNumber)?.intValue ?? panels.walkthroughModel.currentStepIndex
        // Never leave the learner waiting without an instruction: if Claude
        // said nothing since the last step, read the checklist step aloud.
        if sentencesSpokenSinceLastStepWait == 0, panels.walkthroughModel.steps.indices.contains(stepIndex) {
            enqueueSegments([SpokenSegment(text: "Next step: \(panels.walkthroughModel.steps[stepIndex]).", commands: [])])
            await speechQueue.waitUntilIdle()
            guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        }
        sentencesSpokenSinceLastStepWait = 0
        let expectation = input["expect"] as? String ?? "click_target"
        let timeoutSeconds = (input["timeout_seconds"] as? NSNumber)?.doubleValue ?? 90

        var targetGlobalPoint: CGPoint?
        if let targetX = (input["target_x"] as? NSNumber)?.doubleValue, let targetY = (input["target_y"] as? NSNumber)?.doubleValue {
            let targetScreenNumber = (input["target_screen"] as? NSNumber)?.intValue
            let targetScreen = latestScreens.first { $0.screenNumber == targetScreenNumber } ?? latestScreens.first(where: \.isCursorScreen) ?? latestScreens.first
            targetGlobalPoint = targetScreen?.globalPoint(fromScreenshotX: targetX, screenshotY: targetY)
        }

        panels.setWalkthroughStep(stepIndex, isWaiting: true)
        updateVoiceState(.idle)
        updateActivity(.waitingForLearner)
        // A fresh baseline of the display that matters (the target's, else the pointer's),
        // so "the screen changed" never compares two different displays or an old image.
        var baselineFingerprint: [UInt8]?
        var baselineDisplayFrame: CGRect?
        if expectation == "screen_change", let baselineScreens = try? await screenSource.captureScreens(pointerLocation: pointerLocationProvider()) {
            let focusPoint = targetGlobalPoint ?? pointerLocationProvider()
            let baselineScreen = baselineScreens.first { $0.displayFrame.contains(focusPoint) } ?? baselineScreens.first
            baselineFingerprint = baselineScreen.flatMap { ScreenAnnotator.fingerprint(of: $0.jpegData) }
            baselineDisplayFrame = baselineScreen?.displayFrame
        }
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }

        let outcome: String = await withCheckedContinuation { continuation in
            activeStepWait = StepWait(stepIndex: stepIndex, targetGlobalPoint: targetGlobalPoint, expectation: expectation, baselineFingerprint: baselineFingerprint, baselineDisplayFrame: baselineDisplayFrame, continuation: continuation)
            startStepWaitWatchers(timeoutSeconds: timeoutSeconds)
        }

        if outcome.contains("stopped the lesson") || outcome.contains("interrupted") {
            return (outcome, [], true)
        }
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        let screens = await captureSettledScreens()
        latestScreens = screens
        let lowercasedOutcome = outcome.lowercased()
        if lowercasedOutcome.contains("clicked the target") || lowercasedOutcome.contains("continue") || lowercasedOutcome.contains("screen changed") {
            panels.completeWalkthroughStep(stepIndex)
            overlayState.returnToPointer()
        }
        return (outcome + " Fresh screenshot attached.", screens, false)
    }

    /// Watches for a timeout and, for `screen_change` steps, for the screen to change.
    private func startStepWaitWatchers(timeoutSeconds: Double) {
        let startedAt = Date()
        Task { [weak self] in
            while let self, let stepWait = self.activeStepWait {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard self.activeStepWait?.identifier == stepWait.identifier else { return }
                if Date().timeIntervalSince(startedAt) > timeoutSeconds {
                    self.resolveStepWait(with: "The learner did not finish the step within \(Int(timeoutSeconds)) seconds. Check the screen and offer more help.")
                    return
                }
                guard stepWait.expectation == "screen_change",
                      let baselineFingerprint = stepWait.baselineFingerprint,
                      let screens = try? await self.screenSource.captureScreens(pointerLocation: self.pointerLocationProvider()),
                      self.activeStepWait?.identifier == stepWait.identifier,
                      let sameDisplay = screens.first(where: { $0.displayFrame == stepWait.baselineDisplayFrame }),
                      let currentFingerprint = ScreenAnnotator.fingerprint(of: sameDisplay.jpegData) else { continue }
                let difference = ScreenAnnotator.difference(between: baselineFingerprint, and: currentFingerprint)
                if difference > 0.012 {
                    self.resolveStepWait(with: "The screen changed, so the learner probably did the step.", afterDelay: 0.6)
                    return
                }
            }
        }
    }

    /// Captures the screen after it stops changing (pages can be slow to load).
    private func captureSettledScreens() async -> [CapturedScreen] {
        var previousFingerprint: [UInt8]?
        var latestCapture: [CapturedScreen] = []
        for _ in 0..<5 {
            guard let screens = try? await screenSource.captureScreens(pointerLocation: pointerLocationProvider()) else { return latestScreens }
            latestCapture = screens
            let fingerprint = screens.first.flatMap { ScreenAnnotator.fingerprint(of: $0.jpegData) }
            if let previousFingerprint, let fingerprint, ScreenAnnotator.difference(between: previousFingerprint, and: fingerprint) < 0.004 { break }
            previousFingerprint = fingerprint
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return latestCapture
    }

    private func toolQuiz(_ input: [String: Any], toolTurnId: String?) async -> (text: String, screens: [CapturedScreen], isError: Bool) {
        await speechQueue.waitUntilIdle()
        await speakToolSay(input)
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        if sentencesSpokenSinceWhiteboard == 0 {
            // Ask once for a spoken explanation; a quiz right after a silent whiteboard teaches nothing.
            sentencesSpokenSinceWhiteboard = nil
            return ("Not shown yet: the learner has only seen the whiteboard and has not heard you explain it. Explain it out loud now in three or four short sentences, pointing or circling on the screen where it helps. Then call quiz again with the same question.", [], false)
        }
        let choices = input["choices"] as? [String] ?? []
        let correctIndex = (input["correct_index"] as? NSNumber)?.intValue ?? 0
        updateVoiceState(.idle)
        updateActivity(.waitingForLearner)
        let chosenIndex = await panels.presentQuiz(
            question: input["question"] as? String ?? "",
            choices: choices,
            correctIndex: correctIndex,
            explanation: input["explanation"] as? String ?? ""
        )
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        updateVoiceState(.thinking)
        updateActivity(.thinking)
        guard let chosenIndex, choices.indices.contains(chosenIndex) else {
            return ("The learner closed the quiz without answering.", [], false)
        }
        let letter = ["A", "B", "C", "D", "E"][min(chosenIndex, 4)]
        let verdict = chosenIndex == correctIndex ? "That is correct." : "That is not correct; the right answer is \(["A", "B", "C", "D", "E"][min(correctIndex, 4)])."
        return ("The learner chose \(letter): \"\(choices[chosenIndex])\". \(verdict) The card now shows your explanation. React briefly and warmly.", [], false)
    }

    private func toolShowSimulation(_ input: [String: Any], toolTurnId: String?) async -> (text: String, screens: [CapturedScreen], isError: Bool) {
        if !Self.sayWasStreamed(input) { await speechQueue.waitUntilIdle() }
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        let kind = input["kind"] as? String ?? "graph"
        let parameters = (input["params"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
        let isShown = await panels.whiteboard.showSimulation(
            kind: kind,
            title: input["title"] as? String ?? "Lab",
            parameters: parameters,
            expression: input["expression"] as? String,
            customHTML: input["html"] as? String,
            near: pointerLocationProvider(),
            avoiding: learnerAttentionRect,
            screenFrames: screenSource.displayFrames
        )
        guard isShown else {
            return ("Could not open a \(kind) simulation. For custom, include the full HTML page.", [], true)
        }
        sentencesSpokenSinceWhiteboard = Self.sayWasStreamed(input) ? 1 : 0
        await speakToolSay(input)
        let values = await panels.whiteboard.currentSimulationValues()
        let valueList = values.keys.sorted().map { "\($0)=\(String(format: "%g", values[$0] ?? 0))" }.joined(separator: ", ")
        return ("The \(kind) simulation is open and running. Current values: \(valueList.isEmpty ? "set by your page" : valueList). Change them in your speech with [SIM:name=value] tags; the learner can drag the sliders too.", [], false)
    }

    private func toolClickQuiz(_ input: [String: Any], toolTurnId: String?) async -> (text: String, screens: [CapturedScreen], isError: Bool) {
        await speechQueue.waitUntilIdle()
        await speakToolSay(input)
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        guard let targetX = (input["target_x"] as? NSNumber)?.doubleValue, let targetY = (input["target_y"] as? NSNumber)?.doubleValue else {
            return ("click_quiz needs target_x and target_y.", [], true)
        }
        let targetScreenNumber = (input["target_screen"] as? NSNumber)?.intValue
        guard let targetScreen = latestScreens.first(where: { $0.screenNumber == targetScreenNumber }) ?? latestScreens.first(where: \.isCursorScreen) ?? latestScreens.first else {
            return ("Pointwise cannot see the screen, so it cannot check a click.", [], true)
        }
        let targetGlobalPoint = targetScreen.globalPoint(fromScreenshotX: targetX, screenshotY: targetY)
        let targetRadiusPixels = (input["target_radius"] as? NSNumber)?.doubleValue ?? 45
        let targetRadius = targetScreen.points(fromScreenshotLength: targetRadiusPixels)
        let timeoutSeconds = (input["timeout_seconds"] as? NSNumber)?.doubleValue ?? 60

        // Nothing may cover what the learner has to click.
        panels.dismissQuiz()
        if let boardPanel = panels.whiteboard.panel, panels.whiteboard.isVisible,
           boardPanel.frame.insetBy(dx: -targetRadius, dy: -targetRadius).contains(targetGlobalPoint) {
            panels.whiteboard.hide()
        }
        overlayState.returnToPointer()
        overlayState.clickQuizPrompt = input["prompt"] as? String ?? "Click the answer"
        updateVoiceState(.idle)
        updateActivity(.waitingForLearner)
        overlayWindows.captureClicks { [weak self] clickLocation in self?.endClickQuiz(answer: clickLocation) }
        let clickLocation: CGPoint? = await withCheckedContinuation { continuation in
            let clickQuiz = ClickQuizWait(continuation: continuation)
            activeClickQuiz = clickQuiz
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if self?.activeClickQuiz?.identifier == clickQuiz.identifier { self?.endClickQuiz(answer: nil) }
            }
        }
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        updateVoiceState(.thinking)
        updateActivity(.thinking)
        guard let clickLocation else {
            return ("The learner did not click an answer within \(Int(timeoutSeconds)) seconds. Reveal the answer with a CIRCLE and explain it briefly.", [], false)
        }

        let distance = hypot(clickLocation.x - targetGlobalPoint.x, clickLocation.y - targetGlobalPoint.y)
        let isCorrect = distance <= targetRadius
        overlayState.addClickMark(at: clickLocation, isCorrect: isCorrect)
        // Show Claude exactly where the learner clicked, so it can say what they picked instead.
        let clickRing: [CGPoint] = (0...24).map { pointIndex in
            let angle = CGFloat(pointIndex) / 24 * 2 * .pi
            return CGPoint(x: clickLocation.x + 16 * cos(angle), y: clickLocation.y + 16 * sin(angle))
        }
        var screens = (try? await screenSource.captureScreens(pointerLocation: pointerLocationProvider())) ?? latestScreens
        screens = screens.map { $0.displayFrame.contains(clickLocation) ? ScreenAnnotator.drawTrail(clickRing, on: $0) : $0 }
        latestScreens = screens
        let clickPixels = targetScreen.screenshotPoint(fromGlobal: clickLocation)
        let pixelDistance = Int(hypot(clickPixels.x - targetX, clickPixels.y - targetY))
        let clickDescription = "(\(Int(clickPixels.x)), \(Int(clickPixels.y)))"
        if isCorrect {
            return ("Correct: the learner clicked inside the target, at \(clickDescription). A green check mark is showing. Praise them briefly and say why it is right.", screens, false)
        }
        return ("Not correct: the learner clicked at \(clickDescription) in screenshot pixels, about \(pixelDistance) pixels from the target. A red cross is showing there, and the fresh screenshot marks their click with a ring. Say kindly what they clicked instead, then give a hint and let them try again with click_quiz, or reveal the answer with a CIRCLE.", screens, false)
    }

    /// Ends a running click quiz with the learner's click, or nil when it was stopped or timed out.
    func endClickQuiz(answer clickLocation: CGPoint?) {
        guard let clickQuiz = activeClickQuiz else { return }
        activeClickQuiz = nil
        overlayWindows.captureClicks(nil)
        overlayState.clickQuizPrompt = nil
        clickQuiz.continuation.resume(returning: clickLocation)
    }

    private func toolOpenURL(_ input: [String: Any], toolTurnId: String?) async -> (text: String, screens: [CapturedScreen], isError: Bool) {
        guard let urlText = input["url"] as? String, let url = URL(string: urlText), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return ("Only http and https links can be opened.", [], true)
        }
        await speechQueue.waitUntilIdle()
        await speakToolSay(input)
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        urlOpener(url)
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        let screens = await captureSettledScreens()
        latestScreens = screens
        return ("Opened \(url.absoluteString). Fresh screenshot attached.", screens, false)
    }

    private func toolDoAction(_ input: [String: Any], toolTurnId: String?) async -> (text: String, screens: [CapturedScreen], isError: Bool) {
        guard settings.actionsEnabled else {
            return ("The learner has not turned on \"Pointwise can click and type for me\". Guide them to do it themselves.", [], true)
        }
        guard actionPerformer.canPerformActions else {
            return ("Pointwise needs Accessibility permission to click and type. Ask the learner to grant it in System Settings, and guide them for now.", [], true)
        }
        let actionDescription = input["description"] as? String ?? "do a step"
        await speechQueue.waitUntilIdle()
        if !settings.actionsAlwaysAllowed && !actionsAllowedThisLesson {
            switch await panels.requestActionPermission(description: actionDescription.prefix(1).uppercased() + actionDescription.dropFirst()) {
            case .notNow:
                return ("The learner said not now. Guide them to do it themselves.", [], false)
            case .allowOnce:
                actionsAllowedThisLesson = true
            case .alwaysAllow:
                settings.actionsAlwaysAllowed = true
            }
        }
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }

        let action = input["action"] as? String ?? "click"
        var targetGlobalPoint: CGPoint?
        if let actionX = (input["x"] as? NSNumber)?.doubleValue, let actionY = (input["y"] as? NSNumber)?.doubleValue {
            let screenNumber = (input["screen"] as? NSNumber)?.intValue
            let targetScreen = latestScreens.first { $0.screenNumber == screenNumber } ?? latestScreens.first(where: \.isCursorScreen) ?? latestScreens.first
            targetGlobalPoint = targetScreen?.globalPoint(fromScreenshotX: actionX, screenshotY: actionY)
        }
        if let targetGlobalPoint {
            overlayState.point(at: targetGlobalPoint, label: actionDescription)
        }
        await speakToolSay(input)
        if sentencesSpokenSinceLastAction == 0 {
            // Narrate like a teacher demonstrating, even if Claude did not.
            enqueueSegments([SpokenSegment(text: Self.narration(forAction: actionDescription), commands: [])])
            await speechQueue.waitUntilIdle()
        } else if targetGlobalPoint != nil {
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        guard !isStale(toolTurnId) else { return Self.staleTurnResult }
        sentencesSpokenSinceLastAction = 0

        switch action {
        case "click", "double_click":
            guard let targetGlobalPoint else { return ("A click needs x and y.", [], true) }
            await actionPerformer.click(at: targetGlobalPoint, clickCount: action == "double_click" ? 2 : 1)
        case "type":
            await actionPerformer.type(input["text"] as? String ?? "")
        case "key":
            await actionPerformer.pressKeys(input["keys"] as? String ?? "")
        case "scroll":
            await actionPerformer.scroll(at: targetGlobalPoint ?? pointerLocationProvider(), lines: (input["scroll_amount"] as? NSNumber)?.intValue ?? 5)
        default:
            return ("Unknown action \(action).", [], true)
        }
        let screens = await captureSettledScreens()
        latestScreens = screens
        overlayState.returnToPointer()
        return ("Done: \(actionDescription). Fresh screenshot attached.", screens, false)
    }
}
