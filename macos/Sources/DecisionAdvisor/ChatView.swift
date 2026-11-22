import AppKit
import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var state
    @FocusState private var isComposerFocused: Bool
    @State private var showOptionsPopover = false

    private var activeProvider: ProviderPresetDTO? {
        guard let providers = state.config?.providers else { return nil }
        return providers.first(where: { $0.id == state.selectedProviderId }) ?? providers.first
    }

    private var hasActiveContextFilters: Bool {
        state.useAsOfDate || state.allowSensitive
    }

    private var formattedAsOfShort: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: state.asOfDate)
    }

    private var composerEditorHeight: CGFloat {
        let text = state.chatInput
        if text.isEmpty { return 52 }
        let paragraphs = text.components(separatedBy: "\n")
        let estimatedLines = paragraphs.reduce(0) { acc, line in
            acc + max(1, Int(ceil(Double(max(1, line.count)) / 42.0)))
        }
        return min(144, max(52, CGFloat(estimatedLines) * 22 + 20))
    }

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            // MARK: Unified Seamless Header Bar
            ZStack {
                WindowDragHandle()

                HStack(spacing: 12) {
                    if !state.isSidebarVisible {
                        HStack(spacing: 4) {
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                    state.isSidebarVisible = true
                                }
                            } label: {
                                Image(systemName: "sidebar.left")
                                    .font(.system(size: 13.5))
                            }
                            .buttonStyle(GhostIconButtonStyle(size: 28))
                            .help("显示侧边栏 (⌘\\)")

                            Button {
                                state.startNewChat()
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 13))
                            }
                            .buttonStyle(GhostIconButtonStyle(size: 28))
                            .help("新建对话 (⌘N)")
                        }
                        .padding(.leading, Theme.trafficLightClearance - 8)
                    }

                    UnifiedSegmentedControl(
                        options: ChatMode.allCases,
                        selection: $state.chatMode,
                        label: { $0.label }
                    )

                    Spacer(minLength: 12)

                    // Model Selector Capsule Menu
                    if let providers = state.config?.providers, !providers.isEmpty {
                        Menu {
                            ForEach(providers) { p in
                                Button {
                                    state.selectedProviderId = p.id
                                } label: {
                                    HStack {
                                        let missingTag = p.kind == "chatgpt_oauth" ? " (未授权)" : " (未填Key)"
                                        Text("\(p.name) · \(p.model)\(p.hasApiKey == true ? "" : missingTag)")
                                        if p.id == state.selectedProviderId {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                            Divider()
                            if state.config?.chatgptOauth?.connected != true {
                                Button("使用 ChatGPT 账号授权登录…") {
                                    state.selectSection(.settings)
                                    Task {
                                        await state.startChatGPTLogin(forceRegister: false, openBrowser: true)
                                    }
                                }
                            }
                            Button("配置模型与授权…") {
                                state.selectSection(.settings)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(activeProvider?.hasApiKey == true ? Theme.success : Theme.warning)
                                    .frame(width: 6.5, height: 6.5)
                                Text(activeProvider.map { "\($0.name) · \($0.model)" } ?? "选择模型")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5.5)
                            .background(Theme.cardBg, in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Theme.borderSubtle, lineWidth: 0.9)
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    // Context Options Popover Button
                    Button {
                        showOptionsPopover.toggle()
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 13.5))
                            if hasActiveContextFilters {
                                Circle()
                                    .fill(state.allowSensitive ? Theme.warning : Theme.accent)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 4, y: -3)
                            }
                        }
                    }
                    .buttonStyle(GhostIconButtonStyle(size: 30, isActive: hasActiveContextFilters || showOptionsPopover))
                    .help("记忆检索选项（历史回溯 / 敏感记忆）")
                    .popover(isPresented: $showOptionsPopover, arrowEdge: .bottom) {
                        ChatContextOptionsPopover()
                            .environment(state)
                    }
                }
                .padding(.horizontal, 18)
            }
            .frame(height: Theme.headerHeight)

            Rectangle()
                .fill(Theme.borderSubtle.opacity(0.7))
                .frame(height: 1)

            // MARK: Main Message Canvas (Full Fluid Height)
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        if state.messages.isEmpty {
                            WelcomeHeroView(onSelectStarter: { mode, prompt in
                                state.chatMode = mode
                                state.chatInput = prompt
                                isComposerFocused = true
                            })
                            .frame(maxWidth: .infinity, minHeight: max(360, geo.size.height - 20))
                            .padding(.horizontal, 28)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                ForEach(state.messages) { msg in
                                    MessageRowView(message: msg)
                                        .id(msg.id)
                                }
                                Color.clear.frame(height: 8).id("chat-bottom-anchor")
                            }
                            .frame(maxWidth: 760)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 28)
                            .padding(.top, 24)
                            .padding(.bottom, 16)
                        }
                    }
                    .onChange(of: state.messages.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
                        }
                    }
                    .onChange(of: state.messages.last?.content) { _, _ in
                        proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: Floating Unified Composer
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if state.chatInput.isEmpty {
                            Text(state.chatMode.placeholder)
                                .font(.system(size: 14.5))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .allowsHitTesting(false)
                        }

                        TextEditor(text: $state.chatInput)
                            .font(.system(size: 14.5))
                            .foregroundStyle(Theme.textPrimary)
                            .lineSpacing(4)
                            .scrollContentBackground(.hidden)
                            .focused($isComposerFocused)
                            .frame(height: composerEditorHeight)
                            .padding(.horizontal, 11)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                            .animation(.easeOut(duration: 0.12), value: composerEditorHeight)
                    }

                    // Integrated Internal Action Bar
                    HStack(spacing: 8) {
                        Button {
                            Task { await state.extractProposals() }
                        } label: {
                            HStack(spacing: 5) {
                                if state.isExtractingProposals {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("提炼中…")
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 11.5))
                                    Text("提炼记忆")
                                }
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(
                                state.messages.isEmpty || state.isStreaming
                                ? Theme.textTertiary
                                : Theme.textSecondary
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.surfaceSubtle.opacity(0.85), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(state.messages.isEmpty || state.isExtractingProposals || state.isStreaming)
                        .help("从当前对话提炼记忆提案（半自动确认写入 iCloud）")

                        if state.useAsOfDate {
                            ContextFilterChip(
                                icon: "calendar",
                                text: "回溯 \(formattedAsOfShort)",
                                tint: Theme.accent,
                                bg: Theme.accentSoft
                            ) {
                                state.useAsOfDate = false
                            }
                        }

                        if state.allowSensitive {
                            ContextFilterChip(
                                icon: "lock.open",
                                text: "含敏感",
                                tint: Theme.warning,
                                bg: Theme.warningSoft
                            ) {
                                state.allowSensitive = false
                            }
                        }

                        Spacer()

                        Text("⌘↩")
                            .font(.system(size: 11, weight: .medium).monospaced())
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.trailing, 2)

                        let canSend = !state.isStreaming && !state.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button {
                            Task { await state.sendChat() }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(canSend ? Theme.accent : Theme.surfaceSubtle)
                                    .frame(width: 32, height: 32)
                                if state.isStreaming {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(canSend ? Color.white : Theme.textTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!canSend)
                        .help("发送消息 (⌘↩)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                }
                .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isComposerFocused ? Theme.accentBorder : Theme.borderSubtle,
                            lineWidth: isComposerFocused ? 1.2 : 0.9
                        )
                )
                .shadow(color: .black.opacity(0.055), radius: 14, y: 4)
                .frame(maxWidth: 760)
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasBg)
    }
}

