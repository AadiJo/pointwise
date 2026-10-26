import AppKit
import SwiftUI

// MARK: - Models

@MainActor
final class AskBarModel: ObservableObject {
    @Published var draftText = ""
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
}

@MainActor
final class QuizModel: ObservableObject {
    @Published var question = ""
    @Published var choices: [String] = []
    @Published var correctIndex = 0
    @Published var explanation = ""
    @Published var chosenIndex: Int?
    var onAnswer: ((Int) -> Void)?
}

@MainActor
final class WalkthroughModel: ObservableObject {
    @Published var title = ""
    @Published var steps: [String] = []
    @Published var currentStepIndex = 0
    @Published var completedStepIndexes: Set<Int> = []
    @Published var recap: String?
    @Published var isWaitingForLearner = false
    var onContinue: (() -> Void)?
    var onStop: (() -> Void)?
}

@MainActor
final class PermissionModel: ObservableObject {
    enum Answer { case allowOnce, alwaysAllow, notNow }
    @Published var actionDescription = ""
    var onAnswer: ((Answer) -> Void)?
}

// MARK: - Views

struct AskBarView: View {
    @ObservedObject var model: AskBarModel
    @ObservedObject var settings: AppSettings
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        PanelCard {
            HStack(spacing: 10) {
                BuddyTriangle()
                    .fill(settings.cursorColor)
                    .frame(width: 13, height: 13)
                    .rotationEffect(.degrees(-35))
                    .shadow(color: settings.cursorColor, radius: 5)
                TextField("Ask Pointwise anything…", text: $model.draftText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundColor(DS.Colors.textPrimary)
                    .focused($isFieldFocused)
                    .onSubmit { submit() }
                    .onExitCommand { model.onCancel?() }
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(model.draftText.isEmpty ? DS.Colors.surface3 : DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursorOnHover()
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
        }
        .onAppear { isFieldFocused = true }
    }

    private func submit() {
        let question = model.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        model.onSubmit?(question)
    }
}

struct QuizCardView: View {
    @ObservedObject var model: QuizModel
    private static let choiceLetters = ["A", "B", "C", "D", "E"]

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble.fill").foregroundColor(DS.Colors.accentText)
                    Text("Quick check").font(.system(size: 12, weight: .bold)).foregroundColor(DS.Colors.accentText)
                }
                Text(model.question)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(model.choices.enumerated()), id: \.offset) { choiceIndex, choiceText in
                    Button { answer(choiceIndex) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(Self.choiceLetters[min(choiceIndex, Self.choiceLetters.count - 1)])
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(letterBackground(for: choiceIndex)))
                                .foregroundColor(.white)
                            Text(choiceText)
                                .font(.system(size: 14))
                                .foregroundColor(DS.Colors.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if let resultSymbol = resultSymbol(for: choiceIndex) {
                                Image(systemName: resultSymbol.name).foregroundColor(resultSymbol.color)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 9).fill(rowBackground(for: choiceIndex)))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.chosenIndex != nil)
                    .pointerCursorOnHover()
                }
                if model.chosenIndex != nil {
                    Text(model.explanation)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Click an answer or say the letter.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(16)
            .frame(width: 380, alignment: .leading)
        }
    }

    private func answer(_ choiceIndex: Int) {
        guard model.chosenIndex == nil else { return }
        model.chosenIndex = choiceIndex
        model.onAnswer?(choiceIndex)
    }

    private func letterBackground(for choiceIndex: Int) -> Color {
        guard let chosenIndex = model.chosenIndex else { return DS.Colors.accent }
        if choiceIndex == model.correctIndex { return DS.Colors.success }
        return choiceIndex == chosenIndex ? DS.Colors.destructive : DS.Colors.surface3
    }

    private func rowBackground(for choiceIndex: Int) -> Color {
        guard let chosenIndex = model.chosenIndex else { return DS.Colors.surface2 }
        if choiceIndex == model.correctIndex { return DS.Colors.success.opacity(0.16) }
        return choiceIndex == chosenIndex ? DS.Colors.destructive.opacity(0.16) : DS.Colors.surface1
    }

    private func resultSymbol(for choiceIndex: Int) -> (name: String, color: Color)? {
        guard let chosenIndex = model.chosenIndex else { return nil }
        if choiceIndex == model.correctIndex { return ("checkmark.circle.fill", DS.Colors.success) }
        if choiceIndex == chosenIndex { return ("xmark.circle.fill", DS.Colors.destructive) }
        return nil
    }
}

