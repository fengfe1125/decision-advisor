import AppKit
import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var state
    @State private var isComposerFocused = false
    @State private var isComposerComposing = false
    @State private var composerEditorHeight: CGFloat = 44
    @State private var showAsOfPopover = false
    @State private var showModelEffortPopover = false
    @State private var isModeTriggerHovering = false
    @State private var isModelEffortTriggerHovering = false

    private var configuredProviders: [ProviderPresetDTO] {
        (state.config?.providers ?? []).filter(\.isConfigured)
    }

    private var activeProvider: ProviderPresetDTO? {
        guard let providers = state.config?.providers else { return nil }
        if let exact = providers.first(where: { $0.id == state.selectedProviderId }) {
            return exact
        }
        return configuredProviders.first ?? providers.first
    }

    private var formattedAsOfShort: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: state.asOfDate)
    }

    private var currentTitle: String {
        if let id = state.currentSessionId,
           let sess = state.sessions.first(where: { $0.id == id }),
           !sess.title.isEmpty {
            return sess.title
        }
        return state.messages.isEmpty ? "新对话" : "当前对话"
    }

    private func submitComposer() {
        let trimmed = state.chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isStreaming, !trimmed.isEmpty else { return }
        showAsOfPopover = false
        showModelEffortPopover = false
        Task { await state.sendChat() }
    }

    var body: some View {
        GeometryReader { geo in
            let canShowInspector = geo.size.width > 980
            let showInspector = state.isInspectorVisible && canShowInspector
            HStack(spacing: 0) {
                chatColumn(canShowInspector: canShowInspector)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    ChatInspectorPanel()
                        .frame(width: Theme.inspectorWidth)
                        .glassPanel()
                        .padding(.trailing, Theme.panelInset)
                        .padding(.vertical, Theme.panelInset)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private func toolbar(canShowInspector: Bool) -> some View {
        @Bindable var state = state

        ZStack {
            WindowDragHandle()

            HStack(spacing: 10) {
                SidebarRevealButtons(showNewChat: true)

                if !state.messages.isEmpty {
                    HStack(spacing: 6) {
                        Text(currentTitle)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text("· \(state.messages.count) 条消息")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    .padding(.leading, state.isSidebarVisible ? 10 : 0)
                    .frame(minWidth: 60, alignment: .leading)
                    .layoutPriority(-1)
                }

                Spacer(minLength: 8)

                if canShowInspector {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            state.isInspectorVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                            .font(.system(size: 13.5))
                    }
                    .buttonStyle(GhostIconButtonStyle(size: 30, isActive: state.isInspectorVisible))
                    .padding(2)
                    .glassCapsule()
                    .help(state.isInspectorVisible ? "隐藏检查器" : "显示检查器（检索上下文与引用记忆）")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
        }
        .frame(height: Theme.headerHeight)
    }

    // MARK: Native Anchored Composer Menus

    private var composerModeMenu: some View {
        Menu {
            Section("对话模式") {
                ForEach(ChatMode.allCases) { mode in
                    Toggle(
                        isOn: Binding(
                            get: { state.chatMode == mode },
                            set: { isOn in
                                if isOn { state.chatMode = mode }
                            }
                        )
                    ) {
                        Text(mode.label)
                        Text(mode.shortSubtitle)
                        Image(systemName: mode.icon)
                    }
                }
            }

            Divider()

            Button {
                Task { await state.startGuidedInterview(focusSlot: nil) }
            } label: {
                Text("让顾问主动发起冷启动访谈…")
                Text("由顾问先提 1～2 个温和问题，逐步建档")
                Image(systemName: "mic.badge.plus")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.chatMode.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accentInk)
                Text(state.chatMode.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accentInk)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.accentInk.opacity(0.68))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.selectionFill))
            .overlay(
                Capsule()
                    .strokeBorder(isModeTriggerHovering ? Theme.accentBorder : .clear, lineWidth: 0.85)
            )
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isModeTriggerHovering = $0 }
        .help("切换对话模式：日常倾诉 / 9步决策 / 冷启动访谈 / 周期反思")
    }

    private var composerModelAndEffortPill: some View {
        Group {
            if state.config != nil {
                let isReady = activeProvider?.isConfigured == true
                let supported = activeProvider?.supportsReasoningEffort ?? true
                let currentEffort = state.reasoningEffort
                let presetDefault = activeProvider?.defaultReasoningEffort ?? .auto
                let isCustomActive = isReady && supported && currentEffort.isExplicit && currentEffort != .none
                let isHighlighted = isCustomActive || showModelEffortPopover

                let modelText: String = {
                    if let p = activeProvider, p.isConfigured {
                        return p.displayModelName
                    }
                    return configuredProviders.isEmpty ? "未配置模型" : (activeProvider?.displayModelName ?? "选择模型")
                }()

                let effortSuffix: String? = {
                    guard isReady, supported else { return nil }
                    if currentEffort == .auto && presetDefault != .auto {
                        return "自动·\(presetDefault.pillLabel)"
                    }
                    return currentEffort.pillLabel
                }()

                let helpText: String = {
                    let modelPart = activeProvider.map { "\($0.name) · \($0.displayModelName)" } ?? "选择已配置的模型"
                    guard supported else { return "\(modelPart)（不支持调节思考强度）" }
                    return "\(modelPart) · 思考强度：\(currentEffort.label)"
                }()

                Button {
                    showAsOfPopover = false
                    showModelEffortPopover.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isReady ? Theme.success : Theme.warning)
                            .frame(width: 6, height: 6)

                        Text(modelText)
                            .font(.system(size: 11.5, weight: isCustomActive ? .semibold : .medium))
                            .foregroundStyle(
                                isHighlighted
                                ? Theme.accentInk
                                : (isModelEffortTriggerHovering ? Theme.textPrimary : Theme.textSecondary)
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let effortSuffix {
                            Text("·")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(isHighlighted ? Theme.accentInk.opacity(0.45) : Theme.textTertiary)
                                .fixedSize()

                            HStack(spacing: 3) {
                                if currentEffort == .none {
                                    Image(systemName: "bolt.slash")
                                        .font(.system(size: 9.5, weight: .medium))
                                }
                                Text(effortSuffix)
                                    .font(.system(size: 11.5, weight: isCustomActive ? .semibold : .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(
                                isHighlighted
                                ? Theme.accentInk
                                : (isModelEffortTriggerHovering ? Theme.textPrimary : Theme.textSecondary)
                            )
                            .fixedSize(horizontal: true, vertical: false)
                        }

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(isHighlighted ? Theme.accentInk.opacity(0.68) : Theme.textTertiary)
                    }
                    .padding(.horizontal, 9.5)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(
                                isHighlighted
                                ? Theme.selectionFill
                                : (isModelEffortTriggerHovering ? Theme.hoverFill.opacity(0.92) : Theme.surfaceSubtle.opacity(0.85))
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isHighlighted
                                ? Theme.accentBorder.opacity(isModelEffortTriggerHovering || showModelEffortPopover ? 1 : 0.6)
                                : (isModelEffortTriggerHovering ? Theme.borderSubtle : .clear),
                                lineWidth: 0.85
                            )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 232)
                .onHover { isModelEffortTriggerHovering = $0 }
                .help(helpText)
                .popover(isPresented: $showModelEffortPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    ModelAndReasoningPopover(isPresented: $showModelEffortPopover)
                        .environment(state)
                }
            }
        }
    }

    // MARK: Main Column

    @ViewBuilder
    private func chatColumn(canShowInspector: Bool) -> some View {
        VStack(spacing: 0) {
            toolbar(canShowInspector: canShowInspector)

            ZStack(alignment: .bottom) {
                if state.messages.isEmpty {
                    Color.clear
                        .allowsHitTesting(false)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
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
                            .padding(.top, 14)
                            .padding(.bottom, 160)
                        }
                        .scrollIndicators(.automatic)
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

                composer
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: state.currentSessionId) { _, _ in
            showAsOfPopover = false
            showModelEffortPopover = false
        }
    }

    // MARK: Floating Glass Composer

    private var composer: some View {
        @Bindable var state = state

        return VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if state.chatInput.isEmpty && !isComposerComposing {
                    Text(state.chatMode.placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 11)
                        .allowsHitTesting(false)
                }

                ComposerTextEditor(
                    text: $state.chatInput,
                    isFocused: $isComposerFocused,
                    isComposing: $isComposerComposing,
                    height: $composerEditorHeight,
                    onSubmit: submitComposer
                )
                .frame(height: composerEditorHeight)
                .animation(.easeOut(duration: 0.10), value: composerEditorHeight)
            }

            HStack(spacing: 5) {
                composerModeMenu

                ComposerChip(
                    icon: state.useAsOfDate ? "calendar.badge.clock" : "calendar",
                    text: state.useAsOfDate ? "回溯 \(formattedAsOfShort)" : "回溯",
                    isOn: state.useAsOfDate || showAsOfPopover
                ) {
                    showModelEffortPopover = false
                    showAsOfPopover.toggle()
                }
                .help("按历史日期回溯：仅检索该日期之前的记忆")
                .popover(isPresented: $showAsOfPopover, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    AsOfDatePopover(isPresented: $showAsOfPopover)
                        .environment(state)
                }

                ComposerChip(
                    icon: state.allowSensitive ? "lock.open" : "lock.shield",
                    text: state.allowSensitive ? "含敏感" : "敏感保护",
                    isOn: state.allowSensitive,
                    tint: state.allowSensitive ? Theme.warning : Theme.accent
                ) {
                    state.allowSensitive.toggle()
                }
                .help("默认拦截 privacy: sensitive 记忆，开启后仅本轮放行")

                if !state.messages.isEmpty {
                    ComposerChip(
                        icon: state.isExtractingProposals ? "hourglass" : "sparkles",
                        text: state.isExtractingProposals ? "提炼中…" : "提炼记忆",
                        isOn: false
                    ) {
                        showAsOfPopover = false
                        showModelEffortPopover = false
                        Task { await state.extractProposals() }
                    }
                    .disabled(state.isExtractingProposals || state.isStreaming)
                    .help("从当前对话提炼记忆提案（半自动确认写入）")
                }

                Spacer(minLength: 6)

                composerModelAndEffortPill

                let canSend = !state.isStreaming && !state.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: submitComposer) {
                    ZStack {
                        Circle()
                            .fill(canSend ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.surfaceSubtle))
                            .frame(width: 32, height: 32)
                            .shadow(color: Theme.accent.opacity(canSend ? 0.25 : 0), radius: 5, y: 2)
                        if state.isStreaming {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundStyle(canSend ? Theme.onAccent : Theme.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("发送消息（↩ 发送 · ⇧↩ 换行）")
            }
            .padding(.horizontal, 9)
            .padding(.top, 2)
            .padding(.bottom, 9)
        }
        .glassPanel(cornerRadius: 22, tint: Theme.cardBg)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accentBorder.opacity(isComposerFocused ? 1 : 0), lineWidth: 1.2)
        )
    }
}

private struct ComposerChip: View {
    let icon: String
    let text: String
    let isOn: Bool
    var tint: Color = Theme.accent
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(text)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
            }
            .foregroundStyle(!isEnabled ? Theme.textTertiary : (isOn ? tint : Theme.textSecondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isOn ? tint.opacity(0.13) : (isHovering && isEnabled ? Theme.hoverFill.opacity(0.7) : .clear))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Right Inspector (检索上下文 · 本轮引用 · 模式协议)

private struct ChatInspectorPanel: View {
    @Environment(AppState.self) private var state

    private static let decisionSteps: [String] = [
        "问题重述与判断标准",
        "对照核心自我：价值观 / 底线 / 模式",
        "引用高显著历史经历",
        "回溯同类历史决策",
        "至少 3 个选项（含暂缓与小步试错）",
        "价值观体检与情绪干扰警告",
        "强制反方：事实 / 推断 / 价值判断",
        "排序建议 + 证据 + 1 周验证动作",
        "提炼记忆，建档至决策实验室"
    ]

    private var latestReferences: [MemoryReference] {
        state.messages.last(where: { $0.role != "user" && !$0.references.isEmpty })?.references ?? []
    }

    private var modeDescription: String {
        switch state.chatMode {
        case .chat: return "自由倾诉当下情绪，顾问会结合过往记忆温和陪伴，必要时轻声提示提炼记忆。"
        case .decision: return "剥离外界期待，严格按 9 步反讨好协议拆解选择，强制给出反方视角。"
        case .interview: return "每次只问 1～2 个温和具体的问题，逐步建立核心自我与早期重要经历。"
        case .reflect: return "回看近期速记与经历，梳理情绪模式，找出值得归档入库的洞见。"
        }
    }

    var body: some View {
        @Bindable var state = state

        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                // Top spacer aligned with toolbar
                Color.clear.frame(height: 6)

                GlassSectionHeader(title: "对话与检索")
                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        Image(systemName: "brain")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 16)
                        Text("思考强度")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { state.reasoningEffort },
                                set: { state.setReasoningEffort($0) }
                            )
                        ) {
                            ForEach(ReasoningEffort.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 108)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider().padding(.leading, 36).opacity(0.6)
                    InspectorToggleRow(icon: "calendar", title: "按历史日期回溯", isOn: $state.useAsOfDate)
                    if state.useAsOfDate {
                        HStack {
                            Text("截止日期")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            DatePicker("", selection: $state.asOfDate, in: ...Date(), displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    }
                    Divider().padding(.leading, 36).opacity(0.6)
                    InspectorToggleRow(icon: "lock.shield", title: "本轮允许敏感记忆", isOn: $state.allowSensitive)
                }
                .glassCard(cornerRadius: 12)

                GlassSectionHeader(title: "本轮引用", trailing: latestReferences.isEmpty ? nil : "\(latestReferences.count) 篇")
                    .padding(.top, 8)
                if latestReferences.isEmpty {
                    Text("发送消息后，这里会列出顾问参考的本地记忆，点击即可跳转原文。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineSpacing(2)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(latestReferences.enumerated()), id: \.element.id) { idx, ref in
                            if idx > 0 {
                                Divider().padding(.leading, 12).opacity(0.6)
                            }
                            InspectorReferenceRow(reference: ref) {
                                Task { await state.jumpToMemory(path: ref.path) }
                            }
                        }
                    }
                    .glassCard(cornerRadius: 12)
                }

                if state.chatMode == .decision {
                    GlassSectionHeader(title: "9 步反讨好协议", trailing: "9 步")
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(Self.decisionSteps.enumerated()), id: \.offset) { idx, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                                    .foregroundStyle(Theme.onAccent)
                                    .frame(width: 17, height: 17)
                                    .background(Circle().fill(Theme.accentGradient))
                                Text(step)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 12)
                } else if state.chatMode == .interview, let status = state.onboardingStatus {
                    GlassSectionHeader(title: "核心档案槽位", trailing: "\(status.completeness)%")
                        .padding(.top, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(status.slots) { slot in
                            Button {
                                Task { await state.startGuidedInterview(focusSlot: slot.id) }
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: slot.status == "ready" ? "checkmark.circle.fill" : (slot.status == "partial" ? "circle.lefthalf.filled" : "circle.dashed"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(slot.status == "ready" ? Theme.success : (slot.status == "partial" ? Theme.warning : Theme.textTertiary))
                                        .padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 1.5) {
                                        Text(slot.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Theme.textPrimary)
                                        Text(slot.status == "ready" ? "已建立 · 点击可继续深化" : slot.description)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(Theme.textTertiary)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 12)
                } else {
                    GlassSectionHeader(title: "当前模式")
                        .padding(.top, 8)
                    HStack(alignment: .top, spacing: 10) {
                        ColorIconTile(systemName: state.chatMode.icon, color: Theme.accent, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(state.chatMode.label)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(modeDescription)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 12)
                }

                Button {
                    Task { await state.extractProposals() }
                } label: {
                    HStack(spacing: 6) {
                        if state.isExtractingProposals {
                            ProgressView().controlSize(.small)
                            Text("提炼中…")
                        } else {
                            Image(systemName: "sparkles")
                            Text("提炼记忆提案")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SprucePrimaryButtonStyle())
                .disabled(state.messages.isEmpty || state.isExtractingProposals || state.isStreaming)
                .padding(.top, 10)
            }
            .padding(12)
        }
    }
}

private struct InspectorToggleRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct InspectorReferenceRow: View {
    let reference: MemoryReference
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    let meta = [reference.category, reference.reasons?.first].compactMap { $0 }.filter { !$0.isEmpty }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let imp = reference.importance {
                    Text("★\(imp)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(imp >= 7 ? Theme.warning : Theme.textTertiary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(isHovering ? Theme.hoverFill.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Native Composer TextEditor (Return = Send · Shift+Return = Newline · IME Safe)

private final class ComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? SubmitAwareTextView else { return }
        let targetWidth = contentSize.width
        let targetMinHeight = max(44, contentSize.height)
        if textView.minSize.height != targetMinHeight {
            textView.minSize = NSSize(width: 0, height: targetMinHeight)
        }
        if targetWidth > 1 && abs(textView.frame.size.width - targetWidth) > 0.5 {
            textView.frame = NSRect(
                x: 0,
                y: 0,
                width: targetWidth,
                height: max(textView.frame.size.height, targetMinHeight)
            )
            textView.textContainer?.containerSize = NSSize(
                width: max(1, targetWidth - textView.textContainerInset.width * 2),
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.recalculateHeight()
        } else if textView.frame.size.height < targetMinHeight {
            textView.frame.size.height = targetMinHeight
        }
    }
}

private final class SubmitAwareTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onCompositionChange: ((Bool) -> Void)?

    private let minEditorHeight: CGFloat = 44
    private let maxEditorHeight: CGFloat = 152
    private var currentKeyFlags: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        currentKeyFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        defer { currentKeyFlags = [] }
        super.keyDown(with: event)
    }

    func applyTypingStyle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        defaultParagraphStyle = paragraph
        let font = NSFont.systemFont(ofSize: 14)
        let color = Theme.textPrimaryNS
        self.font = font
        self.textColor = color
        self.insertionPointColor = Theme.accentInkNS
        self.typingAttributes = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTypingStyle()
        if let storage = textStorage, storage.length > 0 {
            storage.addAttribute(.foregroundColor, value: Theme.textPrimaryNS, range: NSRange(location: 0, length: storage.length))
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?(hasMarkedText())
        recalculateHeight()
    }

    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?(hasMarkedText())
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76
        if isReturnKey && flags.contains(.command) && window?.firstResponder === self {
            if !hasMarkedText() {
                onSubmit?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if hasMarkedText() {
                super.doCommand(by: selector)
                return
            }
            let flags = currentKeyFlags.isEmpty
                ? (NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? [])
                : currentKeyFlags
            let wantsNewline = flags.contains(.shift) || flags.contains(.option) || flags.contains(.control)
            if wantsNewline {
                super.doCommand(by: selector)
                recalculateHeight()
                scrollRangeToVisible(selectedRange())
                return
            }
            onSubmit?()
            return
        }
        super.doCommand(by: selector)
        if selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || selector == #selector(NSResponder.insertLineBreak(_:)) {
            recalculateHeight()
            scrollRangeToVisible(selectedRange())
        }
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
        recalculateHeight()
    }

    func recalculateHeight() {
        if string.isEmpty && !hasMarkedText() {
            onHeightChange?(minEditorHeight)
            return
        }
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let extraMaxY = layoutManager.extraLineFragmentTextContainer === textContainer
            ? layoutManager.extraLineFragmentRect.maxY
            : 0
        let contentHeight = max(used, extraMaxY)
        let verticalInset = textContainerInset.height * 2
        let target = min(maxEditorHeight, max(minEditorHeight, ceil(contentHeight + verticalInset)))
        onHeightChange?(target)
    }
}

private struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var isComposing: Bool
    @Binding var height: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scrollView = ComposerScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = SubmitAwareTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 11, height: 11)
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 44)
        textView.applyTypingStyle()

        let coordinator = context.coordinator
        textView.onSubmit = { [weak coordinator] in
            coordinator?.parent.onSubmit()
        }
        textView.onFocusChange = { [weak coordinator] focused in
            DispatchQueue.main.async {
                guard let coordinator, coordinator.parent.isFocused != focused else { return }
                coordinator.parent.isFocused = focused
            }
        }
        textView.onCompositionChange = { [weak coordinator] composing in
            DispatchQueue.main.async {
                guard let coordinator, coordinator.parent.isComposing != composing else { return }
                coordinator.parent.isComposing = composing
            }
        }
        textView.onHeightChange = { [weak coordinator] newHeight in
            DispatchQueue.main.async {
                guard let coordinator, abs(coordinator.parent.height - newHeight) > 0.5 else { return }
                coordinator.parent.height = newHeight
            }
        }

        textView.string = text
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? SubmitAwareTextView else { return }

        if text.isEmpty && (!textView.string.isEmpty || textView.hasMarkedText()) {
            textView.unmarkText()
            textView.string = ""
            textView.applyTypingStyle()
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.recalculateHeight()
        } else if !textView.hasMarkedText() && textView.string != text {
            textView.string = text
            textView.applyTypingStyle()
            let end = NSRange(location: (text as NSString).length, length: 0)
            textView.setSelectedRange(end)
            textView.recalculateHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SubmitAwareTextView else { return }
            let composing = textView.hasMarkedText()
            if parent.isComposing != composing {
                parent.isComposing = composing
            }
            if !composing {
                let current = textView.string
                if parent.text != current {
                    parent.text = current
                }
            }
            textView.recalculateHeight()
        }
    }
}

