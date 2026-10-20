// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Server-sent events from an OpenAI-compatible chat endpoint with `"stream": true`,
/// as OpenAI, Ollama, LM Studio and llama.cpp send them: one `data:` line per piece.
public enum ChatStream {
    public enum Event: Equatable, Sendable {
        case text(String)
        case done
        case failed(String)
        case ignored
    }

    public static func event(_ line: String) -> Event {
        guard line.hasPrefix("data:") else { return .ignored }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .ignored }
        if let error = body["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? error as? String ?? "The AI provider stopped with an error."
            return .failed(String(message.prefix(300)))
        }
        guard let choice = (body["choices"] as? [[String: Any]])?.first else { return .ignored }
        if let text = (choice["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty { return .text(text) }
        return .ignored
    }

    /// The whole answer from a complete stream body, or nil when it holds no pieces.
    public static func text(of body: String) -> String? {
        var text = "", found = false
        for line in body.split(whereSeparator: \.isNewline) {
            if case .text(let piece) = event(String(line)) { text += piece; found = true }
        }
        return found ? text : nil
    }
}
