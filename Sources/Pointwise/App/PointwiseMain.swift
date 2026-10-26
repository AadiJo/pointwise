import AppKit
import SwiftUI

@main
enum PointwiseMain {
    static func main() {
        let application = NSApplication.shared
        let appDelegate = PointwiseAppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(appDelegate) {
            application.run()
        }
    }
}

/// Launch options for development.
struct LaunchOptions {
    var questionToAskAtLaunch: String?
    var fixtureScreenImagePath: String?
    var shouldShowOnboarding = false

    init(arguments: [String]) {
        var argumentIndex = 1
        while argumentIndex < arguments.count {
            let argument = arguments[argumentIndex]
            let nextValue = argumentIndex + 1 < arguments.count ? arguments[argumentIndex + 1] : nil
            switch argument {
            case "--ask": questionToAskAtLaunch = nextValue; argumentIndex += 1
            case "--fixture-screen": fixtureScreenImagePath = nextValue; argumentIndex += 1
            case "--onboarding": shouldShowOnboarding = true
            default: break
            }
            argumentIndex += 1
        }
    }
}

@MainActor
final class PointwiseAppDelegate: NSObject, NSApplicationDelegate {
    private let companion = CompanionController()
    private var menuBarController: MenuBarController?
    private var settingsWindow: NSWindow?
    private var homeWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var lessonLibraryWindow: NSWindow?
    private let launchOptions = LaunchOptions(arguments: CommandLine.arguments)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let fixtureScreenImagePath = launchOptions.fixtureScreenImagePath {
            companion.screenSource = FixtureScreenSource(imageURL: URL(fileURLWithPath: fixtureScreenImagePath))
        }

        companion.start()
        let menuBarController = MenuBarController(companion: companion)
        menuBarController.onOpenSettings = { [weak self] in self?.showSettings() }
        menuBarController.onOpenHome = { [weak self] in self?.showHome() }
        menuBarController.onOpenOnboarding = { [weak self] in self?.showOnboarding() }
        menuBarController.onOpenLessonLibrary = { [weak self] in self?.showLessonLibrary() }
        self.menuBarController = menuBarController

        if !AppSettings.shared.hasCompletedOnboarding || launchOptions.shouldShowOnboarding {
            showOnboarding()
        } else {
            companion.overlayState.flashBubble("hey! i'm pointwise", duration: 2)
        }

        if let questionToAskAtLaunch = launchOptions.questionToAskAtLaunch {
            Task {
                // Give the brain a moment to start before the first question.
                for _ in 0..<40 where !companion.isBrainReady { try? await Task.sleep(nanoseconds: 250_000_000) }
                companion.handleLearnerInput(questionToAskAtLaunch, inputMode: "typed")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companion.brain.stop()
    }

    // MARK: - Windows

    private func showSettings() {
        let window = settingsWindow ?? makeWindow(
            title: "Pointwise Settings",
            content: SettingsView(settings: AppSettings.shared, memory: MemoryStore.shared, companion: companion),
            size: CGSize(width: 560, height: 470)
        )
        settingsWindow = window
        present(window)
    }

    private func showHome() {
        let window = homeWindow ?? makeWindow(
            title: "Pointwise Lessons",
            content: HomeView(companion: companion, memory: MemoryStore.shared),
            size: CGSize(width: 820, height: 560),
            isResizable: true
        )
        homeWindow = window
        present(window)
    }

    private func showLessonLibrary() {
        let window = lessonLibraryWindow ?? makeWindow(
            title: "Pointwise Lesson Library",
            content: LessonLibraryView(library: LessonLibrary.shared) { [weak self] lesson in
                self?.lessonLibraryWindow?.close()
                self?.companion.startLesson(lesson)
            },
            size: CGSize(width: 820, height: 600),
            isResizable: true
        )
        lessonLibraryWindow = window
        present(window)
    }

    /// Opens shared lesson links such as pointwise://lesson?title=…&url=…&goal=…
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let lesson = LessonPlan(shareLink: url) else { continue }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Start the lesson \"\(lesson.title)\"?"
            let websiteHost = URL(string: lesson.websiteURL)?.host ?? "no website"
            alert.informativeText = "Pointwise will open \(websiteHost) and teach: \(lesson.goal)"
            alert.addButton(withTitle: "Start lesson")
            alert.addButton(withTitle: "Save for later")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                LessonLibrary.shared.add(lesson)
                companion.startLesson(lesson)
            case .alertSecondButtonReturn:
                LessonLibrary.shared.add(lesson)
            default:
                break
            }
        }
    }

    private func showOnboarding() {
        let window = onboardingWindow ?? makeWindow(
            title: "Welcome to Pointwise",
            content: OnboardingView(settings: AppSettings.shared, companion: companion) { [weak self] in
                AppSettings.shared.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
                self?.companion.overlayState.flashBubble("hold control + option and say hi!", duration: 6)
            },
            size: CGSize(width: 560, height: 500)
        )
        onboardingWindow = window
        present(window)
    }

    private func makeWindow<Content: View>(title: String, content: Content, size: CGSize, isResizable: Bool = false) -> NSWindow {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if isResizable { styleMask.insert(.resizable) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: styleMask, backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Serves a fixed image as the "screen". Lets developers test the whole
/// pipeline without Screen Recording permission.
@MainActor
final class FixtureScreenSource: ScreenSource {
    private let imageURL: URL

    init(imageURL: URL) {
        self.imageURL = imageURL
    }

    var displayFrames: [CGRect] { NSScreen.screens.map(\.frame) }

    func captureScreens(pointerLocation: CGPoint) async throws -> [CapturedScreen] {
        guard let image = NSImage(contentsOf: imageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let jpegData = JPEGEncoding.jpegData(from: cgImage) else { throw ScreenCaptureError.captureFailed }
        let displayFrame = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        return [CapturedScreen(
            jpegData: jpegData,
            label: ScreenLabels.label(screenNumber: 1, screenCount: 1, isCursorScreen: true),
            isCursorScreen: true,
            displayFrame: displayFrame,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            screenNumber: 1
        )]
    }
}
