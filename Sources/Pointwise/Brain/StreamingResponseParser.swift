import Foundation

/// One on-screen drawing command that Claude embedded in its spoken text,
/// for example `[POINT:212,14:Insert menu]`. Coordinates stay in the pixel
/// space of the screenshot until the overlay maps them to the display.
struct ScreenAnnotationCommand: Equatable {
    enum Kind: String, CaseIterable {
        case point = "POINT"
        case circle = "CIRCLE"
        case box = "BOX"
        case underline = "UNDERLINE"
        case arrow = "ARROW"
        case spotlight = "SPOTLIGHT"
        /// Changes values in the open simulation: `[SIM:length=2,gravity=1.6]`.
        case simulation = "SIM"
        case clear = "CLEAR"

        /// How many numbers the tag must carry before the label.
        var requiredNumberCount: Int {
            switch self {
            case .point: return 2
            case .circle: return 3
            case .box, .underline, .arrow, .spotlight: return 4
            case .clear, .simulation: return 0
            }
        }
    }

    var kind: Kind
    var numbers: [Double]
    var label: String?
    /// One-based screen number from the screenshot label, or nil for the cursor's screen.
    var screenNumber: Int?

    /// For `[SIM:...]`: the new values, such as ["length": 2, "gravity": 1.6].
    var simulationValues: [String: Double] {
        guard kind == .simulation, let label else { return [:] }
        var parsedValues: [String: Double] = [:]
        for assignment in label.split(separator: ",") {
            let sides = assignment.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if sides.count == 2, !sides[0].isEmpty, let value = Double(sides[1]) { parsedValues[sides[0]] = value }
        }
        return parsedValues
    }
}

/// A sentence to speak plus the drawing commands to run when it starts.
struct SpokenSegment: Equatable {
    var text: String
    var commands: [ScreenAnnotationCommand]

    var hasSpeech: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// True for notes Claude wrote to itself, such as "x=1 is at (864,463)".
    /// Screen pixel positions are never meant to be read aloud.
    var looksLikeInternalNote: Bool {
        guard let pairPattern = try? NSRegularExpression(pattern: #"\(\s*[~≈]?\s*(\d{2,4})\s*,\s*[~≈]?\s*(\d{2,4})\s*\)"#) else { return false }
        let fullRange = NSRange(text.startIndex..., in: text)
        return pairPattern.matches(in: text, range: fullRange).contains { match in
            let numbers = (1...2).compactMap { Range(match.range(at: $0), in: text).flatMap { Int(text[$0]) } }
            return numbers.contains { $0 >= 100 }
        }
    }
}

/// Turns streamed text deltas into ready-to-speak sentences. A sentence is
/// held until the next visible character arrives, so a tag written right
/// after the period ("Click here. [POINT:...]") still belongs to it.
struct StreamingResponseParser {
    private var unconsumedRawText = ""
    private var currentSentenceText = ""
    private var currentSentenceCommands: [ScreenAnnotationCommand] = []
    private var completedSentenceAwaitingTrailingTags: SpokenSegment?

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let maximumTagLength = 240

    mutating func append(_ textDelta: String) -> [SpokenSegment] {
        unconsumedRawText += textDelta
        return process(isFinal: false)
    }

    /// Flushes everything, for example at the end of a text block or turn.
    mutating func finish() -> [SpokenSegment] {
        process(isFinal: true)
    }

    mutating func reset() {
        self = StreamingResponseParser()
    }

    // MARK: - Processing

    private mutating func process(isFinal: Bool) -> [SpokenSegment] {
        var readySegments: [SpokenSegment] = []

        processingLoop: while true {
            if var completedSentence = completedSentenceAwaitingTrailingTags {
                let textAfterSentence = unconsumedRawText.drop(while: { $0.isWhitespace })
                if textAfterSentence.isEmpty {
                    if isFinal {
                        readySegments.append(completedSentence)
                        completedSentenceAwaitingTrailingTags = nil
                        unconsumedRawText = ""
                    }
                    break processingLoop
                }
                if textAfterSentence.first == "[" {
                    switch Self.readTag(at: textAfterSentence, isFinal: isFinal) {
                    case .command(let command, let remainder):
                        completedSentence.commands.append(command)
                        completedSentenceAwaitingTrailingTags = completedSentence
                        unconsumedRawText = String(remainder)
                        continue processingLoop
                    case .ignoredTag(let remainder):
                        unconsumedRawText = String(remainder)
                        continue processingLoop
                    case .needsMoreText:
                        break processingLoop
                    case .notATag:
                        break
                    }
                }
                readySegments.append(completedSentence)
                completedSentenceAwaitingTrailingTags = nil
                unconsumedRawText = String(textAfterSentence)
                continue processingLoop
            }

            guard !unconsumedRawText.isEmpty else { break processingLoop }

            var scanIndex = unconsumedRawText.startIndex
            while scanIndex < unconsumedRawText.endIndex {
                let character = unconsumedRawText[scanIndex]

                if character == "[" {
                    switch Self.readTag(at: unconsumedRawText[scanIndex...], isFinal: isFinal) {
                    case .command(let command, let remainder):
                        currentSentenceCommands.append(command)
                        unconsumedRawText = String(remainder)
                        continue processingLoop
                    case .ignoredTag(let remainder):
                        unconsumedRawText = String(remainder)
                        continue processingLoop
                    case .needsMoreText:
                        unconsumedRawText = String(unconsumedRawText[scanIndex...])
                        break processingLoop
                    case .notATag:
                        currentSentenceText.append(character)
                        scanIndex = unconsumedRawText.index(after: scanIndex)
                        continue
                    }
                }

                let nextIndex = unconsumedRawText.index(after: scanIndex)
                if character == "\n" {
                    unconsumedRawText = String(unconsumedRawText[nextIndex...])
                    completeCurrentSentence()
                    continue processingLoop
                }

                currentSentenceText.append(character)

                if Self.sentenceTerminators.contains(character) {
                    if nextIndex == unconsumedRawText.endIndex {
                        if isFinal {
                            unconsumedRawText = ""
                            completeCurrentSentence()
                            continue processingLoop
                        }
                        // Wait for the next character: "3." might become "3.14".
                        currentSentenceText.removeLast()
                        unconsumedRawText = String(unconsumedRawText[scanIndex...])
                        break processingLoop
                    }
                    let followingCharacter = unconsumedRawText[nextIndex]
                    if followingCharacter.isWhitespace || followingCharacter == "[" {
                        unconsumedRawText = String(unconsumedRawText[nextIndex...])
                        completeCurrentSentence()
                        continue processingLoop
                    }
                }
                scanIndex = nextIndex
            }
            unconsumedRawText = ""
            break processingLoop
        }

        if isFinal {
            completeCurrentSentence()
            if let completedSentence = completedSentenceAwaitingTrailingTags {
                readySegments.append(completedSentence)
                completedSentenceAwaitingTrailingTags = nil
            }
            unconsumedRawText = ""
        }
        return readySegments
    }

