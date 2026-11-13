import Foundation

enum SessionExport {
    enum Format: String, CaseIterable, Identifiable {
        case text = "Plain text"
        case markdown = "Markdown"

        var id: Self { self }
        var fileExtension: String { self == .text ? "txt" : "md" }
    }

    static func transcript(_ session: MeetingSession) -> String {
        session.transcript.map { line in
            "[\(line.timestamp)] \(line.source.rawValue)\(line.provisional == true ? " (unfinalized)" : ""): \(line.text)"
        }.joined(separator: "\n")
    }

    static func render(_ session: MeetingSession, format: Format) -> String {
        let markdown = format == .markdown
        let heading = markdown ? "## " : ""
        let title = markdown ? "# " + escape(session.title) : session.title
        let cloud = [session.sentAudioToCloud ? "Audio" : nil, session.sentTextToCloud ? "Text or images" : nil,
                     session.summaryProvider != nil ? "Summary input" : nil].compactMap { $0 }
        let date = session.startedAt.formatted(date: .abbreviated, time: .shortened)
        let status = session.endedAt == nil ? "\nStatus: Recovered session checkpoint" : ""
        var result = """
            \(title)

            Assistant: \(markdown ? escape(session.assistantName) : session.assistantName)
            Started: \(date)\(status)
            Duration: \(Int(session.duration.rounded(.down))) seconds
            Cloud processing: \(cloud.isEmpty ? "None recorded" : cloud.joined(separator: ", "))

            \(heading)Transcript

            """
        result += transcript(session) + "\n"
        if !session.suggestions.isEmpty {
            result += "\n\(heading)Questions and suggestions\n"
            for suggestion in session.suggestions {
                let question = markdown ? escape(suggestion.question) : suggestion.question
                result += "\n\(markdown ? "### " : "")\(question) · \(suggestion.provider.shortName)\n\n\(suggestion.answer)\n"
            }
        }
        if !session.summary.isEmpty {
            result += "\n\(heading)Summary\n\n\(session.summary)\n"
        }
        return result
    }

    private static func escape(_ value: String) -> String {
        let inline = value.replacingOccurrences(of: "\n", with: " ")
        let characters = "\\`*_{}[]<>()#+-!|"
        return inline.reduce(into: "") { result, character in
            if characters.contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
