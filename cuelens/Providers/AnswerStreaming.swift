import Foundation

struct TokenUsage: Equatable {
    var input: Int?
    var output: Int?

    mutating func merge(_ usage: Self) {
        if let input = usage.input { self.input = input }
        if let output = usage.output { self.output = output }
    }
}

enum AnswerEvent: Equatable {
    case text(String)
    case usage(TokenUsage)
    case finished
}

protocol AnswerStreaming {
    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws
}

struct HTTPAnswerStream: AnswerStreaming {
    func stream(_ prompt: ProviderPrompt, connection: ProviderConnection,
                emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        try Task.checkCancellation()
        let (bytes, response) = try await ProviderHTTP.answers.bytes(for: connection.request(prompt))
        defer { bytes.task.cancel() }
        try ProviderHTTP.validate(response)
        try await withTaskCancellationHandler {
            try await consume(bytes, provider: connection.selection.provider, emit: emit)
        } onCancel: {
            bytes.task.cancel()
        }
    }

    private func consume(_ bytes: URLSession.AsyncBytes, provider: AnswerProvider,
                         emit: @escaping @Sendable (AnswerEvent) async -> Void) async throws {
        try Task.checkCancellation()
        var reader = ServerSentEvents()
        var receivedText = false
        var completed = false
        for try await byte in bytes {
            guard let payload = try reader.consume(byte: byte) else { continue }
            try Task.checkCancellation()
            for event in try AnswerEvent.decode(payload, provider: provider) {
                if case .text(let token) = event, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    receivedText = true
                }
                if event == .finished { completed = true }
                await emit(event)
            }
            if completed { break }
        }
        guard completed else { throw ProviderError.responseInterrupted }
        guard receivedText else { throw ProviderError.emptyResponse }
    }
}

struct ServerSentEvents {
    private var data = [String]()
    private var size = 0
    private var line = [UInt8]()
    private var afterCarriageReturn = false

    mutating func consume(byte: UInt8) throws -> String? {
        if byte == 10, afterCarriageReturn {
            afterCarriageReturn = false
            return nil
        }
        afterCarriageReturn = byte == 13
        if byte == 10 || byte == 13 {
            let value = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            return try consume(value)
        }
        guard line.count < 512_000 else { throw ProviderError.invalidResponse }
        line.append(byte)
        return nil
    }

    mutating func consume(_ line: String) throws -> String? {
        if line.isEmpty {
            guard !data.isEmpty else { return nil }
            defer { data.removeAll(keepingCapacity: true); size = 0 }
            return data.joined(separator: "\n")
        }
        guard line == "data" || line.hasPrefix("data:") else { return nil }
        var value = line.dropFirst(5)
        if value.first == " " { value = value.dropFirst() }
        size += value.utf8.count + 1
        guard size <= 512_000 else { throw ProviderError.invalidResponse }
        data.append(String(value))
        return nil
    }
}

extension AnswerEvent {
    static func decode(_ payload: String, provider: AnswerProvider) throws -> [Self] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        let type = object["type"] as? String
        if let error = object["error"] as? [String: Any] {
            throw streamError(error)
        }
        switch provider {
        case .openAI:
            switch type {
            case "response.output_text.delta":
                return (object["delta"] as? String).map { [.text($0)] } ?? []
            case "response.refusal.delta", "response.refusal.done":
                throw ProviderError.refused
            case "response.completed":
                let response = object["response"] as? [String: Any]
                return usage(response?["usage"], input: "input_tokens", output: "output_tokens") + [.finished]
            case "response.incomplete":
                let response = object["response"] as? [String: Any]
                let details = response?["incomplete_details"] as? [String: Any]
                throw details?["reason"] as? String == "content_filter" ? ProviderError.refused : ProviderError.incomplete
            case "response.failed", "error":
                let response = object["response"] as? [String: Any]
                throw streamError(response?["error"] as? [String: Any] ?? object)
            default: return []
            }
        case .claude:
            switch type {
            case "content_block_start":
                let block = object["content_block"] as? [String: Any]
                if block?["type"] as? String == "text", let text = block?["text"] as? String, !text.isEmpty {
                    return [.text(text)]
                }
                return []
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { return [.text(text)] }
                return []
            case "message_start":
                let message = object["message"] as? [String: Any]
                return usage(message?["usage"], input: "input_tokens", output: "output_tokens")
            case "message_delta":
                let delta = object["delta"] as? [String: Any]
                if delta?["stop_reason"] as? String == "refusal" { throw ProviderError.refused }
                if let reason = delta?["stop_reason"] as? String,
                   reason == "max_tokens" || reason == "model_context_window_exceeded" {
                    throw ProviderError.incomplete
                }
                return usage(object["usage"], input: "input_tokens", output: "output_tokens")
            case "message_stop": return [.finished]
            case "error": throw ProviderError.invalidResponse
            default: return []
            }
        case .gemini:
            var events = [Self]()
            let feedback = object["promptFeedback"] as? [String: Any]
            if feedback?["blockReason"] != nil { throw ProviderError.refused }
            let candidate = (object["candidates"] as? [[String: Any]])?.first
            let content = candidate?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            events += parts.compactMap { part in
                guard part["thought"] as? Bool != true, let text = part["text"] as? String else { return nil }
                return .text(text)
            }
            events += usage(object["usageMetadata"], input: "promptTokenCount", output: "candidatesTokenCount")
            if let finish = candidate?["finishReason"] as? String, finish != "FINISH_REASON_UNSPECIFIED" {
                if finish == "MAX_TOKENS" { throw ProviderError.incomplete }
                guard finish == "STOP" else { throw ProviderError.refused }
                events.append(.finished)
            }
            return events
        case .disabled:
            throw ProviderError.providerDisabled
        }
    }

    private static func usage(_ value: Any?, input: String, output: String) -> [Self] {
        guard let data = value as? [String: Any] else { return [] }
        return [.usage(TokenUsage(input: data[input] as? Int, output: data[output] as? Int))]
    }

    private static func streamError(_ error: [String: Any]) -> ProviderError {
        if let code = error["code"] as? Int { return .http(code) }
        let code = error["type"] as? String ?? error["code"] as? String
        switch code {
        case "rate_limit_error", "rate_limit_exceeded", "insufficient_quota": return .http(429)
        case "overloaded_error", "server_error", "api_error": return .http(503)
        case "authentication_error", "invalid_api_key": return .http(401)
        default: return .invalidResponse
        }
    }
}
