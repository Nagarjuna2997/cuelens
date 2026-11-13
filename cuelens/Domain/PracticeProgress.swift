import Foundation

struct PracticeSpeechSegment {
    let text: String
    let began: Date
    let ended: Date
}

struct PracticeMetrics: Codable, Equatable {
    let wordCount: Int
    let fillerCount: Int
    let repeatedPhrases: [String]
    let wordsPerMinute: Double?
    let longPauseCount: Int?
    let spokenDuration: TimeInterval?

    static func analyze(text: String, speech: [PracticeSpeechSegment] = []) -> Self {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        let fillers: Set<String> = ["um", "uh", "erm", "hmm"]
        var fillerCount = words.filter { fillers.contains($0) }.count
        var phrases = [String: Int]()
        if words.count >= 2 {
            for index in 0..<(words.count - 1) {
                let pair = words[index] + " " + words[index + 1]
                if pair == "you know" || pair == "i mean" { fillerCount += 1 }
            }
        }
        if words.count >= 3 {
            for index in 0..<(words.count - 2) {
                let phrase = words[index...index + 2].joined(separator: " ")
                phrases[phrase, default: 0] += 1
            }
        }
        let repeated = phrases.filter { $0.value > 1 }.keys.sorted()
        let sorted = speech.sorted { $0.began < $1.began }
        let duration: TimeInterval?
        let pauses: Int?
        if let first = sorted.first, let last = sorted.last, last.ended > first.began {
            duration = last.ended.timeIntervalSince(first.began)
            pauses = zip(sorted, sorted.dropFirst()).filter { $0.1.began.timeIntervalSince($0.0.ended) >= 2 }.count
        } else {
            duration = nil
            pauses = nil
        }
        let pace = duration.flatMap { $0 >= 3 ? Double(words.count) / $0 * 60 : nil }
        return Self(wordCount: words.count, fillerCount: fillerCount, repeatedPhrases: repeated,
                    wordsPerMinute: pace, longPauseCount: pauses, spokenDuration: duration)
    }
}

enum PracticeFeedbackState: String, Codable {
    case pending, partial, completed, interrupted, failed
}

struct PracticeAttempt: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var question: String
    var response: String
    var feedback = ""
    var metrics: PracticeMetrics
    var reviewTopic: String?
    var nextReview: Date?
    // Optional for sessions saved before feedback status was recorded.
    var feedbackState: PracticeFeedbackState?
    var feedbackError: String?

    var effectiveFeedbackState: PracticeFeedbackState {
        feedbackState ?? (feedback.isEmpty ? .interrupted : .completed)
    }

    var feedbackStatus: String {
        switch effectiveFeedbackState {
        case .pending, .partial: "Feedback incomplete"
        case .completed: "Feedback complete"
        case .interrupted: "Feedback interrupted"
        case .failed: "Feedback unavailable"
        }
    }

    static func topic(in feedback: String) -> String? {
        for line in feedback.components(separatedBy: .newlines) {
            let clean = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
            guard clean.lowercased().hasPrefix("practice topic:") else { continue }
            let topic = clean.dropFirst("practice topic:".count).trimmingCharacters(in: .whitespaces)
            if !topic.isEmpty { return String(topic.prefix(180)) }
        }
        return nil
    }
}
