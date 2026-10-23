import Foundation
import Observation

@MainActor @Observable
final class ChatModel {
    var chats: [Chat] = []
    var selection: Int64? { didSet { if selection != oldValue { loadMessages() } } }
    var messages: [ChatMessage] = []
    var streaming: String?  // reply in progress
    var note: String = ""  // trimming notes for the last send
    var error: String?
    var tokens = 0  // tokens the next request costs before the draft

    private let store: Store?
    private var task: Task<Void, Never>?

    init() {
        do { store = try Store() } catch {
            store = nil
            self.error = Assistant.describe(error)
        }
        reloadChats()
        if let first = chats.first { selection = first.id } else { newChat() }
    }

    var current: Chat? { chats.first { $0.id == selection } }
    var isStreaming: Bool { task != nil }

    func reloadChats() {
        chats = (try? store?.chats()) ?? []
    }

    func newChat() {
        // Reuse an empty chat instead of piling them up.
        if let c = current, messages.isEmpty, c.title == "New chat" { return }
        guard let c = try? store?.createChat() else { return }
        chats.insert(c, at: 0)
        selection = c.id
    }

    func delete(_ id: Int64) {
        try? store?.delete(id)
        reloadChats()
        if selection == id { selection = chats.first?.id }
        if chats.isEmpty { newChat() }
    }

    func setSystemPrompt(_ s: String) {
        guard var c = current else { return }
        c.systemPrompt = s
        try? store?.update(c)
        reloadChats()
        refreshTokens()
    }

    func loadMessages() {
        stop()
        messages = selection.flatMap { try? store?.messages($0) } ?? []
        note = ""
        error = nil
        refreshTokens()
    }

    func refreshTokens() {
        guard let c = current else {
            tokens = 0
            return
        }
        let history = messages
        Task {
            let f = await Assistant.fit(system: c.systemPrompt, history: history, prompt: "")
            tokens = f.tokens
        }
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var chat = current, task == nil else { return }
        if let reason = Assistant.unavailableReason {
            error = reason
            return
        }
        error = nil
        let history = messages
        if history.isEmpty {
            chat.title =
                String(text.split(whereSeparator: \.isNewline).first ?? "").prefix(48).description
            try? store?.update(chat)
            reloadChats()
        }
        if let m = try? store?.add(chat.id, role: "user", content: text) { messages.append(m) }
        streaming = ""
        task = Task {
            let f = await Assistant.fit(system: chat.systemPrompt, history: history, prompt: text)
            var notes: [String] = []
            if f.dropped > 0 {
                notes.append(
                    "\(f.dropped) oldest message\(f.dropped == 1 ? "" : "s") left out to fit")
            }
            if f.truncated { notes.append("your message was truncated to fit") }
            note = notes.joined(separator: " · ")
            var reply = ""
            do {
                for try await partial in Assistant.stream(f) {
                    reply = partial
                    streaming = partial
                }
            } catch is CancellationError {
            } catch {
                self.error = Assistant.describe(error)
            }
            let m =
                reply.isEmpty ? nil : try? store?.add(chat.id, role: "assistant", content: reply)
            task = nil
            guard selection == chat.id else { return }  // user switched chats meanwhile
            if let m { messages.append(m) }
            streaming = nil
            refreshTokens()
        }
    }

    func stop() {
        task?.cancel()
        streaming = nil
    }
}
