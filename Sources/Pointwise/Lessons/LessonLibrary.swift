import AppKit
import SwiftUI

/// A ready-to-run guided lesson: open a site, then let Pointwise teach a goal step by step.
struct LessonPlan: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var subject: String
    var websiteURL: String
    var goal: String
    var isBuiltIn = false

    var subjectSymbolName: String {
        switch subject.lowercased() {
        case "math": return "function"
        case "science": return "atom"
        case "coding": return "chevron.left.forwardslash.chevron.right"
        case "data": return "chart.bar.xaxis"
        case "research", "writing": return "text.book.closed"
        case "music": return "music.note"
        case "art": return "paintpalette"
        case "geography": return "map"
        default: return "graduationcap"
        }
    }

    /// The question Pointwise receives when the lesson starts.
    var openingRequest: String {
        "Let's start the lesson \"\(title)\". My goal: \(goal) Guide me step by step on my screen with a walkthrough, and check my understanding at the end."
    }

    /// A pointwise:// link a teacher can share so students start the same lesson.
    var shareLink: URL? {
        var components = URLComponents()
        components.scheme = "pointwise"
        components.host = "lesson"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "url", value: websiteURL),
            URLQueryItem(name: "goal", value: goal),
        ]
        return components.url
    }

    init(title: String, subject: String, websiteURL: String, goal: String, isBuiltIn: Bool = false) {
        self.title = title
        self.subject = subject
        self.websiteURL = websiteURL
        self.goal = goal
        self.isBuiltIn = isBuiltIn
    }

    /// Reads a shared pointwise://lesson link. Only http and https websites are accepted.
    init?(shareLink: URL) {
        guard shareLink.scheme == "pointwise", shareLink.host == "lesson",
              let queryItems = URLComponents(url: shareLink, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { queryItems.first { $0.name == name }?.value }
        guard let title = value("title"), let goal = value("goal"), !title.isEmpty, !goal.isEmpty else { return nil }
        let websiteURL = value("url") ?? ""
        if !websiteURL.isEmpty {
            guard let parsedURL = URL(string: websiteURL), ["http", "https"].contains(parsedURL.scheme?.lowercased() ?? "") else { return nil }
        }
        self.init(title: String(title.prefix(80)), subject: value("subject") ?? "Other", websiteURL: websiteURL, goal: String(goal.prefix(500)))
    }

    static let builtInLessons: [LessonPlan] = [
        LessonPlan(title: "Graph a parabola", subject: "Math", websiteURL: "https://www.desmos.com/calculator",
                   goal: "Graph y = x² − 4x + 3 in Desmos, find where it crosses the x-axis, and find its lowest point.", isBuiltIn: true),
        LessonPlan(title: "Build a circuit", subject: "Science", websiteURL: "https://phet.colorado.edu/sims/html/circuit-construction-kit-dc/latest/circuit-construction-kit-dc_en.html",
                   goal: "Build a circuit with a battery, a wire, and a light bulb, and understand why the bulb lights up.", isBuiltIn: true),
        LessonPlan(title: "Your first Scratch program", subject: "Coding", websiteURL: "https://scratch.mit.edu/projects/editor/",
                   goal: "Make the cat move and say hello when the green flag is clicked, and learn what an event block is.", isBuiltIn: true),
        LessonPlan(title: "Make a chart", subject: "Data", websiteURL: "https://sheets.new",
                   goal: "Type a small table of data and turn it into a bar chart with a title.", isBuiltIn: true),
        LessonPlan(title: "Find and cite a source", subject: "Research", websiteURL: "https://en.wikipedia.org/wiki/Special:Random",
                   goal: "Find the references on a Wikipedia article, open one, and learn how to cite it.", isBuiltIn: true),
        LessonPlan(title: "Make a beat", subject: "Music", websiteURL: "https://musiclab.chromeexperiments.com/Song-Maker/",
                   goal: "Make a simple drum beat and melody, and learn what rhythm and tempo mean.", isBuiltIn: true),
        LessonPlan(title: "Complementary colors", subject: "Art", websiteURL: "https://color.adobe.com/create/color-wheel",
                   goal: "Use the color wheel to find complementary colors and learn why they look good together.", isBuiltIn: true),
        LessonPlan(title: "Measure distance on a map", subject: "Geography", websiteURL: "https://www.google.com/maps",
                   goal: "Measure the distance between two cities and learn how map scale works.", isBuiltIn: true),
    ]
}

