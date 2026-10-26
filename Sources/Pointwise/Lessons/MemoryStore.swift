import Foundation

/// Text-only memory that persists between sessions. Screenshots are never
/// saved; only short facts and lesson transcripts in plain text.
@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published private(set) var rememberedFacts: [String] = []
    @Published private(set) var savedLessons: [SavedLesson] = []

    let storageDirectory: URL

    private var factsFileURL: URL { storageDirectory.appendingPathComponent("memory.md") }
    private var lessonsFileURL: URL { storageDirectory.appendingPathComponent("lessons.json") }

    init(storageDirectory: URL? = nil) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.storageDirectory = storageDirectory ?? applicationSupport.appendingPathComponent("Pointwise", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
        loadFromDisk()
    }

    /// Facts as a Markdown list for the system prompt.
    var memoryMarkdown: String {
        rememberedFacts.map { "- \($0)" }.joined(separator: "\n")
    }

    func remember(_ fact: String) {
        let trimmedFact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFact.isEmpty, !rememberedFacts.contains(trimmedFact) else { return }
        rememberedFacts.append(trimmedFact)
        // Keep memory small so it never crowds the conversation.
        if rememberedFacts.count > 40 { rememberedFacts.removeFirst(rememberedFacts.count - 40) }
        saveFacts()
    }

    func forget(_ fact: String) {
        rememberedFacts.removeAll { $0 == fact }
        saveFacts()
    }

    func forgetEverything() {
        rememberedFacts.removeAll()
        savedLessons.removeAll()
        saveFacts()
        saveLessons()
    }

    func saveLesson(_ lesson: SavedLesson) {
        savedLessons.removeAll { $0.id == lesson.id }
        savedLessons.insert(lesson, at: 0)
        if savedLessons.count > 50 { savedLessons.removeLast(savedLessons.count - 50) }
        saveLessons()
    }

    private func loadFromDisk() {
        if let factsText = try? String(contentsOf: factsFileURL, encoding: .utf8) {
            rememberedFacts = factsText
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .map { String($0.dropFirst(2)) }
        }
        if let lessonsData = try? Data(contentsOf: lessonsFileURL),
           let decodedLessons = try? JSONDecoder().decode([SavedLesson].self, from: lessonsData) {
            savedLessons = decodedLessons
        }
    }

    private func saveFacts() {
        let factsText = "# What Pointwise remembers about you\n\n" + memoryMarkdown + "\n"
        try? factsText.write(to: factsFileURL, atomically: true, encoding: .utf8)
    }

    private func saveLessons() {
        guard let encodedLessons = try? JSONEncoder().encode(savedLessons) else { return }
        try? encodedLessons.write(to: lessonsFileURL, options: .atomic)
    }
}

/// One conversation with Pointwise, saved as text so the learner can review it.
struct SavedLesson: Codable, Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var title: String
    var entries: [ConversationEntry]
    var studyNotesMarkdown: String?
}

struct ConversationEntry: Codable, Identifiable, Equatable {
    enum Speaker: String, Codable { case learner, pointwise }
    var id = UUID()
    var speaker: Speaker
    var text: String
    var date = Date()
}
