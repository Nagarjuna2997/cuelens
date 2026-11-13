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

struct KnowledgeFile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var text: String
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

    func answerSelection(for assistant: AssistantProfile) -> ProviderSelection {
        let provider = assistant.provider ?? answerProvider
        return ProviderSelection(provider: provider, model: assistant.model.isEmpty ? model(for: provider) : assistant.model)
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

    var id: Self { self }
}

struct TranscriptLine: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: TimeInterval
    var source: AudioSource
    var text: String

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
    var sentAudioToCloud = false
    var sentTextToCloud = false
    var audioFiles: [String]?

    var duration: TimeInterval { max(0, (endedAt ?? Date()).timeIntervalSince(startedAt)) }
}

struct SessionOptions: Equatable {
    var title = ""
    var microphone = true
    var meetingAudio = false
    var save = true
    var allowCloud = false
    var practice = false
    var saveAudio = false
}