struct WalkthroughCardView: View {
    @ObservedObject var model: WalkthroughModel

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "list.bullet.clipboard.fill").foregroundColor(DS.Colors.accentText)
                    Text(model.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                    Spacer()
                    Text(model.recap == nil ? "Step \(min(model.currentStepIndex + 1, model.steps.count)) of \(model.steps.count)" : "Done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.steps.enumerated()), id: \.offset) { stepIndex, stepName in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: stepSymbol(for: stepIndex))
                                .font(.system(size: 13))
                                .foregroundColor(stepColor(for: stepIndex))
                                .frame(width: 16)
                            Text(stepName)
                                .font(.system(size: 13, weight: stepIndex == model.currentStepIndex && model.recap == nil ? .semibold : .regular))
                                .foregroundColor(stepIndex == model.currentStepIndex && model.recap == nil ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let recap = model.recap {
                    Text(recap)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.success)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 8) {
                        if model.isWaitingForLearner {
                            Text("Your turn")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.warning)
                        }
                        Spacer()
                        Button("Stop") { model.onStop?() }.buttonStyle(PointwiseButtonStyle())
                        Button("Continue") { model.onContinue?() }.buttonStyle(PointwiseButtonStyle(isProminent: true))
                    }
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }

    private func stepSymbol(for stepIndex: Int) -> String {
        if model.completedStepIndexes.contains(stepIndex) || model.recap != nil { return "checkmark.circle.fill" }
        return stepIndex == model.currentStepIndex ? "circle.inset.filled" : "circle"
    }

    private func stepColor(for stepIndex: Int) -> Color {
        if model.completedStepIndexes.contains(stepIndex) || model.recap != nil { return DS.Colors.success }
        return stepIndex == model.currentStepIndex ? DS.Colors.accentText : DS.Colors.textTertiary
    }
}

struct PermissionCardView: View {
    @ObservedObject var model: PermissionModel

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.tap.fill").foregroundColor(DS.Colors.warning)
                    Text("Pointwise wants to do this for you").font(.system(size: 13, weight: .bold)).foregroundColor(DS.Colors.textPrimary)
                }
                Text(model.actionDescription)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Not now") { model.onAnswer?(.notNow) }.buttonStyle(PointwiseButtonStyle())
                    Spacer()
                    Button("Always allow") { model.onAnswer?(.alwaysAllow) }.buttonStyle(PointwiseButtonStyle())
                    Button("Allow once") { model.onAnswer?(.allowOnce) }.buttonStyle(PointwiseButtonStyle(isProminent: true))
                }
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
        }
    }
}

// MARK: - Controller

/// Owns the floating teaching panels and turns them into async calls the
/// tool handlers can await (for example "wait until the quiz is answered").
@MainActor
final class TeachingPanelsController {
    let askBarModel = AskBarModel()
    let quizModel = QuizModel()
    let walkthroughModel = WalkthroughModel()
    let permissionModel = PermissionModel()
    let whiteboard = WhiteboardPanelController()

    var screenFramesProvider: () -> [CGRect] = { NSScreen.screens.map(\.frame) }
    var pointerLocationProvider: () -> CGPoint = { NSEvent.mouseLocation }

    private(set) var askBarPanel: FloatingPanel?
    private(set) var quizPanel: FloatingPanel?
    private(set) var walkthroughPanel: FloatingPanel?
    private(set) var permissionPanel: FloatingPanel?

    // MARK: Ask bar

    func showAskBar() {
        let panel = askBarPanel ?? {
            let newPanel = FloatingPanel(size: CGSize(width: 440, height: 50), acceptsKeyboardFocus: true)
            newPanel.setSwiftUIContent(AskBarView(model: askBarModel, settings: AppSettings.shared))
            askBarPanel = newPanel
            return newPanel
        }()
        askBarModel.draftText = ""
        panel.place(near: pointerLocationProvider(), offset: CGVector(dx: 24, dy: -70), on: screenFramesProvider())
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hideAskBar() {
        askBarPanel?.orderOut(nil)
    }

    var isAskBarVisible: Bool { askBarPanel?.isVisible ?? false }

    // MARK: Quiz

    private var quizAnswerContinuation: CheckedContinuation<Int?, Never>?

    /// Shows the quiz and waits for an answer (click or spoken letter). Nil if dismissed.
    func presentQuiz(question: String, choices: [String], correctIndex: Int, explanation: String) async -> Int? {
        quizModel.question = question
        quizModel.choices = choices
        quizModel.correctIndex = min(max(correctIndex, 0), max(choices.count - 1, 0))
        quizModel.explanation = explanation
        quizModel.chosenIndex = nil
        let panel = quizPanel ?? {
            let newPanel = FloatingPanel(size: CGSize(width: 380, height: 360))
            newPanel.setSwiftUIContent(QuizCardView(model: quizModel))
            quizPanel = newPanel
            return newPanel
        }()
        quizModel.onAnswer = { [weak self] chosenIndex in self?.finishQuiz(with: chosenIndex) }
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: 380, height: 300)
        panel.setContentSize(CGSize(width: 380, height: max(fittingSize.height, 200) + 70))
        panel.place(near: pointerLocationProvider(), offset: CGVector(dx: 50, dy: -panel.frame.height / 2), on: screenFramesProvider())
        panel.orderFrontRegardless()
        return await withCheckedContinuation { continuation in
            quizAnswerContinuation?.resume(returning: nil)
            quizAnswerContinuation = continuation
        }
    }

    var isQuizWaitingForAnswer: Bool { quizAnswerContinuation != nil }

