import Foundation

/// Events the brain sidecar sends back to the app.
enum BrainEvent {
    case ready(model: String, authSource: String)
    case textDelta(turnId: String, text: String)
    case textBlockEnd(turnId: String)
    case activity(turnId: String, text: String)
    case toolCall(turnId: String, callId: String, name: String, input: [String: Any])
    case turnDone(turnId: String, text: String, wasCancelled: Bool)
    case turnError(turnId: String, message: String)
    case summary(requestId: String, markdown: String)
    case log(level: String, message: String)
    case processExited(status: Int32)
}

/// Runs `brain.mjs` (the Claude Agent SDK sidecar) with Node and talks to it
/// with one JSON object per line. The sidecar reuses the learner's local
/// Claude Code login, so the app never handles an API key.
@MainActor
final class BrainClient {
    var onEvent: ((BrainEvent) -> Void)?

    private var brainProcess: Process?
    private var standardInputHandle: FileHandle?
    private var unparsedOutputData = Data()
    private var lastConfigurationMessage: [String: Any]?
    private var restartAttemptCount = 0
    private var isStopping = false

    private(set) var isRunning = false
    private(set) var resolvedNodePath: String?
    private(set) var resolvedClaudePath: String?

    // MARK: - Lifecycle

    func start() throws {
        isStopping = false
        let settings = AppSettings.shared
        guard let nodePath = ExecutableLocator.nodeExecutablePath(override: settings.nodeExecutablePathOverride) else {
            throw BrainClientError.nodeNotFound
        }
        guard let brainScriptURL = ExecutableLocator.brainScriptURL() else {
            throw BrainClientError.brainScriptNotFound
        }
        resolvedNodePath = nodePath
        resolvedClaudePath = ExecutableLocator.claudeExecutablePath(override: settings.claudeExecutablePathOverride)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [brainScriptURL.path]
        var environment = ProcessInfo.processInfo.environment
        let extraPathDirectories = [
            URL(fileURLWithPath: nodePath).deletingLastPathComponent().path,
            resolvedClaudePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path },
            "/opt/homebrew/bin", "/usr/local/bin",
        ].compactMap { $0 }
        environment["PATH"] = (extraPathDirectories + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        environment["POINTWISE_WORKDIR"] = MemoryStore.shared.storageDirectory.appendingPathComponent("brain").path
        if let resolvedClaudePath { environment["POINTWISE_CLAUDE_PATH"] = resolvedClaudePath }
        process.environment = environment

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let newData = handle.availableData
            guard !newData.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consumeOutput(newData) }
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { handle in
            let errorData = handle.availableData
            guard !errorData.isEmpty, let errorText = String(data: errorData, encoding: .utf8) else { return }
            PointwiseLog.write("brain stderr: \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { @MainActor [weak self] in
                // A restart replaces the process; only the current one may report an exit.
                guard let self, self.brainProcess === terminatedProcess else { return }
                self.handleTermination(status: status)
            }
        }

        try process.run()
        brainProcess = process
        standardInputHandle = standardInputPipe.fileHandleForWriting
        isRunning = true
        PointwiseLog.write("brain started with node at \(nodePath), claude at \(resolvedClaudePath ?? "not found")")