// MARK: - Context Options Popover

private struct ChatContextOptionsPopover: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 14) {
            Text("检索上下文选项")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $state.useAsOfDate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("按历史日期回溯")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("仅检索该日期之前的记忆，还原当时视角")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if state.useAsOfDate {
                    DatePicker("截止日期", selection: $state.asOfDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                }
            }

            Divider()

            Toggle(isOn: $state.allowSensitive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("本轮允许敏感记忆")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("默认拦截 privacy: sensitive 记忆，勾选仅本轮放行")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 300)
    }
}

private struct ContextFilterChip: View {
    let icon: String
    let text: String
    let tint: Color
    let bg: Color
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .padding(.leading, 1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(bg, in: Capsule())
    }
}

// MARK: - Centered Atmospheric Welcome Hero

private struct WelcomeHeroView: View {
    @Environment(AppState.self) private var state
    let onSelectStarter: (ChatMode, String) -> Void

    private struct StarterItem: Identifiable {
        let id = UUID()
        let mode: ChatMode
        let icon: String
        let title: String
        let subtitle: String
        let prompt: String
    }

    private let starters: [StarterItem] = [
        StarterItem(
            mode: .interview,
            icon: "mic",
            title: "开始冷启动访谈",
            subtitle: "用 1–2 个轻松问题建立核心自我与早期重要经历",
            prompt: "我想开始第一次冷启动访谈，请先用1-2个轻松的问题帮我建立「核心自我」和最早的重要经历。"
        ),
        StarterItem(
            mode: .decision,
            icon: "safari",
            title: "9 步反讨好决策分析",
            subtitle: "剥离外界期待，按结构化框架厘清真实权衡",
            prompt: "我最近面临一个重要选择，想请你按 9 步反讨好决策流程帮我分析："
        ),
        StarterItem(
            mode: .chat,
            icon: "bubble.left",
            title: "聊聊今天的经历与感受",
            subtitle: "自由倾诉当下情绪，结合过往记忆温和陪伴",
            prompt: "今天发生了一件让我感触很深的事，想先和你聊聊当时的感受："
        ),
        StarterItem(
            mode: .reflect,
            icon: "sparkles",
            title: "整理收件箱与周期反思",
            subtitle: "回看近期速记，梳理情绪模式与可归档洞见",
            prompt: "请帮我读取 99-收件箱/inbox.md 和近期记忆，做一次阶段反思，看看有哪些情绪模式和值得整理入库的内容。"
        )
    ]

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 14) {
                CompassEmblem(size: 52)

                VStack(spacing: 7) {
                    Text(state.chatMode.heroTitle)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    if let stats = state.health?.stats {
                        let modeDesc = state.backendMode == .remoteVPS
                            ? "已连接 VPS 远程记忆库（桌面与手机端互通）"
                            : "已连接 App 内置本地记忆库"
                        Text("\(modeDesc) · \(stats.total) 篇记忆随时参与思考")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                    } else if !state.isOnline {
                        Text(
                            state.backendMode == .remoteVPS
                                ? "正在连接远程 VPS 后端（\(state.activeBaseURL)）…"
                                : "正在启动 App 内置后端引擎…"
                        )
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.warning)
                    } else {
                        Text("基于你的长期记忆库，提供克制、清醒、连贯的个人决策陪伴")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(starters) { item in
                    StarterCard(
                        icon: item.icon,
                        title: item.title,
                        subtitle: item.subtitle,
                        modeLabel: item.mode.label
                    ) {
                        onSelectStarter(item.mode, item.prompt)
                    }
                }
            }
            .frame(maxWidth: 680)
        }
        .padding(.vertical, 24)
    }
}

