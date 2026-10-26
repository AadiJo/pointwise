import SwiftUI

/// Lesson history, the live transcript, and AI-made study notes.
struct HomeView: View {
    @ObservedObject var companion: CompanionController
    @ObservedObject var memory: MemoryStore
    @State private var selectedLessonIdentifier: UUID?
    @State private var typedQuestion = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedLessonIdentifier) {
                Section("Now") {
                    Label("Current lesson", systemImage: "bubble.left.and.bubble.right").tag(nil as UUID?)
                }
                Section("Past lessons") {
                    ForEach(memory.savedLessons) { lesson in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lesson.title).lineLimit(1)
                            Text(lesson.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(.secondary)
                        }
                        .tag(lesson.id as UUID?)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let selectedLessonIdentifier, let lesson = memory.savedLessons.first(where: { $0.id == selectedLessonIdentifier }) {
                lessonDetail(entries: lesson.entries, notes: lesson.studyNotesMarkdown, isCurrent: false)
            } else {
                lessonDetail(entries: companion.conversation, notes: companion.studyNotesMarkdown, isCurrent: true)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func lessonDetail(entries: [ConversationEntry], notes: String?, isCurrent: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if entries.isEmpty {
                        Text("Hold Control + Option and ask Pointwise anything, or type below.")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(entries) { entry in
                        HStack(alignment: .top) {
                            if entry.speaker == .learner { Spacer(minLength: 60) }
                            Text(entry.text)
                                .textSelection(.enabled)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(entry.speaker == .learner ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12)))
                            if entry.speaker == .pointwise { Spacer(minLength: 60) }
                        }
                    }
                    if let notes {
                        Divider().padding(.vertical, 6)
                        Label("Study notes", systemImage: "note.text").font(.headline)
                        Text((try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(notes))
                            .textSelection(.enabled)
                        Button("Copy notes") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(notes, forType: .string)
                        }
                    }
                }
                .padding(20)
            }
            if isCurrent {
                Divider()
                HStack(spacing: 8) {
                    TextField("Type a question for Pointwise…", text: $typedQuestion)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendTypedQuestion)
                    Button("Ask", action: sendTypedQuestion).disabled(typedQuestion.isEmpty)
                    Button("Make study notes") { companion.makeStudyNotes() }.disabled(companion.conversation.isEmpty)
                    Button("New lesson") { companion.startNewLesson() }
                }
                .padding(12)
            }
        }
    }

    private func sendTypedQuestion() {
        let question = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        typedQuestion = ""
        companion.handleLearnerInput(question, inputMode: "typed")
    }
}