// MARK: - Anchored Historical Backfill Popover

private struct AsOfDatePopover: View {
    @Environment(AppState.self) private var state
    @Binding var isPresented: Bool

    private static let presets: [(label: String, component: Calendar.Component, value: Int)] = [
        ("1 周前", .day, -7),
        ("1 个月前", .month, -1),
        ("3 个月前", .month, -3),
        ("1 年前", .year, -1),
    ]

    private func applyPreset(component: Calendar.Component, value: Int) {
        if let target = Calendar.current.date(byAdding: component, value: value, to: Date()) {
            state.asOfDate = target
            state.useAsOfDate = true
        }
    }

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: state.useAsOfDate ? "calendar.badge.clock" : "calendar")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state.useAsOfDate ? Theme.accentInk : Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(state.useAsOfDate ? Theme.selectionFill : Theme.surfaceSubtle)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("按历史日期回溯")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("仅检索该日期之前的记忆，还原当时视角")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 6)

                Toggle("", isOn: $state.useAsOfDate)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.label) { preset in
                    AsOfPresetPill(title: preset.label) {
                        applyPreset(component: preset.component, value: preset.value)
                    }
                }
            }

            HStack {
                Text("截止日期")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                DatePicker(
                    "",
                    selection: Binding(
                        get: { state.asOfDate },
                        set: { newDate in
                            state.asOfDate = newDate
                            state.useAsOfDate = true
                        }
                    ),
                    in: ...Date(),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surfaceSubtle.opacity(0.75), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            if state.useAsOfDate {
                HStack {
                    Spacer()
                    Button("恢复当前时间") {
                        state.useAsOfDate = false
                        isPresented = false
                    }
                    .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                }
            }
        }
        .padding(14)
        .frame(width: 296)
    }
}

