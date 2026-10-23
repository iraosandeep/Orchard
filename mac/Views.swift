import SwiftUI

struct ContentView: View {
    @Environment(ChatModel.self) var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.chats) { chat in
                    Text(chat.title.isEmpty ? "New chat" : chat.title)
                        .lineLimit(1)
                        .tag(chat.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.delete(chat.id) }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                Button { model.newChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    .help("New Chat (⌘N)")
            }
        } detail: {
            ChatDetail()
        }
    }
}

struct ChatDetail: View {
    @Environment(ChatModel.self) var model
    @ViewState private var draft = ""
    @ViewState private var showSystem = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages) { m in
                            MessageRow(role: m.role, text: m.content)
                        }
                        if let s = model.streaming {
                            MessageRow(role: "assistant", text: s.isEmpty ? "…" : s)
                        }
                        if let e = model.error {
                            Label(e, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(20)
                }
                .overlay {
                    if model.messages.isEmpty && model.streaming == nil {
                        ContentUnavailableView(
                            "Orchard", systemImage: "leaf",
                            description: Text("Chat with Apple's on-device model. Replies are drafts — check facts and code."))
                    }
                }
                .onChange(of: model.streaming) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer
        }
        .navigationTitle(model.current?.title ?? "Orchard")
        .toolbar {
            ToolbarItem {
                Button { showSystem.toggle() } label: { Label("System Prompt", systemImage: "text.badge.star") }
                    .help("System prompt")
                    .popover(isPresented: $showSystem) { SystemPromptEditor() }
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.selection) { draft = ""; focused = true }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator))
                if model.isStreaming {
                    Button(action: model.stop) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Return)")
                }
            }
            HStack(spacing: 8) {
                let used = model.tokens + (draft.isEmpty ? 0 : Assistant.estimate(draft) + 4)
                Gauge(value: Double(min(used, Assistant.budget)), in: 0...Double(Assistant.budget)) {}
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(used > Assistant.budget ? .orange : .accentColor)
                    .frame(width: 80)
                Text("\(used) / \(Assistant.budget) tokens")
                    .monospacedDigit()
                if used > Assistant.budget {
                    Text("· oldest turns will be left out")
                } else if !model.note.isEmpty {
                    Text("· \(model.note)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
        }
        .padding(12)
        .background(.bar)
    }

    func send() {
        guard !model.isStreaming else { return }
        let text = draft
        draft = ""
        model.send(text)
    }
}

struct MessageRow: View {
    let role: String
    let text: String
    @ViewState private var hovering = false

    var body: some View {
        HStack(alignment: .top) {
            if role == "user" { Spacer(minLength: 60) }
            Group {
                if role == "user" {
                    Text(text)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    Text(markdown(text))
                        .lineSpacing(2)
                }
            }
            .textSelection(.enabled)
            .contextMenu { Button("Copy") { copy() } }
            if role == "assistant" {
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy")
                    .opacity(hovering ? 1 : 0)
                Spacer(minLength: 60)
            }
        }
        .onHover { hovering = $0 }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

struct SystemPromptEditor: View {
    @Environment(ChatModel.self) var model
    @Environment(\.dismiss) var dismiss
    @ViewState private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System Prompt").font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 340, height: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack {
                Button("Reset") { text = defaultSystemPrompt }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.setSystemPrompt(text); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { text = model.current?.systemPrompt ?? "" }
    }
}
