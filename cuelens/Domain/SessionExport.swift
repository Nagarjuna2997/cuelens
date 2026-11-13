import Foundation

enum SessionExport {
    enum Format: String, CaseIterable, Identifiable {
        case text = "Plain text"
        case markdown = "Markdown"

        var id: Self { self }
        var fileExtension: String { self == .text ? "txt" : "md" }
    }

    static func transcript(_ session: MeetingSession) -> String {
        let lines = session.transcript.map { line in
            "[\(line.timestamp)] \(line.source.rawValue)\(line.provisional == true ? " (unfinalized)" : ""): \(line.text)"
        }.joined(separator: "\n")
        guard let notice = session.transcriptionNotice else { return lines }
        return notice + (lines.isEmpty ? "" : "\n\n" + lines)
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
            Duration: \(seconds(session.duration)) seconds
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
        if let attempts = session.practiceAttempts, !attempts.isEmpty {
            result += "\n\(heading)Practice review\n"
            if let style = session.practiceStyle { result += "\nInterview: \(style.rawValue)\n" }
            for attempt in attempts {
                let question = markdown ? escape(attempt.question) : attempt.question
                result += "\n\(markdown ? "### " : "")\(question)\n\nAnswer: \(attempt.response)\n\nFeedback: \(attempt.feedback)\n"
                result += "\nWords: \(attempt.metrics.wordCount) · Fillers: \(attempt.metrics.fillerCount)"
                if let pace = attempt.metrics.wordsPerMinute, pace.isFinite {
                    result += String(format: " · Pace: %.0f words/min", pace)
                }
                if let pauses = attempt.metrics.longPauseCount { result += " · Long pauses: \(pauses)" }
                result += "\nDelivery measurements are transcript-based estimates.\n"
                if !attempt.metrics.repeatedPhrases.isEmpty {
                    result += "Repeated phrases: \(attempt.metrics.repeatedPhrases.joined(separator: ", "))\n"
                }
                if let topic = attempt.reviewTopic { result += "Review topic: \(topic)\n" }
                if let date = attempt.nextReview { result += "Review date: \(date.formatted(date: .abbreviated, time: .omitted))\n" }
            }
        }
        return result
    }

    private static func seconds(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "0" }
        return String(format: "%.0f", max(0, duration).rounded(.down))
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
