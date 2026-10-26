import SwiftUI

struct ContentView: View {
    @Environment(ChatModel.self) var model
    @Environment(\.openSettings) private var openSettings

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
                Button {
                    model.newChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat (⌘N)")
            }
        } detail: {
            ChatDetail()
        }
        .task {
            // On launch, open Setup if something needs the user's attention.
            try? await Task.sleep(for: .seconds(2))
            if Services.shared.needsSetup { openSettings() }
        }
    }
}

struct ChatDetail: View {
    @Environment(ChatModel.self) var model
    @ViewState private var draft = ""
    @ViewState private var cursor: TextSelection?
    @ViewState private var pendingTask: ChatTask?  // applies to the draft / file on send
    @ViewState private var taskOption = ""
    @ViewState private var highlighted = 0  // in the / suggestions
    @FocusState private var focused: Bool
    private var library: TaskLibrary { .shared }

    var body: some View {
        VStack(spacing: 0) {
            ModelBanner()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages) { m in
                            MessageRow(role: m.role, text: m.content)
                                .transition(
                                    m.role == "user"
                                        ? .opacity.combined(with: .move(edge: .bottom)) : .identity)
                        }
                        if let s = model.streaming {
                            MessageRow(role: "assistant", text: s, streaming: true)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                        GeometryReader { g in
                            ScrollView {
                                EmptyChat()
                                    .frame(maxWidth: .infinity, minHeight: g.size.height)
                            }
                        }
                        .background(.background)
                    }
                }
                .onChange(of: model.streaming) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer
        }
        .navigationTitle(model.current?.title ?? "Orchard")
        .onAppear {
            focused = true
            library.reload()
        }
        .onChange(of: model.selection) {
            draft = ""
            pendingTask = nil
            focused = true
        }
        .onChange(of: draft) { highlighted = 0 }
    }

    // MARK: Tasks

    /// `/` suggestions while the draft is just a partial command.
    var suggestions: [ChatTask] {
        guard pendingTask == nil, draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) else {
            return []
        }
        let q = draft.dropFirst().lowercased()
        return library.popular.filter {
            q.isEmpty || $0.name.hasPrefix(q) || $0.label.lowercased().contains(q)
        }
    }

    func pick(_ t: ChatTask) {
        pendingTask = t
        taskOption = ""
        if draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) { draft = "" }
        focused = true
    }

    @ViewBuilder var composerExtras: some View {
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { i, t in
                    Button {
                        pick(t)
                    } label: {
                        HStack {
                            Text("/\(t.name)").monospaced()
                            Text(t.label).foregroundStyle(.secondary)
                            Spacer()
                            if let o = t.option { Text(o.label).font(.caption).foregroundStyle(.tertiary) }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                        .background(
                            i == highlighted ? Color.accentColor.opacity(0.2) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
        if let t = pendingTask {
            HStack(spacing: 8) {
                Pill(icon: "sparkles", text: t.label) { pendingTask = nil }
                if let o = t.option {
                    if let choices = o.choices, !choices.isEmpty {
                        Picker(o.label, selection: $taskOption) {
                            Text(o.default).tag("")
                            ForEach(choices.filter { $0 != o.default }, id: \.self) { Text($0).tag($0) }
                        }
                        .fixedSize()
                    } else {
                        TextField(o.label, text: $taskOption, prompt: Text(o.default))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                }
                Spacer()
            }
            .font(.callout)
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            composerExtras
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, selection: $cursor, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($focused)
                    .onKeyPress(.downArrow) { moveHighlight(1) }
                    .onKeyPress(.upArrow) { moveHighlight(-1) }
                    .onKeyPress(.tab) { acceptSuggestion() }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers == .shift {
                            insertNewline()
                            return .handled
                        }
                        return press.modifiers.isEmpty ? acceptSuggestion() : .ignored
                    }
                    .onKeyPress(.delete) {
                        // Backspace in an empty draft drops the chosen task.
                        guard draft.isEmpty, pendingTask != nil else { return .ignored }
                        pendingTask = nil
                        return .handled
                    }
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
                    .foregroundStyle(
                        canSend ? Color.accentColor : Color.secondary
                    )
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Return) · new line (Shift-Return)")
                }
            }
            HStack(spacing: 8) {
                let used = model.tokens + (draft.isEmpty ? 0 : Assistant.estimate(draft) + 4)
                Gauge(value: Double(min(used, Assistant.budget)), in: 0...Double(Assistant.budget))
                {}
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

    var placeholder: String {
        pendingTask.map { "Text to \($0.label.lowercased())" } ?? "Message, or / for tasks"
    }

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func moveHighlight(_ d: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + d + suggestions.count) % suggestions.count
        return .handled
    }

    func acceptSuggestion() -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        pick(suggestions[min(highlighted, suggestions.count - 1)])
        return .handled
    }

    /// Shift-Return: a new line at the cursor (Return sends).
    func insertNewline() {
        guard case .selection(let r)? = cursor?.indices,
            r.lowerBound >= draft.startIndex, r.upperBound <= draft.endIndex
        else { return draft.append("\n") }
        let offset = draft.distance(from: draft.startIndex, to: r.lowerBound)
        draft.replaceSubrange(r, with: "\n")
        cursor = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: offset + 1))
    }

    func send() {
        guard !model.isStreaming, canSend else { return }
        var text = draft
        if let t = pendingTask {
            let opt = taskOption.trimmingCharacters(in: .whitespaces)
            text = "/\(t.name)\(opt.isEmpty ? "" : " " + opt)\n\(draft)"
        }
        model.send(text)
        draft = ""
        pendingTask = nil
    }
}

