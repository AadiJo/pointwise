import XCTest
@testable import Pointwise

final class CoordinateMappingTests: XCTestCase {
    private func makeScreen(displayFrame: CGRect, pixelWidth: Int = 1280, pixelHeight: Int = 832) -> CapturedScreen {
        CapturedScreen(jpegData: Data(), label: "test", isCursorScreen: true, displayFrame: displayFrame, pixelWidth: pixelWidth, pixelHeight: pixelHeight, screenNumber: 1)
    }

    func testScreenshotCornersMapToDisplayCorners() {
        let screen = makeScreen(displayFrame: CGRect(x: 0, y: 0, width: 1710, height: 1112))
        XCTAssertEqual(screen.globalPoint(fromScreenshotX: 0, screenshotY: 0), CGPoint(x: 0, y: 1112))
        let bottomRight = screen.globalPoint(fromScreenshotX: 1280, screenshotY: 832)
        XCTAssertEqual(bottomRight.x, 1710, accuracy: 0.01)
        XCTAssertEqual(bottomRight.y, 0, accuracy: 0.01)
    }

    func testSecondDisplayOffsetIsApplied() {
        // A display to the left of the main one has a negative origin.
        let screen = makeScreen(displayFrame: CGRect(x: -1920, y: 100, width: 1920, height: 1080), pixelWidth: 1280, pixelHeight: 720)
        let center = screen.globalPoint(fromScreenshotX: 640, screenshotY: 360)
        XCTAssertEqual(center.x, -960, accuracy: 0.01)
        XCTAssertEqual(center.y, 640, accuracy: 0.01)
    }

    func testRoundTripBetweenScreenshotAndGlobalPoints() {
        let screen = makeScreen(displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), pixelWidth: 1280, pixelHeight: 831)
        let globalPoint = screen.globalPoint(fromScreenshotX: 333, screenshotY: 444)
        let screenshotPoint = screen.screenshotPoint(fromGlobal: globalPoint)
        XCTAssertEqual(screenshotPoint.x, 333, accuracy: 0.01)
        XCTAssertEqual(screenshotPoint.y, 444, accuracy: 0.01)
    }

    func testOutOfRangeCoordinatesAreClamped() {
        let screen = makeScreen(displayFrame: CGRect(x: 0, y: 0, width: 1710, height: 1112))
        let clampedPoint = screen.globalPoint(fromScreenshotX: 5000, screenshotY: -50)
        XCTAssertEqual(clampedPoint.x, 1710, accuracy: 0.01)
        XCTAssertEqual(clampedPoint.y, 1112, accuracy: 0.01)
    }
}

@MainActor
final class LearnerInputRoutingTests: XCTestCase {
    func testContinueCommandsAreRecognized() {
        for phrase in ["Continue", "next", "okay I did it", "Done.", "got it", "next step"] {
            XCTAssertTrue(CompanionController.isContinueCommand(phrase), phrase)
        }
        for phrase in ["what does this button do", "how do I continue the line", "nextgen"] {
            XCTAssertFalse(CompanionController.isContinueCommand(phrase), phrase)
        }
    }

    func testQuizAnswersMatchLettersOrdinalsAndText() {
        let choices = ["Oxygen", "Carbon dioxide", "Nitrogen"]
        XCTAssertEqual(CompanionController.quizChoiceIndex(from: "B", choices: choices), 1)
        XCTAssertEqual(CompanionController.quizChoiceIndex(from: "I think it's answer c", choices: choices), 2)
        XCTAssertEqual(CompanionController.quizChoiceIndex(from: "the first one", choices: choices), 0)
        XCTAssertEqual(CompanionController.quizChoiceIndex(from: "carbon dioxide!", choices: choices), 1)
        XCTAssertNil(CompanionController.quizChoiceIndex(from: "can you explain more", choices: choices))
    }

    func testActionNarrationReadsNaturally() {
        XCTAssertEqual(CompanionController.narration(forAction: "Click the search box"), "Watch: I'll click the search box.")
        XCTAssertEqual(CompanionController.narration(forAction: "type black hole."), "Watch: I'll type black hole.")
        XCTAssertEqual(CompanionController.narration(forAction: ""), "Watch this.")
    }

    func testTagsAreRemovedFromSavedTranscripts() {
        let text = "Click Insert up here. [POINT:212,14:Insert menu] Then pick Chart. [CIRCLE:10,10,20:chart]"
        XCTAssertEqual(CompanionController.removingTags(from: text), "Click Insert up here. Then pick Chart.")
        let labText = "Watch closely. [SPOTLIGHT:1,2,3,4:here] Now longer. [SIM:length=2]"
        XCTAssertEqual(CompanionController.removingTags(from: labText), "Watch closely. Now longer.")
    }

    func testStreamedSayIsNotSpokenTwice() {
        XCTAssertTrue(CompanionController.sayWasStreamed(["say": "Hi.", "say_streamed": true]))
        XCTAssertFalse(CompanionController.sayWasStreamed(["say": "Hi."]))
    }
}

final class KeyCombinationTests: XCTestCase {
    func testParsesModifiersAndNamedKeys() {
        let combination = KeyCombination(parsing: "cmd+shift+t")
        XCTAssertEqual(combination?.keyCode, 17)
        XCTAssertEqual(combination?.flags.contains(.maskCommand), true)
        XCTAssertEqual(combination?.flags.contains(.maskShift), true)
        XCTAssertEqual(KeyCombination(parsing: "return")?.keyCode, 36)
        XCTAssertNil(KeyCombination(parsing: "cmd+nonsense"))
    }
}

final class ScreenFingerprintTests: XCTestCase {
    func testIdenticalImagesHaveZeroDifference() {
        let fingerprint: [UInt8] = Array(repeating: 128, count: 48 * 30)
        XCTAssertEqual(ScreenAnnotator.difference(between: fingerprint, and: fingerprint), 0)
        let inverted = fingerprint.map { 255 - $0 }
        XCTAssertGreaterThan(ScreenAnnotator.difference(between: fingerprint, and: inverted), 0)
        XCTAssertEqual(ScreenAnnotator.difference(between: fingerprint, and: []), 1)
    }
}

final class LessonPlanTests: XCTestCase {
    func testShareLinkRoundTrip() throws {
        let lesson = LessonPlan(title: "Graph a line", subject: "Math", websiteURL: "https://www.desmos.com/calculator", goal: "Graph y = 2x + 1 & find the slope.")
        let shareLink = try XCTUnwrap(lesson.shareLink)
        XCTAssertEqual(shareLink.scheme, "pointwise")
        let decodedLesson = try XCTUnwrap(LessonPlan(shareLink: shareLink))
        XCTAssertEqual(decodedLesson.title, lesson.title)
        XCTAssertEqual(decodedLesson.goal, lesson.goal)
        XCTAssertEqual(decodedLesson.websiteURL, lesson.websiteURL)
    }

    func testShareLinksRejectNonWebURLs() {
        XCTAssertNil(LessonPlan(shareLink: URL(string: "pointwise://lesson?title=x&goal=y&url=file:///etc/passwd")!))
        XCTAssertNil(LessonPlan(shareLink: URL(string: "pointwise://other?title=x&goal=y")!))
        XCTAssertNotNil(LessonPlan(shareLink: URL(string: "pointwise://lesson?title=x&goal=y")!))
    }
}
