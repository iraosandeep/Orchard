// Talks to Apple's on-device model through FoundationModels directly (no
// fm serve needed). Same rules as the Go guard: plain text, no tools, and
// every request trimmed to fit the context window.
import Foundation
import FoundationModels

enum Assistant {
    static let model = SystemLanguageModel.default
    /// Rewrite transforms text the user supplied, which is what Apple's
    /// permissive guardrail mode is for; chat keeps the default guardrails.
    static let rewriteModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    /// Tokens kept free for the reply.
    static let replyReserve = 1000
    static var contextSize: Int { model.contextSize }
    static var budget: Int { contextSize - replyReserve }

    /// nil when the model is ready, otherwise why it isn't.
    static var unavailableReason: String? {
        switch model.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady):
            return "The model is still downloading. Try again shortly."
        case .unavailable(let other): return "Model unavailable: \(other)"
        }
    }

    static func estimate(_ s: String) -> Int { (s.count + 3) / 4 }

    static func tokens(_ entries: [Transcript.Entry]) async -> Int {
        if let n = try? await model.tokenCount(for: entries) { return n }
        return entries.reduce(0) { $0 + estimate(text(of: $1)) + 4 }
    }

    static func text(of e: Transcript.Entry) -> String {
        let segs: [Transcript.Segment]
        switch e {
        case .instructions(let i): segs = i.segments
        case .prompt(let p): segs = p.segments
        case .response(let r): segs = r.segments
        default: segs = []
        }
        return segs.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
    }

    static func entry(_ role: String, _ content: String) -> Transcript.Entry {
        let seg = Transcript.Segment.text(.init(content: content))
        switch role {
        case "system": return .instructions(.init(segments: [seg], toolDefinitions: []))
        case "assistant": return .response(.init(assetIDs: [], segments: [seg]))
        default: return .prompt(.init(segments: [seg]))
        }
    }

    struct Fitted {
        var history: [Transcript.Entry]  // instructions + earlier turns
        var prompt: String
        var dropped: Int
        var truncated: Bool
        var tokens: Int
    }

    /// Drops the oldest turns (and truncates the prompt as a last resort) so
    /// that instructions + history + prompt fit the budget.
    static func fit(system: String, history: [ChatMessage], prompt: String) async -> Fitted {
        let head =
            system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : [entry("system", system)]
        var turns = history.map { entry($0.role, $0.content) }
        var prompt = prompt
        var dropped = 0
        var truncated = false
        var n = await tokens(head + turns + [entry("user", prompt)])
        while n > budget, !turns.isEmpty {
            turns.removeFirst()
            dropped += 1
            if case .response = turns.first {
                turns.removeFirst()
                dropped += 1
            }
            n = await tokens(head + turns + [entry("user", prompt)])
        }
        while n > budget, prompt.count > 200 {
            prompt = String(
                prompt.prefix(Int(Double(prompt.count) * Double(budget) / Double(n) * 0.95)))
            truncated = true
            n = await tokens(head + [entry("user", prompt)])
        }
        return Fitted(
            history: head + turns, prompt: prompt, dropped: dropped, truncated: truncated, tokens: n
        )
    }

    /// Streams the reply; each element is the full text so far.
    static func stream(_ f: Fitted) -> AsyncThrowingStream<String, Error> {
        stream(
            session: LanguageModelSession(transcript: Transcript(entries: f.history)),
            prompt: f.prompt)
    }

    static func stream(instructions: String, input: String) -> AsyncThrowingStream<String, Error> {
        stream(session: LanguageModelSession(model: rewriteModel, instructions: instructions), prompt: input)
    }

    /// A short, human message for model errors.
    static func describe(_ error: Error) -> String {
        let blocked = "The on-device model's safety filter declined this. Try rephrasing."
        let busy = "The model is busy or rate-limited. Try again in a moment."
        let tooLong = "That's too long for the model's context window."
        if #available(macOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .guardrailViolation, .refusal: return blocked
            case .rateLimited: return busy
            case .contextSizeExceeded: return tooLong
            default: break
            }
        }
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .guardrailViolation, .refusal: return blocked
            case .rateLimited, .concurrentRequests: return busy
            case .exceededContextWindowSize: return tooLong
            default: break
            }
        }
        return error.localizedDescription
    }

    private static func stream(session: LanguageModelSession, prompt: String)
        -> AsyncThrowingStream<String, Error>
    {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await snap in session.streamResponse(to: prompt) {
                        cont.yield(snap.content)
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