        if let lastConfigurationMessage { send(lastConfigurationMessage) }
    }

    func stop() {
        isStopping = true
        try? standardInputHandle?.close()
        brainProcess?.terminationHandler = nil
        brainProcess?.terminate()
        brainProcess = nil
        isRunning = false
    }

    private func handleTermination(status: Int32) {
        isRunning = false
        brainProcess = nil
        onEvent?(.processExited(status: status))
        guard !isStopping, restartAttemptCount < 5 else { return }
        restartAttemptCount += 1
        let delaySeconds = Double(restartAttemptCount)
        PointwiseLog.write("brain exited with status \(status); restarting in \(delaySeconds)s")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            try? self.start()
        }
    }

    // MARK: - Requests

    func configure(model: String, effort: String, learnerProfile: String, memory: String, language: String, actionsEnabled: Bool, thinksBeforeAnswering: Bool) {
        var message: [String: Any] = [
            "type": "configure",
            "model": model,
            "effort": effort,
            "thinking": thinksBeforeAnswering ? "adaptive" : "disabled",
            "learnerProfile": learnerProfile,
            "memory": memory,
            "language": language,
            "actionsEnabled": actionsEnabled,
        ]
        if let resolvedClaudePath { message["claudeExecutablePath"] = resolvedClaudePath }
        lastConfigurationMessage = message
        send(message)
    }

    func ask(turnId: String, text: String, screens: [CapturedScreen], context: String, inputMode: String) {
        send([
            "type": "ask",
            "turnId": turnId,
            "text": text,
            "screens": screens.map(\.protocolDictionary),
            "context": context,
            "inputMode": inputMode,
        ])
    }

    func sendToolResult(callId: String, text: String, screens: [CapturedScreen] = [], isError: Bool = false) {
        send([
            "type": "tool_result",
            "callId": callId,
            "text": text,
            "screens": screens.map(\.protocolDictionary),
            "isError": isError,
        ])
    }

    func cancel() { send(["type": "cancel"]) }
    func reset() { send(["type": "reset"]) }

    func summarize(requestId: String, transcript: String) {
        send(["type": "summarize", "requestId": requestId, "transcript": transcript])
    }

    private func send(_ message: [String: Any]) {
        guard isRunning, let standardInputHandle,
              var lineData = try? JSONSerialization.data(withJSONObject: message) else { return }
        lineData.append(0x0A)
        do {
            try standardInputHandle.write(contentsOf: lineData)
        } catch {
            PointwiseLog.write("failed to write to brain: \(error)")
        }
    }

    // MARK: - Output parsing

    private func consumeOutput(_ newData: Data) {
        unparsedOutputData.append(newData)
        while let newlineIndex = unparsedOutputData.firstIndex(of: 0x0A) {
            let lineData = unparsedOutputData[unparsedOutputData.startIndex..<newlineIndex]
            unparsedOutputData.removeSubrange(unparsedOutputData.startIndex...newlineIndex)
            guard let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let event = Self.decodeEvent(message) else { continue }
            if case .ready = event { restartAttemptCount = 0 }
            onEvent?(event)
        }
    }

    static func decodeEvent(_ message: [String: Any]) -> BrainEvent? {
        let turnId = message["turnId"] as? String ?? ""
        switch message["type"] as? String {
        case "ready":
            return .ready(model: message["model"] as? String ?? "", authSource: message["authSource"] as? String ?? "")
        case "text_delta":
            return .textDelta(turnId: turnId, text: message["text"] as? String ?? "")
        case "text_block_end":
            return .textBlockEnd(turnId: turnId)
        case "activity":
            return .activity(turnId: turnId, text: message["text"] as? String ?? "")
        case "tool_call":
            return .toolCall(
                turnId: turnId,
                callId: message["callId"] as? String ?? "",
                name: message["name"] as? String ?? "",
                input: message["input"] as? [String: Any] ?? [:]
            )
        case "turn_done":
            return .turnDone(turnId: turnId, text: message["text"] as? String ?? "", wasCancelled: message["cancelled"] as? Bool ?? false)
        case "turn_error":
            return .turnError(turnId: turnId, message: message["message"] as? String ?? "Something went wrong.")
        case "summary":
            return .summary(requestId: message["requestId"] as? String ?? "", markdown: message["markdown"] as? String ?? "")
        case "log":
            return .log(level: message["level"] as? String ?? "info", message: message["message"] as? String ?? "")
        default:
            return nil
        }
    }
}

enum BrainClientError: LocalizedError {
    case nodeNotFound
    case brainScriptNotFound

    var errorDescription: String? {
        switch self {
        case .nodeNotFound: return "Pointwise needs Node.js to run its Claude brain. Install Node 20 or newer, or set the path in Settings."
        case .brainScriptNotFound: return "The brain script is missing from the app bundle. Rebuild Pointwise."
        }
    }
}

/// Finds Node, the Claude Code CLI, and the bundled brain script.
enum ExecutableLocator {
    static func nodeExecutablePath(override: String) -> String? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        var candidatePaths = [
            override,
            ProcessInfo.processInfo.environment["POINTWISE_NODE_PATH"] ?? "",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(homeDirectory)/.vite-plus/bin/node",
            "\(homeDirectory)/.volta/bin/node",
        ]
        let nvmVersionsDirectory = "\(homeDirectory)/.nvm/versions/node"
        if let installedVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmVersionsDirectory) {
            candidatePaths += installedVersions.sorted(by: >).map { "\(nvmVersionsDirectory)/\($0)/bin/node" }
        }
        if let existingPath = firstExecutable(in: candidatePaths) { return existingPath }
        if let loginShellPath = pathFromLoginShell(command: "node") { return loginShellPath }
        return firstExecutable(in: ["\(homeDirectory)/.bun/bin/bun"])
    }

    static func claudeExecutablePath(override: String) -> String? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            override,
            ProcessInfo.processInfo.environment["POINTWISE_CLAUDE_PATH"] ?? "",
            "\(homeDirectory)/.local/bin/claude",
            "\(homeDirectory)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return firstExecutable(in: candidatePaths) ?? pathFromLoginShell(command: "claude")
    }

    static func brainScriptURL() -> URL? {
        if let environmentPath = ProcessInfo.processInfo.environment["POINTWISE_BRAIN_PATH"],
           FileManager.default.fileExists(atPath: environmentPath) {
            return URL(fileURLWithPath: environmentPath)
        }
        if let bundledURL = Bundle.main.resourceURL?.appendingPathComponent("brain/brain.mjs"),
           FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }
        // Development fallback: .build/<config>/Pointwise → repo/brain/dist/brain.mjs
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var searchDirectory = executableURL.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidateURL = searchDirectory.appendingPathComponent("brain/dist/brain.mjs")
            if FileManager.default.fileExists(atPath: candidateURL.path) { return candidateURL }
            searchDirectory = searchDirectory.deletingLastPathComponent()
        }
        return nil
    }

    private static func firstExecutable(in candidatePaths: [String]) -> String? {
        candidatePaths.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func pathFromLoginShell(command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(command)"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstExecutable(in: [path])
    }
}

/// Appends diagnostic lines to ~/Library/Logs/Pointwise.log and stderr.
enum PointwiseLog {
    private static let logFileURL: URL = {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        return logsDirectory.appendingPathComponent("Pointwise.log")
    }()
    private static let writeQueue = DispatchQueue(label: "pointwise.log")
    private static let timestampFormatter: ISO8601DateFormatter = ISO8601DateFormatter()

    static func write(_ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        writeQueue.async {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: logFileURL)
            }
        }
    }
}