    /// Answers the open quiz from speech, for example "B" or "the second one".
    func answerQuiz(choiceIndex: Int) {
        guard quizAnswerContinuation != nil, quizModel.chosenIndex == nil, quizModel.choices.indices.contains(choiceIndex) else { return }
        quizModel.chosenIndex = choiceIndex
        finishQuiz(with: choiceIndex)
    }

    func dismissQuiz() {
        quizAnswerContinuation?.resume(returning: nil)
        quizAnswerContinuation = nil
        quizPanel?.orderOut(nil)
    }

    private func finishQuiz(with chosenIndex: Int) {
        quizAnswerContinuation?.resume(returning: chosenIndex)
        quizAnswerContinuation = nil
        let panel = quizPanel
        if let panel, let fittingSize = panel.contentView?.fittingSize {
            panel.setContentSize(CGSize(width: 380, height: fittingSize.height))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            guard let self, self.quizAnswerContinuation == nil else { return }
            panel?.orderOut(nil)
        }
    }

    // MARK: Walkthrough

    func startWalkthrough(title: String, steps: [String]) {
        walkthroughModel.title = title
        walkthroughModel.steps = Array(steps.prefix(15))
        walkthroughModel.currentStepIndex = 0
        walkthroughModel.completedStepIndexes = []
        walkthroughModel.recap = nil
        walkthroughModel.isWaitingForLearner = false
        let panel = walkthroughPanel ?? {
            let newPanel = FloatingPanel(size: CGSize(width: 300, height: 300))
            newPanel.setSwiftUIContent(WalkthroughCardView(model: walkthroughModel))
            walkthroughPanel = newPanel
            return newPanel
        }()
        resizeWalkthroughPanel()
        let pointerLocation = pointerLocationProvider()
        let screenFrame = screenFramesProvider().first { $0.contains(pointerLocation) } ?? screenFramesProvider().first ?? .zero
        panel.setFrameOrigin(CGPoint(x: screenFrame.maxX - panel.frame.width - 18, y: screenFrame.maxY - panel.frame.height - 44))
        panel.orderFrontRegardless()
    }

    func setWalkthroughStep(_ stepIndex: Int, isWaiting: Bool) {
        guard !walkthroughModel.steps.isEmpty else { return }
        let clampedIndex = min(max(stepIndex, 0), walkthroughModel.steps.count - 1)
        for completedIndex in 0..<clampedIndex { walkthroughModel.completedStepIndexes.insert(completedIndex) }
        walkthroughModel.currentStepIndex = clampedIndex
        walkthroughModel.isWaitingForLearner = isWaiting
    }

    func completeWalkthroughStep(_ stepIndex: Int) {
        walkthroughModel.completedStepIndexes.insert(stepIndex)
        walkthroughModel.isWaitingForLearner = false
        if stepIndex + 1 < walkthroughModel.steps.count { walkthroughModel.currentStepIndex = stepIndex + 1 }
    }

    func finishWalkthrough(recap: String) {
        walkthroughModel.recap = recap
        walkthroughModel.isWaitingForLearner = false
        resizeWalkthroughPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard self?.walkthroughModel.recap == recap else { return }
            self?.walkthroughPanel?.orderOut(nil)
        }
    }

    func hideWalkthrough() {
        walkthroughPanel?.orderOut(nil)
        walkthroughModel.steps = []
    }

    var isWalkthroughActive: Bool { (walkthroughPanel?.isVisible ?? false) && walkthroughModel.recap == nil }

    private func resizeWalkthroughPanel() {
        guard let walkthroughPanel, let fittingSize = walkthroughPanel.contentView?.fittingSize else { return }
        let topEdge = walkthroughPanel.frame.maxY
        walkthroughPanel.setContentSize(CGSize(width: 300, height: fittingSize.height))
        walkthroughPanel.setFrameOrigin(CGPoint(x: walkthroughPanel.frame.minX, y: topEdge - fittingSize.height))
    }

    // MARK: Permission

    private var permissionContinuation: CheckedContinuation<PermissionModel.Answer, Never>?

    func requestActionPermission(description: String) async -> PermissionModel.Answer {
        permissionModel.actionDescription = description
        let panel = permissionPanel ?? {
            let newPanel = FloatingPanel(size: CGSize(width: 340, height: 130))
            newPanel.setSwiftUIContent(PermissionCardView(model: permissionModel))
            permissionPanel = newPanel
            return newPanel
        }()
        if let fittingSize = panel.contentView?.fittingSize { panel.setContentSize(fittingSize) }
        panel.place(near: pointerLocationProvider(), offset: CGVector(dx: 40, dy: 30), on: screenFramesProvider())
        panel.orderFrontRegardless()
        permissionModel.onAnswer = { [weak self] answer in
            self?.permissionContinuation?.resume(returning: answer)
            self?.permissionContinuation = nil
            self?.permissionPanel?.orderOut(nil)
        }
        return await withCheckedContinuation { continuation in
            permissionContinuation?.resume(returning: .notNow)
            permissionContinuation = continuation
        }
    }

    func dismissAll() {
        hideAskBar()
        dismissQuiz()
        permissionContinuation?.resume(returning: .notNow)
        permissionContinuation = nil
        permissionPanel?.orderOut(nil)
    }
}
