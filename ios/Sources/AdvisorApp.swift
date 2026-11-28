import SwiftUI
import UIKit

@main
struct AdvisorApp: App {
    @StateObject private var model = AdvisorModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            AdvisorRoot(model: model)
                .tint(AdvisorTheme.accentInk)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.sync() } }
        }
    }
}

private extension View {
    /// 弹窗打开时，根视图上的提示框不会显示；每个弹窗也要挂一份，才能看到保存失败等错误。
    func advisorErrorAlert(_ model: AdvisorModel) -> some View {
        alert("请求未完成", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("好", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

private struct AdvisorRoot: View {
    @ObservedObject var model: AdvisorModel

    var body: some View {
        Group {
            if model.connected {
                TabView {
                    NavigationStack { AdvisorChat(model: model) }
                        .tabItem { Label("对话", systemImage: "bubble.left.and.bubble.right") }
                    NavigationStack { AdvisorMemories(model: model) }
                        .tabItem { Label("记忆", systemImage: "book.closed") }
                    NavigationStack { AdvisorSettings(model: model) }
                        .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                        .badge(model.failedItems.count)
                }
            } else {
                AdvisorLogin(model: model)
            }
        }
        .task { await model.sync() }
        .sheet(isPresented: Binding(
            get: { model.memoryFile != nil }, set: { if !$0 { model.memoryFile = nil } }
        )) {
            if let file = model.memoryFile { MemoryDetail(model: model, file: file) }
        }
        .advisorErrorAlert(model)
        .alert("成长顾问", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }
        )) {
            Button("好", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }
}

private struct AdvisorLogin: View {
    @ObservedObject var model: AdvisorModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("HTTPS 地址", text: $model.server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("访问密码", text: $model.password)
                    Button("验证并连接") { Task { await model.connect() } }
                    if model.busy { ProgressView() }
                } header: {
                    Text("连接你的 VPS")
                } footer: {
                    if model.pendingCount > 0 {
                        Text("手机上还有 \(model.pendingCount) 条内容等待上传，重新连接后会继续上传。")
                    }
                }
                .disabled(model.busy)
            }
            .navigationTitle("成长顾问")
        }
    }
}

// MARK: - 对话

private let userBubbleShape = UnevenRoundedRectangle(
    topLeadingRadius: 20,
    bottomLeadingRadius: 20,
    bottomTrailingRadius: 6,
    topTrailingRadius: 20,
    style: .continuous
)

private struct MessageRow: View {
    @ObservedObject var model: AdvisorModel
    let message: StoredMessage
    let onReuseDraft: (String) -> Void

    @State private var showReasoning = false
    @State private var copied = false

    private var outgoing: Bool { message.role == "user" }

    var body: some View {
        if outgoing {
            userMessageRow
        } else {
            assistantMessageRow
        }
    }