    private mutating func completeCurrentSentence() {
        let cleanedText = Self.cleanForSpeech(currentSentenceText)
        if !cleanedText.isEmpty || !currentSentenceCommands.isEmpty {
            if var previousSentence = completedSentenceAwaitingTrailingTags, cleanedText.isEmpty {
                // Commands with no words of their own join the sentence before them.
                previousSentence.commands.append(contentsOf: currentSentenceCommands)
                completedSentenceAwaitingTrailingTags = previousSentence
            } else {
                completedSentenceAwaitingTrailingTags = SpokenSegment(text: cleanedText, commands: currentSentenceCommands)
            }
        }
        currentSentenceText = ""
        currentSentenceCommands = []
    }

    // MARK: - Tags

    private enum TagReadResult {
        case command(ScreenAnnotationCommand, remainder: Substring)
        case ignoredTag(remainder: Substring)
        case needsMoreText
        case notATag
    }

    private static func readTag(at text: Substring, isFinal: Bool) -> TagReadResult {
        guard text.first == "[" else { return .notATag }
        let bodyStart = text.index(after: text.startIndex)
        guard let closingBracketIndex = text[bodyStart...].firstIndex(of: "]") else {
            if !isFinal && couldBeStartOfTag(text) { return .needsMoreText }
            return .notATag
        }
        let tagBody = text[bodyStart..<closingBracketIndex]
        let remainder = text[text.index(after: closingBracketIndex)...]
        if let command = parseTagBody(tagBody) {
            return .command(command, remainder: remainder)
        }
        if tagBody.uppercased().hasPrefix("POINT:NONE") {
            return .ignoredTag(remainder: remainder)
        }
        return .notATag
    }

    private static func couldBeStartOfTag(_ text: Substring) -> Bool {
        guard text.count <= maximumTagLength else { return false }
        let body = text.dropFirst()
        // Measure the keyword in the original text: uppercasing can change length ("ß" becomes "SS").
        let originalKeyword = body.prefix(while: { $0.isLetter })
        let keyword = originalKeyword.uppercased()
        let knownKeywords = ScreenAnnotationCommand.Kind.allCases.map(\.rawValue)
        guard originalKeyword.endIndex < body.endIndex else {
            return knownKeywords.contains { $0.hasPrefix(keyword) }
        }
        let characterAfterKeyword = body[originalKeyword.endIndex]
        return knownKeywords.contains(keyword) && (characterAfterKeyword == ":" || characterAfterKeyword == "]")
    }

    static func parseTagBody(_ tagBody: Substring) -> ScreenAnnotationCommand? {
        var parts = tagBody.split(separator: ":", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let keyword = parts.first, let kind = ScreenAnnotationCommand.Kind(rawValue: keyword.uppercased()) else {
            return nil
        }
        parts.removeFirst()
        if kind == .clear {
            return ScreenAnnotationCommand(kind: .clear, numbers: [], label: nil, screenNumber: nil)
        }
        if kind == .simulation {
            let assignments = parts.joined(separator: ":").trimmingCharacters(in: .whitespaces)
            let command = ScreenAnnotationCommand(kind: .simulation, numbers: [], label: assignments, screenNumber: nil)
            return command.simulationValues.isEmpty ? nil : command
        }
        guard let numberPart = parts.first else { return nil }
        let numbers = numberPart.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == kind.requiredNumberCount else { return nil }
        parts.removeFirst()

        var screenNumber: Int?
        if let lastPart = parts.last, lastPart.lowercased().hasPrefix("screen"), let parsedNumber = Int(lastPart.dropFirst(6)) {
            screenNumber = parsedNumber
            parts.removeLast()
        }
        let label = parts.joined(separator: ":").trimmingCharacters(in: .whitespaces)
        return ScreenAnnotationCommand(kind: kind, numbers: numbers, label: label.isEmpty ? nil : label, screenNumber: screenNumber)
    }

    /// Removes Markdown symbols that sound odd when spoken and collapses spaces.
    static func cleanForSpeech(_ text: String) -> String {
        var cleanedText = text
        for symbol in ["**", "__", "`", "#"] {
            cleanedText = cleanedText.replacingOccurrences(of: symbol, with: "")
        }
        cleanedText = cleanedText.replacingOccurrences(of: #"(?m)^\s*[-*•]\s+"#, with: "", options: .regularExpression)
        cleanedText = cleanedText.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // A removed tag can leave a space before punctuation: "the leaves , and".
        cleanedText = cleanedText.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        return cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