private struct AsOfPresetPill: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? Theme.accentInk : Theme.textSecondary)
                .padding(.horizontal, 8.5)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isHovering ? Theme.selectionFill : Theme.surfaceSubtle)
                )
                .overlay(
                    Capsule().strokeBorder(isHovering ? Theme.accentBorder.opacity(0.6) : .clear, lineWidth: 0.7)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Anchored Model & Reasoning Effort Popover

private struct ModelAndReasoningPopover: View {
    @Environment(AppState.self) private var state
    @Binding var isPresented: Bool

    private var configuredProviders: [ProviderPresetDTO] {
        (state.config?.providers ?? []).filter(\.isConfigured)
    }

    private var activeProvider: ProviderPresetDTO? {
        guard let providers = state.config?.providers else { return nil }
        if let exact = providers.first(where: { $0.id == state.selectedProviderId }) {
            return exact
        }
        return configuredProviders.first ?? providers.first
    }

    var body: some View {
        let cfg = state.config
        let isReady = activeProvider?.isConfigured == true
        let chatgptConnected = cfg?.chatgptOauth?.connected == true
        let chatgptPlan = cfg?.chatgptOauth?.planType ?? ""
        let chatgptModels = cfg?.chatgptOauth?.availableModels ?? []
        let currentChatGPTModel = cfg?.providers.first(where: { $0.kind == "chatgpt_oauth" })?.model ?? ""

        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .center, spacing: 8) {
                Text("模型与思考强度")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                HStack(spacing: 4.5) {
                    Circle()
                        .fill(isReady ? Theme.success : Theme.warning)
                        .frame(width: 6, height: 6)
                    Text(isReady ? "已就绪" : "未配置")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isReady ? Theme.accentInk : Theme.warning)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(
                    Capsule().fill(isReady ? Theme.selectionFill : Theme.warningSoft)
                )
            }

            // Models list
            if configuredProviders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("暂无已配置模型（请先填写 Key 或授权）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)

                    if !chatgptConnected {
                        Button {
                            isPresented = false
                            state.openModelsSettings()
                            Task {
                                await state.startChatGPTLogin(forceRegister: false, openBrowser: true)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.badge.key.fill")
                                    .font(.system(size: 11.5))
                                Text("使用 ChatGPT 授权登录…")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SprucePrimaryButtonStyle(compact: true))
                    }
                }
                .padding(.vertical, 4)
            } else {
                let listContent = VStack(spacing: 2) {
                    ForEach(configuredProviders) { provider in
                        let isSelected = activeProvider?.id == provider.id
                        let badge: String? = {
                            if provider.kind == "chatgpt_oauth", !chatgptPlan.isEmpty {
                                return chatgptPlan.uppercased()
                            }
                            if !provider.supportsReasoningEffort {
                                return "无思考"
                            }
                            if configuredProviders.count > 1 && provider.id == cfg?.activeProviderId {
                                return "默认"
                            }
                            return nil
                        }()

                        ModelPopoverRow(
                            provider: provider,
                            badge: badge,
                            isSelected: isSelected
                        ) {
                            state.selectedProviderId = provider.id
                        }
                    }

                    if chatgptConnected && chatgptModels.count > 1 && activeProvider?.kind == "chatgpt_oauth" {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ChatGPT 订阅模型")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)

                            FlowLayout(spacing: 5, lineSpacing: 5) {
                                ForEach(chatgptModels) { opt in
                                    let isCurrent = currentChatGPTModel.trimmingCharacters(in: .whitespacesAndNewlines) == opt.slug
                                    ChatGPTSubModelPill(
                                        title: opt.displayName,
                                        isSelected: isCurrent
                                    ) {
                                        Task { await state.switchChatGPTModel(opt.slug) }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 5)
                        .padding(.bottom, 2)
                    }
                }

                if configuredProviders.count > 6 {
                    ScrollView(.vertical, showsIndicators: true) {
                        listContent
                    }
                    .frame(maxHeight: 224)
                } else {
                    listContent
                }
            }

            // Stardust Reasoning Effort Slider Card
            StardustReasoningSliderCard(
                activeProvider: activeProvider,
                effort: state.reasoningEffort
            ) { newEffort in
                state.setReasoningEffort(newEffort)
            }

            Divider().opacity(0.6)

            // Footer
            HStack(spacing: 8) {
                Button {
                    isPresented = false
                    state.openModelsSettings()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .medium))
                        Text("配置模型与授权…")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Text("完成")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.selectionFill))
                        .overlay(Capsule().strokeBorder(Theme.accentBorder.opacity(0.6), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(13)
        .frame(width: 326)
    }
}

private struct ModelPopoverRow: View {
    let provider: ProviderPresetDTO
    let badge: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? Theme.success : Theme.textTertiary.opacity(0.45))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 5) {
                        Text(provider.displayModelName)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Theme.accentInk : Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let badge, !badge.isEmpty {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.surfaceSubtle))
                                .fixedSize()
                        }
                    }

                    Text(provider.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accentInk)
                }
            }
            .padding(.horizontal, 8.5)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.selectionFill : (isHovering ? Theme.hoverFill.opacity(0.75) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct ChatGPTSubModelPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.accentInk : (isHovering ? Theme.textPrimary : Theme.textSecondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(isSelected ? Theme.selectionFill : (isHovering ? Theme.hoverFill : Theme.surfaceSubtle))
                )
                .overlay(
                    Capsule().strokeBorder(isSelected ? Theme.accentBorder.opacity(0.65) : .clear, lineWidth: 0.7)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct StardustSeed: Sendable {
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let speed: Double
    let phase: Double
    let dx: CGFloat
    let dy: CGFloat
}

private struct StardustReasoningSliderCard: View {
    let activeProvider: ProviderPresetDTO?
    let effort: ReasoningEffort
    let onSelect: (ReasoningEffort) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragFraction: CGFloat? = nil
    @State private var lastHapticStopIndex: Int? = nil
    @State private var isAutoHovering = false

    private static let sliderStops: [ReasoningEffort] = [.none, .low, .medium, .high, .xhigh]

    private static let stardustSeeds: [StardustSeed] = [
        StardustSeed(x: 0.06, y: 0.28, radius: 1.7, speed: 2.3, phase: 0.0, dx: 2.0, dy: -1.4),
        StardustSeed(x: 0.10, y: 0.66, radius: 1.2, speed: 1.9, phase: 1.1, dx: -1.2, dy: 1.6),
        StardustSeed(x: 0.15, y: 0.44, radius: 1.4, speed: 2.1, phase: 2.3, dx: 1.5, dy: -1.6),
        StardustSeed(x: 0.20, y: 0.74, radius: 1.1, speed: 1.7, phase: 0.7, dx: 1.8, dy: 1.1),
        StardustSeed(x: 0.25, y: 0.30, radius: 1.3, speed: 2.4, phase: 3.0, dx: -1.4, dy: 1.3),
        StardustSeed(x: 0.30, y: 0.64, radius: 1.8, speed: 2.0, phase: 1.7, dx: 2.1, dy: -1.7),
        StardustSeed(x: 0.35, y: 0.48, radius: 1.1, speed: 2.5, phase: 3.8, dx: -1.1, dy: -1.3),
        StardustSeed(x: 0.39, y: 0.56, radius: 1.5, speed: 1.8, phase: 0.4, dx: 1.4, dy: 1.8),
        StardustSeed(x: 0.44, y: 0.24, radius: 1.6, speed: 2.2, phase: 2.6, dx: -1.8, dy: 1.4),
        StardustSeed(x: 0.48, y: 0.70, radius: 1.3, speed: 2.0, phase: 1.3, dx: 1.6, dy: -1.8),
        StardustSeed(x: 0.53, y: 0.40, radius: 1.1, speed: 2.6, phase: 4.2, dx: 1.9, dy: 1.0),
        StardustSeed(x: 0.58, y: 0.58, radius: 1.4, speed: 1.9, phase: 0.9, dx: -1.4, dy: -1.5),
        StardustSeed(x: 0.63, y: 0.28, radius: 1.7, speed: 2.1, phase: 3.2, dx: 1.5, dy: 1.8),
        StardustSeed(x: 0.66, y: 0.64, radius: 1.2, speed: 2.0, phase: 2.0, dx: -1.9, dy: -1.1),
        StardustSeed(x: 0.70, y: 0.46, radius: 1.5, speed: 2.3, phase: 0.2, dx: 1.9, dy: -1.4),
        StardustSeed(x: 0.75, y: 0.34, radius: 1.1, speed: 1.7, phase: 2.8, dx: -1.1, dy: 1.4),
        StardustSeed(x: 0.79, y: 0.68, radius: 1.3, speed: 2.5, phase: 1.5, dx: 1.5, dy: -1.7),
        StardustSeed(x: 0.84, y: 0.44, radius: 1.5, speed: 2.1, phase: 3.5, dx: -1.4, dy: 1.1),
        StardustSeed(x: 0.89, y: 0.58, radius: 1.3, speed: 2.2, phase: 0.6, dx: 1.1, dy: -1.4),
    ]

    private var supported: Bool {
        activeProvider?.supportsReasoningEffort ?? true
    }

    private var presetDefault: ReasoningEffort {
        activeProvider?.defaultReasoningEffort ?? .auto
    }

    private var isDragging: Bool {
        dragFraction != nil
    }

    private func shortTickLabel(for level: ReasoningEffort) -> String {
        switch level {
        case .auto: return "自动"
        case .none: return "关闭"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "极高"
        }
    }

    private var effectiveFraction: CGFloat {
        if let dragFraction { return dragFraction }
        guard supported else { return 0 }
        if effort == .auto {
            let presetIdx = Self.sliderStops.firstIndex(of: presetDefault) ?? 2
            return CGFloat(presetIdx) / 4.0
        }
        let idx = Self.sliderStops.firstIndex(of: effort) ?? 2
        return CGFloat(idx) / 4.0
    }

    private var activePreviewEffort: ReasoningEffort {
        if let dragFraction {
            let idx = min(4, max(0, Int((dragFraction * 4.0).rounded())))
            return Self.sliderStops[idx]
        }
        return effort
    }

    private var isVisuallyOff: Bool {
        if !supported { return true }
        if let dragFraction { return dragFraction < 0.08 }
        return effort == .none
    }

    private var isVisuallyAuto: Bool {
        supported && dragFraction == nil && effort == .auto
    }

    private var particleOpacity: Double {
        if !supported || isVisuallyOff { return 0 }
        if isVisuallyAuto { return 0.45 }
        if let dragFraction {
            return 0.35 + Double(dragFraction) * 0.65
        }
        switch effort {
        case .none: return 0
        case .low: return 0.52
        case .medium: return 0.72
        case .high: return 0.88
        case .xhigh: return 1.0
        case .auto: return 0.45
        }
    }

    private var valueLabelText: String {
        guard supported else { return "不支持" }
        let current = activePreviewEffort
        if current == .auto && presetDefault != .auto {
            return "自动·\(presetDefault.pillLabel)"
        }
        return current.label
    }

    private var descriptionText: String {
        guard supported else {
            return "当前模型（\(activeProvider?.displayModelName ?? "")）不支持调节思考强度"
        }
        let current = activePreviewEffort
        if current == .auto {
            if presetDefault != .auto {
                return "遵循当前模型预设（\(presetDefault.label)），拖动滑块可手动接管"
            }
            return "由模型默认策略自动决定，拖动滑块可随时手动指定"
        }
        return current.subtitle
    }

    // Emerald Stardust Palette (aligned with Theme.swift White Glass)
    private var isDark: Bool { colorScheme == .dark }

    private var cardBackground: LinearGradient {
        if isDark {
            return LinearGradient(
                colors: [
                    Color(red: 0.098, green: 0.200, blue: 0.161).opacity(0.75),
                    Color(red: 0.078, green: 0.149, blue: 0.125).opacity(0.88),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.910, green: 0.973, blue: 0.941).opacity(0.80),
                Color(red: 0.965, green: 0.988, blue: 0.976).opacity(0.95),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var cardBorderColor: Color {
        isDark
            ? Color(red: 0.420, green: 0.800, blue: 0.671).opacity(0.36)
            : Color(red: 0.306, green: 0.729, blue: 0.525).opacity(0.45)
    }

    private var accentValueColor: Color {
        isDark
            ? Color(red: 0.553, green: 0.902, blue: 0.769)
            : Color(red: 0.122, green: 0.478, blue: 0.318)
    }

    private var trackBackgroundColor: Color {
        isDark
            ? Color.white.opacity(0.085)
            : Color(red: 0.078, green: 0.243, blue: 0.173).opacity(0.085)
    }

    private var fillGradient: LinearGradient {
        if isDark {
            return LinearGradient(
                stops: [
                    .init(color: Color(red: 0.051, green: 0.184, blue: 0.137), location: 0.0),
                    .init(color: Color(red: 0.106, green: 0.396, blue: 0.286), location: 0.34),
                    .init(color: Color(red: 0.227, green: 0.690, blue: 0.510), location: 0.68),
                    .init(color: Color(red: 0.596, green: 0.922, blue: 0.816), location: 1.0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            stops: [
                .init(color: Color(red: 0.059, green: 0.239, blue: 0.173), location: 0.0),
                .init(color: Color(red: 0.114, green: 0.435, blue: 0.302), location: 0.34),
                .init(color: Color(red: 0.227, green: 0.663, blue: 0.467), location: 0.68),
                .init(color: Color(red: 0.608, green: 0.898, blue: 0.769), location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var fillGlowColor: Color {
        isDark
            ? Color(red: 0.420, green: 0.800, blue: 0.671).opacity(0.24)
            : Color(red: 0.227, green: 0.663, blue: 0.467).opacity(0.28)
    }

    var body: some View {
        let trackHeight: CGFloat = 30
        let thumbSize: CGFloat = 26

        VStack(alignment: .leading, spacing: 7) {
            // Card Header
            HStack(alignment: .center, spacing: 6) {
                Text("思考强度")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        dragFraction = nil
                        onSelect(.auto)
                    }
                } label: {
                    let autoActive = supported && !isDragging && effort == .auto
                    Text("自动")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(autoActive || isAutoHovering ? accentValueColor : Theme.textTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                autoActive || isAutoHovering
                                ? accentValueColor.opacity(isDark ? 0.18 : 0.12)
                                : .clear
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                autoActive ? accentValueColor.opacity(0.32) : .clear,
                                lineWidth: 0.8
                            )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!supported)
                .onHover { isAutoHovering = $0 }
                .help("恢复由模型自动决定思考强度")

                Spacer()

                Text(valueLabelText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isVisuallyOff ? Theme.textTertiary : accentValueColor)
                    .animation(.easeOut(duration: 0.12), value: valueLabelText)
            }

            // Draggable Glowing Particle Pill Track
            GeometryReader { geo in
                let totalWidth = max(trackHeight, geo.size.width)
                let usableWidth = max(1, totalWidth - trackHeight)
                let frac = effectiveFraction
                let fillWidth = trackHeight + usableWidth * frac
                let thumbOffsetX = (trackHeight - thumbSize) * 0.5 + usableWidth * frac

                ZStack(alignment: .leading) {
                    // Recessed track background
                    Capsule()
                        .fill(trackBackgroundColor)
                        .overlay(
                            Capsule().strokeBorder(Color.black.opacity(isDark ? 0.22 : 0.05), lineWidth: 0.6)
                        )

                    // Active gradient fill + animated stardust particles
                    ZStack(alignment: .leading) {
                        if isVisuallyOff {
                            Capsule()
                                .fill(Theme.borderStrong)
                        } else {
                            Capsule()
                                .fill(fillGradient)
                        }

                        if particleOpacity > 0.01 {
                            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !supported || particleOpacity <= 0.01)) { timeline in
                                Canvas { context, size in
                                    let t = timeline.date.timeIntervalSinceReferenceDate
                                    for seed in Self.stardustSeeds {
                                        let wave = sin(t * seed.speed + seed.phase)
                                        let norm = (wave + 1.0) * 0.5
                                        let cx = seed.x * size.width + CGFloat(wave) * seed.dx
                                        let cy = seed.y * size.height + CGFloat(cos(t * seed.speed * 0.85 + seed.phase)) * seed.dy
                                        let alpha = (0.38 + 0.62 * norm) * particleOpacity
                                        let r = seed.radius * (0.85 + 0.25 * CGFloat(norm))

                                        let haloR = r * 2.15
                                        let haloRect = CGRect(x: cx - haloR, y: cy - haloR, width: haloR * 2, height: haloR * 2)
                                        context.fill(Path(ellipseIn: haloRect), with: .color(Color.white.opacity(alpha * 0.34)))

                                        let coreRect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                                        context.fill(Path(ellipseIn: coreRect), with: .color(Color.white.opacity(alpha)))
                                    }
                                }
                            }
                            .frame(width: totalWidth, height: trackHeight)
                            .allowsHitTesting(false)
                        }
                    }
                    .frame(width: fillWidth, height: trackHeight, alignment: .leading)
                    .clipShape(Capsule())
                    .opacity(isVisuallyAuto ? 0.62 : 1.0)
                    .shadow(color: isVisuallyOff ? .clear : fillGlowColor, radius: 6, y: 2)

                    // White circular thumb
                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: Color.black.opacity(isDragging ? 0.28 : 0.20), radius: isDragging ? 5 : 3.5, y: 1.5)
                        .overlay(
                            Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                        )
                        .scaleEffect(isDragging ? 1.07 : 1.0)
                        .offset(x: thumbOffsetX)
                        .animation(.easeOut(duration: 0.12), value: isDragging)
                }
                .frame(height: trackHeight)
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard supported else { return }
                            let raw = (value.location.x - trackHeight * 0.5) / usableWidth
                            let clamped = min(1, max(0, raw))
                            dragFraction = clamped
                            let stopIdx = min(4, max(0, Int((clamped * 4.0).rounded())))
                            if lastHapticStopIndex != stopIdx {
                                lastHapticStopIndex = stopIdx
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            }
                        }
                        .onEnded { value in
                            guard supported else { return }
                            let raw = (value.location.x - trackHeight * 0.5) / usableWidth
                            let clamped = min(1, max(0, raw))
                            let stopIdx = min(4, max(0, Int((clamped * 4.0).rounded())))
                            let target = Self.sliderStops[stopIdx]
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                dragFraction = nil
                                onSelect(target)
                            }
                            lastHapticStopIndex = nil
                        }
                )
            }
            .frame(height: trackHeight)

            // 5-stop clickable tick labels
            HStack {
                ForEach(Array(Self.sliderStops.enumerated()), id: \.element.id) { idx, stop in
                    let isSelectedTick = supported && activePreviewEffort == stop
                    Button {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                            dragFraction = nil
                            onSelect(stop)
                        }
                    } label: {
                        Text(shortTickLabel(for: stop))
                            .font(.system(size: 10, weight: isSelectedTick ? .bold : .medium))
                            .foregroundStyle(isSelectedTick ? accentValueColor : Theme.textTertiary)
                            .padding(.horizontal, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!supported)

                    if idx < Self.sliderStops.count - 1 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 4)

            // Live description
            Text(descriptionText)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(cardBorderColor, lineWidth: 1.1)
        )
        .opacity(supported ? 1.0 : 0.54)
    }
}

// MARK: - Editorial Message Row

private struct MessageRowView: View {
    @Environment(AppState.self) private var state
    let message: ChatMessageItem
    @State private var showReasoning = false
    @State private var isHovering = false
    @State private var copied = false

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 90)
                Text(message.content)
                    .font(.system(size: 14.5))
                    .lineSpacing(4.5)
                    .foregroundStyle(Theme.userBubbleText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 19, bottomLeadingRadius: 19,
                            bottomTrailingRadius: 6, topTrailingRadius: 19,
                            style: .continuous
                        )
                        .fill(Theme.userBubble)
                    )
                    .overlay(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 19, bottomLeadingRadius: 19,
                            bottomTrailingRadius: 6, topTrailingRadius: 19,
                            style: .continuous
                        )
                        .strokeBorder(Theme.accentBorder.opacity(0.45), lineWidth: 0.6)
                    )
                    .shadow(color: Theme.accent.opacity(0.08), radius: 5, y: 2)
            }
        } else {
            VStack(alignment: .leading, spacing: 11) {
                // Assistant Header Line
                HStack(spacing: 8) {
                    CompassEmblem(size: 24)
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

                // Optional Thinking Process (glass disclosure card)
                if !message.reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showReasoning.toggle()
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .rotationEffect(.degrees(showReasoning ? 90 : 0))
                                    .foregroundStyle(Theme.textTertiary)
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.accent)
                                Text("思考过程")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text(message.isStreaming ? "思考中…" : "\(message.reasoning.count) 字")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showReasoning {
                            Text(message.reasoning)
                                .font(.system(size: 12.5))
                                .lineSpacing(4.5)
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 12)
                                .padding(.leading, 18)
                        }
                    }
                    .glassCard(cornerRadius: 12)
                }

                // Main Assistant Content
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            (state.reasoningEffort == .high || state.reasoningEffort == .xhigh)
                            ? "正在结合你的记忆深入思考…"
                            : "正在结合你的记忆思考…"
                        )
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    RichMarkdownView(text: message.content)
                }

                // Referenced Local Memories (glass chips)
                if !message.references.isEmpty {
                    FlowLayout(spacing: 7, lineSpacing: 7) {
                        ForEach(message.references) { ref in
                            ReferenceChip(reference: ref) {
                                Task { await state.jumpToMemory(path: ref.path) }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.leading, 2)
            .onHover { isHovering = $0 }
        }
    }
}

private struct ReferenceChip: View {
    let reference: MemoryReference
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(reference.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    let meta = [reference.category, reference.reasons?.first].compactMap { $0 }.filter { !$0.isEmpty }
                    if !meta.isEmpty {
                        Text(meta.joined(separator: " · "))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, 7)
            .padding(.trailing, 11)
            .padding(.vertical, 6)
            .glassCard(cornerRadius: 11, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("打开记忆原文")
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