    private var userMessageRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 5) {
                Text(verbatim: message.content)
                    .font(.body)
                    .lineSpacing(3)
                    .foregroundStyle(AdvisorTheme.outgoingInk)
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(
                        AdvisorTheme.outgoingBubble.opacity(message.state == .sent ? 1 : 0.65),
                        in: userBubbleShape
                    )
                    .overlay(
                        userBubbleShape
                            .strokeBorder(AdvisorTheme.accentBorder.opacity(0.45), lineWidth: 0.6)
                    )
                    .contextMenu {
                        Button("复制", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.content
                        }
                        Button("填入输入框重新编辑", systemImage: "arrow.uturn.backward") {
                            onReuseDraft(message.content)
                        }
                    }

                userMessageStatus
            }
        }
    }

    @ViewBuilder
    private var userMessageStatus: some View {
        switch message.state {
        case .pending:
            if !model.online {
                Label("离线已暂存 · 联网自动发送", systemImage: "icloud.and.arrow.up")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.syncing {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("发送中…")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    Label(model.lastSyncFailure ?? "暂未送达，点击重试", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(AdvisorTheme.warning)
                        .multilineTextAlignment(.trailing)
                    if let item = model.outboxItem(for: message) {
                        HStack(spacing: 8) {
                            Button("删除", role: .destructive) { model.discard(item) }
                            Button("重试") { Task { await model.retry(item) } }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                }
            }
        case .failed:
            VStack(alignment: .trailing, spacing: 5) {
                Label(message.failure ?? "发送失败", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AdvisorTheme.coral)
                    .multilineTextAlignment(.trailing)
                if let item = model.outboxItem(for: message) {
                    HStack(spacing: 8) {
                        Button("删除", role: .destructive) { model.discard(item) }
                        Button("重试") { Task { await model.retry(item) } }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        case .sent, .streaming:
            EmptyView()
        }
    }

    private var assistantMessageRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：品牌标 + 模型信息 + 复制按钮
            HStack(spacing: 8) {
                AdvisorMark(size: 24)
                Text("成长顾问")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AdvisorTheme.ink)

                if let modelTag = assistantModelTag {
                    Text(modelTag)
                        .font(.caption2)
                        .foregroundStyle(AdvisorTheme.tertiaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                if !message.content.isEmpty && message.state != .streaming {
                    Button {
                        UIPasteboard.general.string = message.content
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.4))
                            copied = false
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            if copied { Text("已复制") }
                        }
                        .font(.caption)
                        .foregroundStyle(copied ? AdvisorTheme.accentInk : AdvisorTheme.tertiaryInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            copied ? AdvisorTheme.accentSoft : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制回复")
                }
            }

            // 可折叠思考链（推理模型流式输出时立即显示进展）
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                reasoningCard(reasoning)
            }

            // 正文内容 / 思考中占位
            if message.state == .streaming && message.content.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text((message.reasoning?.isEmpty == false) ? "正在组织回复…" : "正在结合你的记忆思考…")
                        .font(.subheadline)
                        .foregroundStyle(AdvisorTheme.secondaryInk)
                }
                .padding(.vertical, 2)
            } else if !message.content.isEmpty {
                MarkdownMessageView(text: message.content)
                    .contextMenu {
                        Button("复制全文", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = message.content
                        }
                    }
            }

            // 本轮引用的记忆胶囊（点开直达原文）
            if let refs = message.references, !refs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(refs) { ref in
                            Button {
                                Task { await model.openMemory(ref.path) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "book.closed")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(AdvisorTheme.accentInk)
                                    Text(ref.title)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(AdvisorTheme.ink)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(AdvisorTheme.cardSurface, in: Capsule())
                                .overlay(Capsule().strokeBorder(AdvisorTheme.subtleBorder, lineWidth: 0.6))
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.online || model.busy)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantModelTag: String? {
        let parts = [message.providerName, message.modelName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func reasoningCard(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showReasoning.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showReasoning ? 90 : 0))
                        .foregroundStyle(AdvisorTheme.tertiaryInk)
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AdvisorTheme.accentInk)
                    Text(message.state == .streaming && message.content.isEmpty ? "正在思考" : "思考过程")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AdvisorTheme.secondaryInk)
                    Spacer()
                    Text("\(reasoning.count) 字")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AdvisorTheme.tertiaryInk)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showReasoning {
                Text(verbatim: reasoning)
                    .font(.footnote)
                    .lineSpacing(4)
                    .foregroundStyle(AdvisorTheme.secondaryInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(AdvisorTheme.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AdvisorTheme.subtleBorder, lineWidth: 0.6)
        )
    }
}

// MARK: - 结构化 Markdown 渲染（支持标题、列表、引用、代码块与行内格式）

private struct MarkdownMessageView: View {
    let text: String

    private enum Block: Identifiable {
        case heading(level: Int, text: String, id: Int)
        case paragraph(text: String, id: Int)
        case bullet(text: String, id: Int)
        case numbered(prefix: String, text: String, id: Int)
        case quote(text: String, id: Int)
        case code(language: String, code: String, id: Int)
        case divider(id: Int)

        var id: Int {
            switch self {
            case .heading(_, _, let id), .paragraph(_, let id), .bullet(_, let id),
                 .numbered(_, _, let id), .quote(_, let id), .code(_, _, let id), .divider(let id):
                return id
            }
        }
    }

    private var blocks: [Block] {
        Self.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let level, let content, _):
                    inlineText(content)
                        .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                        .foregroundStyle(AdvisorTheme.ink)
                        .padding(.top, level <= 2 ? 6 : 3)
                case .paragraph(let content, _):
                    inlineText(content)
                        .font(.body)
                        .lineSpacing(4)
                        .foregroundStyle(AdvisorTheme.ink)
                case .bullet(let content, _):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(AdvisorTheme.accentInk)
                        inlineText(content)
                            .font(.body)
                            .lineSpacing(4)
                            .foregroundStyle(AdvisorTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .numbered(let prefix, let content, _):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(prefix)
                            .font(.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(AdvisorTheme.accentInk)
                        inlineText(content)
                            .font(.body)
                            .lineSpacing(4)
                            .foregroundStyle(AdvisorTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .quote(let content, _):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(AdvisorTheme.accent.opacity(0.6))
                            .frame(width: 3)
                        inlineText(content)
                            .font(.callout)
                            .lineSpacing(4)
                            .foregroundStyle(AdvisorTheme.secondaryInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
                case .code(let language, let code, _):
                    VStack(alignment: .leading, spacing: 6) {
                        if !language.isEmpty {
                            Text(language)
                                .font(.caption2.monospaced())
                                .foregroundStyle(AdvisorTheme.tertiaryInk)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(verbatim: code)
                                .font(.footnote.monospaced())
                                .foregroundStyle(AdvisorTheme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AdvisorTheme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(AdvisorTheme.subtleBorder, lineWidth: 0.6)
                    )
                case .divider:
                    Divider().padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineText(_ raw: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: raw, options: options) {
            return Text(attributed)
        }
        return Text(verbatim: raw)
    }

    private static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [Block] = []
        var nextID = 0
        var paragraphBuffer: [String] = []
        var inCode = false
        var codeLang = ""
        var codeBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            result.append(.paragraph(text: paragraphBuffer.joined(separator: "\n"), id: nextID))
            nextID += 1
            paragraphBuffer.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    result.append(.code(language: codeLang, code: codeBuffer.joined(separator: "\n"), id: nextID))
                    nextID += 1
                    codeBuffer.removeAll()
                    codeLang = ""
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCode {
                codeBuffer.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                result.append(.divider(id: nextID))
                nextID += 1
                continue
            }

            if trimmed.hasPrefix("### ") {
                flushParagraph()
                result.append(.heading(level: 3, text: String(trimmed.dropFirst(4)), id: nextID))
                nextID += 1
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushParagraph()
                result.append(.heading(level: 2, text: String(trimmed.dropFirst(3)), id: nextID))
                nextID += 1
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushParagraph()
                result.append(.heading(level: 1, text: String(trimmed.dropFirst(2)), id: nextID))
                nextID += 1
                continue
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                result.append(.quote(text: String(trimmed.dropFirst(2)), id: nextID))
                nextID += 1
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                result.append(.bullet(text: String(trimmed.dropFirst(2)), id: nextID))
                nextID += 1
                continue
            }

            if let dotIndex = trimmed.firstIndex(of: "."),
               dotIndex > trimmed.startIndex,
               trimmed[trimmed.startIndex..<dotIndex].allSatisfy(\.isNumber) {
                let afterDot = trimmed.index(after: dotIndex)
                if afterDot < trimmed.endIndex && trimmed[afterDot] == " " {
                    flushParagraph()
                    let prefix = String(trimmed[trimmed.startIndex...dotIndex])
                    let body = String(trimmed[trimmed.index(after: afterDot)...])
                    result.append(.numbered(prefix: prefix, text: body, id: nextID))
                    nextID += 1
                    continue
                }
            }

            paragraphBuffer.append(line)
        }

        if inCode {
            result.append(.code(language: codeLang, code: codeBuffer.joined(separator: "\n"), id: nextID))
        } else {
            flushParagraph()
        }

        return result
    }
}

// MARK: - 空对话欢迎页与快捷引导

private struct ChatWelcomeView: View {
    let mode: ChatMode
    let online: Bool
    let onSelectStarter: (ChatMode, String) -> Void

    private struct Starter: Identifiable {
        let id = UUID()
        let mode: ChatMode
        let icon: String
        let title: String
        let subtitle: String
        let prompt: String
    }

    private let starters: [Starter] = [
        Starter(
            mode: .decision,
            icon: "safari",
            title: "9 步反讨好决策分析",
            subtitle: "剥离外界期待，拆解选项与真实权衡",
            prompt: "我最近面临一个重要选择，想请你按 9 步反讨好决策流程帮我分析："
        ),
        Starter(
            mode: .chat,
            icon: "bubble.left",
            title: "聊聊今天的经历与感受",
            subtitle: "自由倾诉当下情绪，结合过往记忆陪伴",
            prompt: "今天发生了一件让我感触很深的事，想先和你聊聊当时的感受："
        ),
        Starter(
            mode: .interview,
            icon: "mic",
            title: "开始冷启动访谈",
            subtitle: "用 1–2 个轻松问题建立核心自我档案",
            prompt: "我想开始一次冷启动访谈，请先用 1–2 个轻松具体的问题帮我梳理「核心自我」和早期重要经历。"
        ),
        Starter(
            mode: .reflect,
            icon: "sparkles",
            title: "整理收件箱与阶段反思",
            subtitle: "回看近期速记，找出情绪模式与洞见",
            prompt: "请帮我结合 99-收件箱/inbox.md 和近期记忆做一次阶段反思，看看有哪些情绪模式和值得归档的内容。"
        ),
    ]

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                AdvisorMark(size: 64)
                    .shadow(color: AdvisorTheme.accent.opacity(0.16), radius: 12, y: 6)

                VStack(spacing: 6) {
                    Text(mode.heroTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AdvisorTheme.ink)
                        .multilineTextAlignment(.center)

                    Text(online ? "基于你的长期记忆库，陪你克制、清醒地思考" : "当前离线 · 写下的内容会先存手机，联网自动发送")
                        .font(.footnote)
                        .foregroundStyle(AdvisorTheme.secondaryInk)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.top, 28)

            VStack(spacing: 10) {
                ForEach(starters) { item in
                    Button {
                        onSelectStarter(item.mode, item.prompt)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.icon)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(AdvisorTheme.accentInk)
                                .frame(width: 34, height: 34)
                                .background(AdvisorTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(AdvisorTheme.ink)
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(AdvisorTheme.secondaryInk)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AdvisorTheme.tertiaryInk)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AdvisorTheme.cardSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(AdvisorTheme.subtleBorder, lineWidth: 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }
}

private struct AdvisorChat: View {
    @ObservedObject var model: AdvisorModel
    @State private var composerFocused = false
    @State private var showHistory = false
    @State private var isAtBottom = true
    @State private var lastAutoScrollTime: Date = .distantPast

    private var streamActivitySignature: Int {
        guard let last = model.messages.last else { return 0 }
        return last.content.count + (last.reasoning?.count ?? 0)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if model.messages.isEmpty {
                        ChatWelcomeView(mode: model.mode, online: model.online) { selectedMode, prompt in
                            model.changeMode(selectedMode)
                            model.draft = prompt
                            composerFocused = true
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            composerFocused = false
                        }
                    } else {
                        ForEach(model.messages) { message in
                            MessageRow(model: model, message: message) { content in
                                model.draft = content
                                composerFocused = true
                            }
                            .id(message.id)
                        }
                    }

                    Color.clear
                        .frame(height: 12)
                        .id("latest")
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .frame(maxWidth: AdvisorTheme.contentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .softBottomScrollEdge()
            .onChange(of: model.messages.count) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
            .onChange(of: streamActivitySignature) { _, _ in
                guard isAtBottom else { return }
                let now = Date()
                if now.timeIntervalSince(lastAutoScrollTime) >= 0.12 {
                    lastAutoScrollTime = now
                    proxy.scrollTo("latest", anchor: .bottom)
                }
            }
            .onChange(of: model.activeID) { _, _ in
                isAtBottom = true
                scrollToBottom(proxy, animated: false)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !model.online {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                        Text("离线中 · 写下的内容会先存手机")
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AdvisorTheme.secondaryInk)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 6) {
                    if !isAtBottom && !model.messages.isEmpty {
                        HStack {
                            Spacer()
                            Button {
                                scrollToBottom(proxy, animated: true)
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AdvisorTheme.ink)
                                    .frame(width: 34, height: 34)
                                    .floatingGlassCircle()
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 16)
                            .accessibilityLabel("回到底部")
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }

                    AdvisorComposer(model: model, isFocused: $composerFocused) { focused in
                        if focused && !model.messages.isEmpty {
                            Task {
                                try? await Task.sleep(for: .milliseconds(220))
                                scrollToBottom(proxy, animated: true)
                            }
                        }
                    }
                }
                .animation(.snappy(duration: 0.2), value: isAtBottom)
            }
        }
        .background(AdvisorTheme.paper.ignoresSafeArea())
        .navigationTitle(model.active?.title ?? "顾问对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("历史会话", systemImage: "clock") {
                    composerFocused = false
                    showHistory = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("新对话", systemImage: "square.and.pencil") {
                    composerFocused = false
                    model.newConversation()
                }
                .disabled(model.isReplying)
            }
        }
        .sheet(isPresented: $showHistory) { AdvisorHistory(model: model) }
        .sheet(isPresented: Binding(
            get: { !model.proposals.isEmpty }, set: { if !$0 && !model.busy { model.proposals = [] } }
        )) {
            AdvisorProposals(model: model)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo("latest", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("latest", anchor: .bottom)
        }
    }
}

private struct AdvisorHistory: View {
    @ObservedObject var model: AdvisorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.conversations) { conversation in
                    Button {
                        Task { await model.open(conversation) }
                        dismiss()
                    } label: {
                        HStack {
                            Text(conversation.title).foregroundStyle(.primary).lineLimit(2)
                            Spacer()
                            if conversation.isLocal {
                                Image(systemName: "icloud.and.arrow.up")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("等待上传")
                            }
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { Task { await model.delete(conversation) } }
                    }
                }
            }
            .overlay {
                if model.conversations.isEmpty {
                    ContentUnavailableView("还没有会话", systemImage: "clock")
                }
            }
            .refreshable { await model.sync() }
            .navigationTitle("历史会话")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

private struct AdvisorProposals: View {
    @ObservedObject var model: AdvisorModel
    @State private var selected = Set<String>()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(model.proposals) { proposal in
                Section {
                    Toggle(proposal.title, isOn: Binding(
                        get: { selected.contains(proposal.id) },
                        set: { if $0 { selected.insert(proposal.id) } else { selected.remove(proposal.id) } }
                    ))
                    Text(proposal.summary)
                    if !proposal.evidence.isEmpty {
                        LabeledContent("提案依据", value: proposal.evidence)
                    }
                    DisclosureGroup("查看要写入的内容") {
                        Text(proposal.diff.isEmpty ? proposal.content : proposal.diff)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(proposal.level == 3 ? "核心记忆变更" : proposal.path)
                }
            }
            .navigationTitle("确认记忆提案")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(model.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("写入") { Task { await model.saveProposals(selected) } }
                        .disabled(model.busy || selected.isEmpty)
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }
}

// MARK: - 记忆

private struct AdvisorMemories: View {
    @ObservedObject var model: AdvisorModel
    @State private var query = ""
    @State private var showNote = false
    @State private var showNew = false

    var body: some View {
        List(model.memories) { memory in
            Button {
                Task { await model.openMemory(memory.path) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(memory.categoryLabel).font(.caption).foregroundStyle(.secondary)
                    Text(memory.title).font(.headline).foregroundStyle(.primary)
                    Text(memory.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .disabled(model.busy)
        }
        .overlay {
            if model.memories.isEmpty {
                ContentUnavailableView(query.isEmpty ? "记忆库是空的" : "没有找到", systemImage: "book.closed")
            }
        }
        .navigationTitle("记忆库")
        .searchable(text: $query, prompt: "搜索记忆")
        .onSubmit(of: .search) { Task { await model.findMemories(query) } }
        .onChange(of: query) { _, value in if value.isEmpty { Task { await model.findMemories("") } } }
        .task { await model.findMemories(query) }
        .refreshable { await model.findMemories(query) }
        .toolbar {
            Menu("记录", systemImage: "plus") {
                Button("收件箱速记", systemImage: "tray.and.arrow.down") { showNote = true }
                Button("新建一条记忆", systemImage: "square.and.pencil") { showNew = true }
            }
        }
        .sheet(isPresented: $showNote) { NoteEditor(model: model) }
        .sheet(isPresented: $showNew) { MemoryEditor(model: model) }
    }
}

private struct NoteEditor: View {
    @ObservedObject var model: AdvisorModel
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TextEditor(text: $note)
                .padding()
                .accessibilityLabel("速记内容")
                .navigationTitle("收件箱速记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            guard model.saveNote(note) else { return }
                            dismiss()
                            Task { await model.sync() }
                        }
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .advisorErrorAlert(model)
    }
}

private struct MemoryEditor: View {
    @ObservedObject var model: AdvisorModel
    @State private var kind = MemoryKind.experience
    @State private var title = ""
    @State private var text = ""
    @State private var importance = 5
    @State private var privacy = "private"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类别", selection: $kind) {
                        ForEach(MemoryKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField(kind == .relation ? "人物称呼" : "标题", text: $title)
                }
                Section("内容") {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .accessibilityLabel("记忆内容")
                }
                Section {
                    Stepper("重要程度 \(importance)/10", value: $importance, in: 1...10)
                    Picker("隐私", selection: $privacy) {
                        Text("普通").tag("normal")
                        Text("私密").tag("private")
                        Text("敏感（不进入对话）").tag("sensitive")
                    }
                } footer: {
                    Text("保存到 \(kind.path(title: title.isEmpty ? "标题" : title, day: "今天"))")
                }
            }
            .navigationTitle("新建记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard model.createMemory(
                            kind: kind, title: title, body: text,
                            importance: importance, privacy: privacy
                        ) else { return }
                        dismiss()
                        Task { await model.sync() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .advisorErrorAlert(model)
    }
}

private struct MemoryDetail: View {
    @ObservedObject var model: AdvisorModel
    let file: AdvisorAPI.MemoryFile
    @State private var editing = false
    @State private var raw = ""

    var body: some View {
        NavigationStack {
            Group {
                if editing {
                    TextEditor(text: $raw)
                        .font(.footnote.monospaced())
                        .padding(.horizontal)
                        .accessibilityLabel("Markdown 原文")
                } else {
                    ScrollView {
                        MarkdownMessageView(text: file.body)
                            .padding()
                    }
                }
            }
            .navigationTitle(file.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editing ? "取消" : "关闭") {
                        if editing { editing = false } else { model.memoryFile = nil }
                    }
                    .disabled(model.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if editing {
                        Button("保存") {
                            Task {
                                await model.saveMemoryEdit(path: file.path, raw: raw)
                                if model.error == nil { editing = false }
                            }
                        }
                        .disabled(model.busy || raw == file.raw)
                    } else {
                        Button("编辑") {
                            raw = file.raw
                            editing = true
                        }
                        .disabled(!model.online)
                    }
                }
            }
            .interactiveDismissDisabled(editing)
        }
        .advisorErrorAlert(model)
    }
}

// MARK: - 同步

private struct AdvisorSettings: View {
    @ObservedObject var model: AdvisorModel
    @State private var confirmDisconnect = false

    var body: some View {
        Form {
            Section("状态") {
                LabeledContent("网络", value: model.online ? "在线" : "离线")
                LabeledContent("等待上传", value: "\(model.pendingCount) 条")
                if let last = model.lastSync {
                    LabeledContent("上次同步", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                Button {
                    Task { await model.sync() }
                } label: {
                    HStack {
                        Text("立即同步")
                        if model.syncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.syncing || !model.online)
            }
            if !model.failedItems.isEmpty {
                Section {
                    ForEach(model.failedItems) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.summary)
                            Text(item.failure ?? "").font(.caption).foregroundStyle(AdvisorTheme.coral)
                            HStack {
                                Button("放弃", role: .destructive) { model.discard(item) }
                                Button("重试") { Task { await model.retry(item) } }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("上传失败")
                } footer: {
                    Text("这些内容被服务器拒绝了，需要你决定重试还是放弃。")
                }
            }
            Section {
                LabeledContent("服务器", value: model.server)
                Button("断开并清除本机数据", role: .destructive) { confirmDisconnect = true }
                    .disabled(model.busy)
            } footer: {
                Text("聊天、速记和新建的记忆都保存在 VPS 上；手机只保留一份缓存和未上传的内容。")
            }
        }
        .navigationTitle("同步")
        .confirmationDialog("断开连接？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("断开并清除", role: .destructive, action: model.disconnect)
        } message: {
            Text(model.pendingCount > 0
                 ? "还有 \(model.pendingCount) 条内容没上传，断开后会一起删除。"
                 : "VPS 上的数据不受影响。")
        }
    }
}