private struct StarterCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let modeLabel: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovering ? Theme.accent : Theme.accentSoft)
                            .frame(width: 30, height: 30)
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isHovering ? Color.white : Theme.accent)
                    }

                    Spacer()

                    Text(modeLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Theme.surfaceSubtle.opacity(0.8), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isHovering ? Theme.accentBorder : Theme.borderSubtle, lineWidth: isHovering ? 1.1 : 0.85)
            )
            .shadow(color: .black.opacity(isHovering ? 0.06 : 0.025), radius: isHovering ? 10 : 4, y: isHovering ? 4 : 1)
            .animation(.easeOut(duration: 0.16), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Editorial Message Row

private struct MessageRowView: View {
    @Environment(AppState.self) private var state
    let message: ChatMessageItem
    @State private var showReasoning = false
    @State private var showRefs = false
    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 90)
                Text(message.content)
                    .font(.system(size: 14.5))
                    .lineSpacing(4.5)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Theme.userBubble.opacity(0.18), radius: 6, y: 2)
            }
        } else {
            VStack(alignment: .leading, spacing: 11) {
                // Assistant Header Line
                HStack(spacing: 8) {
                    CompassEmblem(size: 20)
                    Text("成长决策顾问")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if !message.model.isEmpty || !message.providerName.isEmpty {
                        Text([message.providerName, message.model].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if !message.content.isEmpty && !message.isStreaming {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            copied = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copied = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "已复制" : "复制")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(copied ? Theme.success : Theme.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.surfaceSubtle.opacity(isHovering || copied ? 0.9 : 0), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .opacity(isHovering || copied ? 1 : 0)
                    }
                }

                // Optional Thinking Process Accordion
                if !message.reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showReasoning.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "brain")
                                    .font(.system(size: 11))
                                Text("思考过程")
                                    .font(.system(size: 12, weight: .medium))
                                Image(systemName: showReasoning ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.surfaceSubtle.opacity(0.75), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        if showReasoning {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.borderStrong)
                                    .frame(width: 2.5)
                                Text(message.reasoning)
                                    .font(.system(size: 13))
                                    .lineSpacing(4.5)
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.leading, 4)
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Main Assistant Content
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在结合你的记忆思考…")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    RichMarkdownView(text: message.content)
                }

                // Optional Referenced Local Memories
                if !message.references.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showRefs.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "book.closed")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.accent)
                                Text("参考了 \(message.references.count) 篇本地记忆")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                Image(systemName: showRefs ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.accentSoft.opacity(0.6), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        if showRefs {
                            FlowLayout(spacing: 7, lineSpacing: 7) {
                                ForEach(message.references) { ref in
                                    Button {
                                        Task { await state.jumpToMemory(path: ref.path) }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "doc.text")
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(Theme.accent)
                                            let reason = ref.reasons?.first.map { " · \($0)" } ?? ""
                                            Text("\(ref.title)\(reason)")
                                                .font(.system(size: 11.5, weight: .medium))
                                                .foregroundStyle(Theme.textPrimary)
                                                .lineLimit(1)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Theme.cardBg, in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Theme.borderSubtle, lineWidth: 0.85)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.leading, 2)
            .onHover { isHovering = $0 }
        }
    }
}