/// Apple Intelligence's mark in its rainbow colours; it turns and breathes
/// while a reply is being written.
struct AILogo: View {
    var active = false
    static let colors: [Color] = [.orange, .pink, .purple, .blue, .cyan, .orange]
    static let gradient = LinearGradient(
        colors: [.orange, .pink, .purple, .blue], startPoint: .leading, endPoint: .trailing)

    @ViewState private var angle = 0.0

    var body: some View {
        Image(systemName: "apple.intelligence")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(AngularGradient(colors: Self.colors, center: .center, angle: .degrees(angle)))
            .symbolEffect(.breathe, isActive: active)
            .frame(width: 22, height: 22)
            // Sit centred on the first line of text beside it (in a
            // .firstTextBaseline stack): the baseline is ~4.5pt below the
            // middle of a body-size line.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
            .help("Apple Intelligence")
            .onAppear { spin(active) }
            .onChange(of: active) { spin(active) }
    }

    private func spin(_ on: Bool) {
        if on {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { angle = 360 }
        } else {
            withAnimation(.easeOut(duration: 0.4)) { angle = 0 }
        }
    }
}

/// A reply as it's written: "Thinking…" until the first words, then text that
/// grows smoothly with a rainbow dot at the end until it's done.
struct ReplyText: View {
    var text: AttributedString
    var streaming = false

    var body: some View {
        if streaming && text.characters.isEmpty {
            ThinkingText()
        } else {
            (Text(text) + Text(streaming ? " ●" : "").foregroundStyle(AILogo.gradient))
                .lineSpacing(2)
                .animation(.smooth(duration: 0.25), value: text)
        }
    }
}

/// "Thinking…" with a light sweeping across it, shown until the first words arrive.
struct ThinkingText: View {
    @ViewState private var phase: CGFloat = -1

    var body: some View {
        Text("Thinking…")
            .foregroundStyle(.secondary)
            .overlay {
                LinearGradient(
                    colors: [.clear, .white.opacity(0.9), .clear],
                    startPoint: UnitPoint(x: phase, y: 0.5), endPoint: UnitPoint(x: phase + 0.6, y: 0.5)
                )
                .mask(Text("Thinking…"))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
    }
}

/// A removable capsule in the composer showing the chosen task.
struct Pill: View {
    var icon: String
    var text: String
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 9)
        .background(Color.accentColor.opacity(0.18), in: Capsule())
    }
}

struct MessageRow: View {
    let role: String
    let text: String
    var streaming = false
    @ViewState private var hovering = false
    @ViewState private var expanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if role == "user" { Spacer(minLength: 60) }
            if role == "assistant" { AILogo(active: streaming) }
            Group {
                if role == "user" {
                    userBubble
                } else {
                    ReplyText(text: markdown(text), streaming: streaming)
                }
            }
            .textSelection(.enabled)
            .contextMenu { Button("Copy") { copy() } }
            if role == "assistant" {
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy")
                    .opacity(hovering && !streaming ? 1 : 0)
                Spacer(minLength: 60)
            }
        }
        .onHover { hovering = $0 }
    }

    /// A user message: a `/task` first line shows as a label, and long
    /// pasted text is collapsed.
    var userBubble: some View {
        var body = text
        var label: String?
        if text.hasPrefix("/") {
            let first = text.prefix { !$0.isNewline }
            let words = first.dropFirst().split(separator: " ", maxSplits: 1)
            if let name = words.first, let t = TaskLibrary.shared.task(String(name)) {
                label = t.label + (words.count > 1 ? " · \(words[1])" : "")
                body = text.dropFirst(first.count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let long = body.count > 600 || body.filter(\.isNewline).count > 12
        return VStack(alignment: .leading, spacing: 6) {
            if let label {
                Label(label, systemImage: "sparkles").font(.caption.weight(.semibold)).opacity(0.85)
            }
            Text(body).lineLimit(long && !expanded ? 8 : nil)
            if long {
                Button(expanded ? "Show less" : "Show all \(body.count.formatted()) characters") {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .opacity(0.85)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
