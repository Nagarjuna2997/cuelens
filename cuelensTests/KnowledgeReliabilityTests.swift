import XCTest
@testable import cuelens

final class KnowledgeReliabilityTests: XCTestCase {
    func testShortTechnicalSkillsAndPunctuationRetrieveTheRightMaterial() {
        let skills = ["Go", "AI", "ML", "C++", "C#", ".NET", "Node.js", "R"]
        let documents = skills.enumerated().map { index, skill in
            KnowledgeFile(name: "Project \(index)", text: "Built a prototype using \(skill).", kind: .resume)
        }
        let index = KnowledgeIndex(assistant: .init(knowledge: documents))
        for (number, skill) in skills.enumerated() {
            let context = index.context(for: "Tell me about \(skill).", limit: 1_000)
            XCTAssertTrue(context.contains("[Resume · Project \(number)]"), skill)
            for other in documents.indices where other != number {
                XCTAssertFalse(context.contains("[Resume · Project \(other)]"), "\(skill) matched Project \(other)")
            }
        }
    }

    func testPastedJobDescriptionRemainsRetrievableBeyondThePromptOpening() {
        let description = String(repeating: "General responsibilities and collaboration. ", count: 45)
            + "Required specialization: Kubernetes admission controllers."
        let assistant = AssistantProfile(jobDescription: description, background: "Built an iOS application.")
        let index = KnowledgeIndex(assistant: assistant)
        let prompt = AnswerPrompts.make(task: .practiceQuestion, question: "Ask about Kubernetes admission controllers.",
                                       assistant: assistant, index: index, recent: [], length: .short, preset: .low)
        XCTAssertTrue(prompt.input.contains("Kubernetes admission controllers"))
        XCTAssertTrue(prompt.input.contains("[Job description · Role requirements, not personal experience]"))
        XCTAssertTrue(prompt.instructions.contains("zero evidence of the user's experience"))
        XCTAssertEqual(assistant.background, "Built an iOS application.")
    }

    func testUTF16ImportPreservesKindAndEnforcesTextLimit() throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: "Notes.txt")
        let source = "  中文 résumé \0" + String(repeating: "work ", count: 21_000)
        try XCTUnwrap(source.data(using: .utf16)).write(to: file)
        let imported = try KnowledgeImport.read(file, kind: .reference)
        XCTAssertEqual(imported.name, "Notes.txt")
        XCTAssertEqual(imported.kind, .reference)
        XCTAssertTrue(imported.text.hasPrefix("中文 résumé "))
        XCTAssertFalse(imported.text.contains("\0"))
        XCTAssertEqual(imported.text.count, KnowledgeImport.textLimit)
    }
}
