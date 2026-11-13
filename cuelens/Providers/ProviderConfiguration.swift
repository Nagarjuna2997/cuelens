import Foundation

enum ProviderError: LocalizedError, Equatable {
    case modelRequired, credentialUnavailable, providerDisabled
    case invalidResponse, emptyResponse, responseInterrupted, cloudApprovalRequired, refused, incomplete
    case http(Int)
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .modelRequired: "Enter a valid API model ID in Providers or in the assistant."
        case .credentialUnavailable: "Save the provider’s API key in Keychain first."
        case .providerDisabled: "Select an answer provider to generate suggestions."
        case .invalidResponse: "The provider returned an unsupported response."
        case .emptyResponse: "The provider completed without generating text."
        case .responseInterrupted: "The provider disconnected before completing its response."
        case .cloudApprovalRequired: "Allow cloud processing before sending session content."
        case .refused: "The provider declined this request."
        case .incomplete: "The provider reached its output limit. Retry with a shorter response."
        case .http(401), .http(403): "The provider rejected access. Check the API key and model permissions."
        case .http(404): "The model was unavailable. Check the model ID and access in Providers."
        case .http(429): "The provider is rate-limited or out of quota. Wait, then retry or choose your backup."
        case .http(500...599): "The provider is temporarily unavailable. Retry or choose your backup."
        case .http(let status): "The provider returned HTTP \(status)."
        case .keychain(let status): "Keychain returned an error (\(status))."
        }
    }
}

extension AnswerProvider {
    var credential: Credential? {
        switch self {
        case .disabled: nil
        case .openAI: .openAI
        case .claude: .claude
        case .gemini: .gemini
        }
    }

    var keyURL: URL? {
        switch self {
        case .disabled: nil
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .claude: URL(string: "https://platform.claude.com/settings/keys")
        case .gemini: URL(string: "https://aistudio.google.com/api-keys")
        }
    }

    var host: String {
        switch self {
        case .disabled: ""
        case .openAI: "api.openai.com"
        case .claude: "api.anthropic.com"
        case .gemini: "generativelanguage.googleapis.com"
        }
    }
}

struct ProviderConnection {
    let selection: ProviderSelection
    private let apiKey: String

    init(selection: ProviderSelection, credentials: any CredentialStore) throws {
        guard let credential = selection.provider.credential else { throw ProviderError.providerDisabled }
        let model = selection.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._:")
        guard !model.isEmpty, model.utf8.count <= 160,
              model.unicodeScalars.allSatisfy(modelCharacters.contains) else { throw ProviderError.modelRequired }
        guard let key = try credentials.read(credential), !key.isEmpty,
              !key.contains(where: { $0.isNewline }) else { throw ProviderError.credentialUnavailable }
        self.selection = ProviderSelection(provider: selection.provider, model: model)
        apiKey = key
    }

    func request(_ prompt: ProviderPrompt) throws -> URLRequest {
        let model = selection.model
        var url = URLComponents()
        url.scheme = "https"
        url.host = selection.provider.host
        var body: [String: Any]
        var auth: [String: String]
        switch selection.provider {
        case .disabled:
            throw ProviderError.providerDisabled
        case .openAI:
            url.path = "/v1/responses"
            auth = ["Authorization": "Bearer \(apiKey)"]
            body = ["model": model, "instructions": prompt.instructions, "input": prompt.input,
                    "max_output_tokens": prompt.outputLimit, "stream": true, "store": false]
        case .claude:
            url.path = "/v1/messages"
            auth = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
            body = ["model": model, "system": prompt.instructions,
                    "messages": [["role": "user", "content": prompt.input]], "max_tokens": prompt.outputLimit,
                    "stream": true]
        case .gemini:
            url.path = "/v1beta/models/\(model):streamGenerateContent"
            url.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            auth = ["x-goog-api-key": apiKey]
            body = ["systemInstruction": ["parts": [["text": prompt.instructions]]],
                    "contents": [["role": "user", "parts": [["text": prompt.input]]]],
                    "generationConfig": ["maxOutputTokens": prompt.outputLimit, "candidateCount": 1]]
        }
        guard let endpoint = url.url else { throw ProviderError.invalidResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (field, value) in auth { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

struct ProviderPrompt {
    let instructions: String
    let input: String
    let outputLimit: Int

    static let connectionTest = Self(instructions: "Reply with the single word Ready.", input: "Connection test.", outputLimit: 384)
}

final class NoProviderRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ProviderHTTP {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 90
        return URLSession(configuration: config, delegate: NoProviderRedirect(), delegateQueue: nil)
    }

    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw ProviderError.http(response.statusCode) }
    }
}
