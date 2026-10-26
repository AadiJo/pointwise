import XCTest
@testable import Pointwise

final class StreamingResponseParserTests: XCTestCase {
    private func parseInChunks(_ text: String, chunkSize: Int) -> [SpokenSegment] {
        var parser = StreamingResponseParser()
        var segments: [SpokenSegment] = []
        var remainingText = Substring(text)
        while !remainingText.isEmpty {
            let chunk = remainingText.prefix(chunkSize)
            remainingText = remainingText.dropFirst(chunk.count)
            segments += parser.append(String(chunk))
        }
        return segments + parser.finish()
    }

    func testTagAfterPeriodBelongsToPreviousSentence() {
        let text = "Open the Insert menu up here. [POINT:212,14:Insert menu] Then pick Chart."
        for chunkSize in [1, 3, 7, 200] {
            let segments = parseInChunks(text, chunkSize: chunkSize)
            XCTAssertEqual(segments.map(\.text), ["Open the Insert menu up here.", "Then pick Chart."], "chunk size \(chunkSize)")
            XCTAssertEqual(segments[0].commands, [ScreenAnnotationCommand(kind: .point, numbers: [212, 14], label: "Insert menu", screenNumber: nil)])
            XCTAssertTrue(segments[1].commands.isEmpty)
        }
    }

    func testTagInsideSentenceAndScreenSuffix() {
        let segments = parseInChunks("See this box [BOX:10,20,110,220:graph area:screen2] on the right!", chunkSize: 4)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "See this box on the right!")
        XCTAssertEqual(segments[0].commands.first?.kind, .box)
        XCTAssertEqual(segments[0].commands.first?.screenNumber, 2)
        XCTAssertEqual(segments[0].commands.first?.label, "graph area")
    }

    func testSpotlightAndSimulationTags() {
        let text = "Look only at this diagram. [SPOTLIGHT:660,280,950,560:Photosynthesis] Watch the string get longer. [SIM:length=2.5, gravity=1.6]"
        for chunkSize in [1, 5, 300] {
            let segments = parseInChunks(text, chunkSize: chunkSize)
            XCTAssertEqual(segments.map(\.text), ["Look only at this diagram.", "Watch the string get longer."], "chunk size \(chunkSize)")
            XCTAssertEqual(segments[0].commands, [ScreenAnnotationCommand(kind: .spotlight, numbers: [660, 280, 950, 560], label: "Photosynthesis", screenNumber: nil)])
            XCTAssertEqual(segments[1].commands.first?.kind, .simulation)
            XCTAssertEqual(segments[1].commands.first?.simulationValues, ["length": 2.5, "gravity": 1.6])
        }
    }

    func testSimulationTagWithoutValuesIsSpokenAsText() {
        let segments = parseInChunks("A [SIM:nothing] tag.", chunkSize: 3)
        XCTAssertTrue(segments.allSatisfy { $0.commands.isEmpty })
    }

    func testDecimalsDoNotSplitSentences() {
        let segments = parseInChunks("Pi is about 3.14 and that is neat. Next idea.", chunkSize: 2)
        XCTAssertEqual(segments.map(\.text), ["Pi is about 3.14 and that is neat.", "Next idea."])
    }

    func testPointNoneAndLiteralBracketsAreHandled() {
        let segments = parseInChunks("Arrays start at index [0] in Python. [POINT:none]", chunkSize: 5)
        XCTAssertEqual(segments.map(\.text), ["Arrays start at index [0] in Python."])
        XCTAssertTrue(segments[0].commands.isEmpty)
    }

    func testMultipleTrailingTagsAndClear() {
        let segments = parseInChunks("Here is the vertex. [CIRCLE:400,300,40:vertex] [ARROW:100,100,380,290:look] [CLEAR]", chunkSize: 6)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].commands.map(\.kind), [.circle, .arrow, .clear])
    }

    func testNewlineEndsSentenceAndMarkdownIsCleaned() {
        let segments = parseInChunks("**First** click Save\n- then close it", chunkSize: 3)
        XCTAssertEqual(segments.map(\.text), ["First click Save", "then close it"])
    }

    func testRemovedTagDoesNotLeaveSpaceBeforePunctuation() {
        let segments = parseInChunks("Sunlight hits the leaves [CIRCLE:10,10,20:leaves] , and water rises [POINT:5,5:roots] .", chunkSize: 5)
        XCTAssertEqual(segments.map(\.text), ["Sunlight hits the leaves, and water rises."])
        XCTAssertEqual(segments[0].commands.count, 2)
    }

    func testBracketedWordsWithLengthChangingLettersDoNotCrash() {
        let segments = parseInChunks("Die Straße [Straße] ist lang. [ß", chunkSize: 3)
        XCTAssertEqual(segments.map(\.text), ["Die Straße [Straße] ist lang.", "[ß"])
    }

    func testPixelCoordinateNotesAreDetected() {
        XCTAssertTrue(SpokenSegment(text: "Points at x=1 is (864,463), x=3 is (950,463).", commands: []).looksLikeInternalNote)
        XCTAssertTrue(SpokenSegment(text: "Gray dots at x=1 (~864,463) and x=3 (~950,463).", commands: []).looksLikeInternalNote)
        XCTAssertFalse(SpokenSegment(text: "The vertex is at (2, -1).", commands: []).looksLikeInternalNote)
        XCTAssertFalse(SpokenSegment(text: "It crosses at one comma zero.", commands: []).looksLikeInternalNote)
    }

    func testIncompleteTagWaitsForMoreText() {
        var parser = StreamingResponseParser()
        XCTAssertEqual(parser.append("Click it. [POI"), [])
        XCTAssertEqual(parser.append("NT:5,6:it]"), [])
        let segments = parser.append(" Done.") + parser.finish()
        XCTAssertEqual(segments.map(\.text), ["Click it.", "Done."])
        XCTAssertEqual(segments[0].commands.count, 1)
    }
}