/// Built-in lessons plus lessons the learner or a teacher made, saved as JSON.
@MainActor
final class LessonLibrary: ObservableObject {
    static let shared = LessonLibrary()

    @Published private(set) var customLessons: [LessonPlan] = []
    private let storageURL: URL

    init(storageDirectory: URL? = nil) {
        storageURL = (storageDirectory ?? MemoryStore.shared.storageDirectory).appendingPathComponent("lesson-plans.json")
        if let storedData = try? Data(contentsOf: storageURL), let decodedLessons = try? JSONDecoder().decode([LessonPlan].self, from: storedData) {
            customLessons = decodedLessons
        }
    }

    var allLessons: [LessonPlan] { customLessons + LessonPlan.builtInLessons }

    func add(_ lesson: LessonPlan) {
        customLessons.insert(lesson, at: 0)
        save()
    }

    func remove(_ lesson: LessonPlan) {
        customLessons.removeAll { $0.id == lesson.id }
        save()
    }

    private func save() {
        guard let encodedLessons = try? JSONEncoder().encode(customLessons) else { return }
        try? encodedLessons.write(to: storageURL, options: .atomic)
    }
}

struct LessonLibraryView: View {
    @ObservedObject var library: LessonLibrary
    let onStart: (LessonPlan) -> Void
    @State private var isCreatingLesson = false
    @State private var newTitle = ""
    @State private var newSubject = "Other"
    @State private var newWebsite = ""
    @State private var newGoal = ""
    @State private var copiedLessonIdentifier: UUID?

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 14)]
    private static let subjects = ["Math", "Science", "Coding", "Data", "Research", "Writing", "Music", "Art", "Geography", "Other"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lesson library").font(.system(size: 22, weight: .bold))
                    Text("Pick a lesson. Pointwise opens the right website and walks you through it on your screen.")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                }
                Spacer()
                Button(isCreatingLesson ? "Cancel" : "New lesson…") { isCreatingLesson.toggle() }
            }
            if isCreatingLesson { newLessonForm }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(library.allLessons) { lesson in lessonCard(lesson) }
                }
                .padding(.bottom, 10)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func lessonCard(_ lesson: LessonPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: lesson.subjectSymbolName).foregroundColor(.accentColor)
                Text(lesson.subject.uppercased()).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                if !lesson.isBuiltIn {
                    Button { library.remove(lesson) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
            }
            Text(lesson.title).font(.system(size: 15, weight: .semibold))
            Text(lesson.goal).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Start lesson") { onStart(lesson) }.buttonStyle(.borderedProminent)
                Button(copiedLessonIdentifier == lesson.id ? "Link copied" : "Share") {
                    guard let shareLink = lesson.shareLink else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shareLink.absoluteString, forType: .string)
                    copiedLessonIdentifier = lesson.id
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
    }

    private var newLessonForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Lesson title", text: $newTitle)
                Picker("", selection: $newSubject) { ForEach(Self.subjects, id: \.self) { Text($0) } }.labelsHidden().frame(width: 130)
            }
            TextField("Website to open (optional), for example https://www.desmos.com/calculator", text: $newWebsite)
            TextField("What should the student learn or do?", text: $newGoal, axis: .vertical).lineLimit(2...4)
            HStack {
                Text("Teachers: use Share to send students a link that starts this lesson in Pointwise.").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Save lesson") {
                    library.add(LessonPlan(title: newTitle, subject: newSubject, websiteURL: newWebsite, goal: newGoal))
                    newTitle = ""; newWebsite = ""; newGoal = ""
                    isCreatingLesson = false
                }
                .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || newGoal.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }
}