// MARK: - Semi-Auto Memory Proposal Confirmation Sheet

struct ProposalConfirmationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private var selectedCount: Int {
        state.proposals.filter(\.selected).count
    }

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 36, height: 36)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("确认写入记忆提案")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("勾选后将写入 iCloud 纯 Markdown，并自动刷新语义索引与本地 Git 快照")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(GhostIconButtonStyle(size: 28))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Theme.canvasBg)

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            // Proposals List
            ScrollView {
                VStack(spacing: 14) {
                    ForEach($state.proposals) { $prop in
                        ProposalCardView(proposal: $prop)
                    }
                }
                .padding(20)
            }
            .background(Theme.canvasBg)

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            // Footer
            HStack {
                Text("已勾选 \(selectedCount) / \(state.proposals.count) 条记忆")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                Button("暂不写入") { dismiss() }
                    .buttonStyle(SubtleOutlineButtonStyle())

                Button {
                    Task { await state.commitSelectedProposals() }
                } label: {
                    if state.isCommittingProposals {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("写入中…")
                        }
                    } else {
                        Text("确认写入 (\(selectedCount))")
                    }
                }
                .buttonStyle(SprucePrimaryButtonStyle())
                .disabled(state.isCommittingProposals || selectedCount == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Theme.sidebarBg.opacity(0.65))
        }
        .frame(width: 740, height: 610)
        .background(Theme.canvasBg)
        .tint(Theme.accent)
    }
}

private struct ProposalCardView: View {
    @Binding var proposal: MemoryProposal
    @State private var showDiff = false
    @State private var showEditor = false

    private var levelLabel: String {
        switch proposal.level {
        case 3: return "Level 3 · 核心自我"
        case 1: return "Level 1 · 收件箱"
        default: return "Level 2 · 常规记忆"
        }
    }

    private var levelTint: Color {
        proposal.level == 3 ? Theme.danger : (proposal.level == 1 ? Theme.textSecondary : Theme.accent)
    }

    private var levelBg: Color {
        proposal.level == 3 ? Theme.dangerSoft : (proposal.level == 1 ? Theme.surfaceSubtle : Theme.accentSoft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    proposal.selected.toggle()
                } label: {
                    Image(systemName: proposal.selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 17))
                        .foregroundStyle(proposal.selected ? Theme.accent : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(proposal.action == "append" ? "追加" : (proposal.exists ? "更新" : "新建")) · \(proposal.path)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                Text(levelLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(levelTint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(levelBg, in: Capsule())
            }

            Text(proposal.summary)
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                    Text("显著性 \(proposal.importance)/10")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Theme.surfaceSubtle.opacity(0.75), in: Capsule())

                if !proposal.emotions.isEmpty {
                    Text(proposal.emotions.joined(separator: " · "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Theme.accentSoft.opacity(0.75), in: Capsule())
                }

                Spacer()

                Picker("隐私级别", selection: $proposal.privacy) {
                    Text("normal · 常规").tag("normal")
                    Text("private · 默认私密").tag("private")
                    Text("sensitive · 拦截云端").tag("sensitive")
                }
                .labelsHidden()
                .frame(width: 170)
            }

            // Expanders for Diff & Markdown
            HStack(spacing: 10) {
                if !proposal.diff.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { showDiff.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showDiff ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("查看变更 Diff")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showEditor.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showEditor ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("查看或微调 Markdown")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if showDiff && !proposal.diff.isEmpty {
                DiffPreviewBox(diff: proposal.diff)
            }

            if showEditor {
                TextEditor(text: $proposal.content)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .padding(10)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.8)
                    )
            }
        }
        .padding(16)
        .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(proposal.selected ? Theme.accentBorder : Theme.borderSubtle, lineWidth: 0.9)
        )
        .opacity(proposal.selected ? 1.0 : 0.65)
    }
}

private struct DiffPreviewBox: View {
    let diff: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    let isAdd = line.hasPrefix("+") && !line.hasPrefix("+++")
                    let isDel = line.hasPrefix("-") && !line.hasPrefix("---")
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(isAdd ? Theme.success : (isDel ? Theme.danger : Theme.textSecondary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1.5)
                        .background(isAdd ? Theme.successSoft.opacity(0.6) : (isDel ? Theme.dangerSoft.opacity(0.6) : .clear))
                }
            }
            .padding(.vertical, 6)
        }
        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 0.8)
        )
    }
}
