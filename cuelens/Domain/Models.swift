import Foundation

enum MeetingKind: String, Codable, CaseIterable, Identifiable {
    case interview = "Interview"
    case mockInterview = "Mock interview"
    case work = "Work meeting"
    case sales = "Sales"
    case technical = "Technical discussion"
    case custom = "Custom"

    var id: Self { self }
}

enum AnswerFormat: String, Codable, CaseIterable, Identifiable {
    case talkingPoints = "Talking points"
    case conversational = "Conversational"
    case star = "STAR"
    case technical = "Technical explanation"
    case coding = "Coding hints"
    case actions = "Action points"

    var id: Self { self }
}

enum AnswerLength: String, Codable, CaseIterable, Identifiable {
    case short = "Short"
    case standard = "Standard"
    case detailed = "Detailed"

    var id: Self { self }
}

enum AnswerProvider: String, Codable, CaseIterable, Identifiable {
    case disabled = "Off"
    case openAI = "ChatGPT (OpenAI API)"
    case claude = "Claude (Anthropic API)"
    case gemini = "Gemini (Google API)"

    var id: Self { self }

    var shortName: String {
        switch self {
        case .disabled: "Off"
        case .openAI: "OpenAI"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    var suggestedModel: String {
        switch self {
        case .disabled: ""
        case .openAI: "gpt-5.4-mini"
        case .claude: "claude-haiku-5-5"
        case .gemini: "gemini-3.8-flash"
        }
    }

    static let cloudProviders = [openAI, claude, gemini]
}

enum SpeechProvider: String, Codable, CaseIterable, Identifiable {
    case onDevice = "Apple on-device"
    case openAI = "OpenAI Realtime"

    var id: Self { self }
}

enum ResourcePreset: String, Codable, CaseIterable, Identifiable {
    case low = "Low"
    case balanced = "Balanced"
    case performance = "Performance"

    var id: Self { self }
}

enum MaterialKind: String, Codable, CaseIterable, Identifiable {
    case resume = "Resume"
    case job = "Job description"
    case reference = "Reference"

    var id: Self { self }
}

struct KnowledgeFile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
    var kind: MaterialKind?
}

struct CustomResponse: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var instructions = ""
}

struct AssistantProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var purpose = ""
    var kind = MeetingKind.interview
    var jobTitle = ""
    var company = ""
    var jobDescription = ""
    var background = ""
    var knowledge = [KnowledgeFile]()
    var instructions = ""
    var format = AnswerFormat.talkingPoints
    var length = AnswerLength.short
    var language = "English"
    var tone = ""
    var provider: AnswerProvider?
    var model = ""
    var liveSuggestions = true
    var retainSession = true
    var archived = false
    var customResponses: [CustomResponse]?

    func duplicate() -> Self {
        var copy = self
        copy.id = UUID()
        copy.name += " Copy"
        copy.archived = false
        return copy
    }
}

struct Preferences: Codable, Equatable {
    var setupComplete = false
    var answerProvider = AnswerProvider.disabled
    var models: [String: String]?
    var speechProvider = SpeechProvider.onDevice
    var speechLocale = "en-US"
    var resourcePreset = ResourcePreset.balanced
    var microphoneID: String?
    var backupProvider: AnswerProvider?
    var saveRawAudio: Bool?
    var sessionMicrophone: Bool?
    var sessionMeetingAudio: Bool?
    var sessionScreenContext: Bool?
    var startCameraWithSession: Bool?

    func answerSelection(for assistant: AssistantProfile) -> ProviderSelection {
        let provider = assistant.provider ?? answerProvider
        let override = assistant.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderSelection(provider: provider, model: override.isEmpty ? model(for: provider) : override)
    }

    func model(for provider: AnswerProvider) -> String {
        models?[provider.shortName] ?? provider.suggestedModel
    }

    mutating func setModel(_ name: String, for provider: AnswerProvider) {
        var values = models ?? [:]
        values[provider.shortName] = name
        models = values
    }
}

struct ProviderSelection: Equatable {
    let provider: AnswerProvider
    let model: String
}

enum AudioSource: String, Codable, CaseIterable, Identifiable {
    case microphone = "Me"
    case meeting = "Meeting audio"
    case manual = "Typed"
    case practice = "Mock interviewer"

    var id: Self { self }
}

struct TranscriptLine: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: TimeInterval
    var source: AudioSource
    var text: String
    var provisional: Bool?

    var timestamp: String {
        let seconds = Int(max(0, min(time.isFinite ? time : 0, 359_999)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

struct Suggestion: Codable, Equatable, Identifiable {
    var id = UUID()
    var question: String
    var answer: String
    var provider: AnswerProvider
    var pinned: Bool?
}

struct MeetingSession: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var assistantID: UUID
    var assistantName: String
    var startedAt = Date()
    var endedAt: Date?
    var transcript = [TranscriptLine]()
    var suggestions = [Suggestion]()
    var summary = ""
    var summaryProvider: AnswerProvider?
    var sentAudioToCloud = false
    var sentTextToCloud = false
    var audioFiles: [String]?
    var practiceAttempts: [PracticeAttempt]?
    var practiceStyle: PracticeStyle?
    var transcriptionIncompleteSources: [AudioSource]?

    var transcriptionNotice: String? {
        guard let sources = transcriptionIncompleteSources, !sources.isEmpty else { return nil }
        let names = sources.map(\.rawValue).joined(separator: ", ")
        return "Some buffered speech could not be transcribed before this session ended (\(names)). The saved transcript may be incomplete."
    }

    var duration: TimeInterval {
        if let endedAt { return max(0, endedAt.timeIntervalSince(startedAt)) }
        return max(0, transcript.last?.time ?? 0)
    }
}

struct SessionOptions: Equatable {
    var title = ""
    var microphone = true
    var meetingAudio = false
    var save = true
    var allowCloud = false
    var practice = false
    var saveAudio = false
    var automaticAnswers = false
    var screenContext = false
    var previewCamera = false
    var practiceStyle = PracticeStyle.behavioral
    var practiceHints = true
    var reviewTopic: String?
}

enum PracticeStyle: String, Codable, CaseIterable, Identifiable {
    case behavioral = "Behavioral"
    case technical = "Technical"
    case coding = "Coding discussion"
    case project = "Project deep dive"

    var id: Self { self }
}
