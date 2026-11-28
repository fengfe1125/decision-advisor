import AppKit
import SwiftUI

private enum ComposerPopover: Equatable {
    case mode
    case context
    case model

    var anchor: UnitPoint {
        switch self {
        case .model: return .bottomTrailing
        case .mode, .context: return .bottomLeading
        }
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var state
    @State private var isComposerFocused = false
    @State private var isComposerComposing = false
    @State private var composerEditorHeight: CGFloat = 44
    @State private var activePopover: ComposerPopover? = nil
    @State private var isModeTriggerHovering = false
    @State private var isModelTriggerHovering = false

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

    private func togglePopover(_ target: ComposerPopover) {
        let next: ComposerPopover? = (activePopover == target) ? nil : target
        if next != nil {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
            activePopover = next
        }
    }

    private func dismissPopover() {
        guard activePopover != nil else { return }
        withAnimation(.spring(response: 0.20, dampingFraction: 0.90)) {
            activePopover = nil
        }
    }

    private func submitComposer() {
        let trimmed = state.chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isStreaming, !trimmed.isEmpty else { return }
        dismissPopover()
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

    private var composerModeTrigger: some View {
        let isOpen = activePopover == .mode
        return Button {
            togglePopover(.mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.chatMode.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isOpen ? Theme.accentInk : Theme.accent)
                Text(state.chatMode.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isOpen ? Theme.accentInk : Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isOpen ? Theme.accentInk.opacity(0.75) : Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isOpen ? Theme.selectionFill : (isModeTriggerHovering ? Theme.selectionFill.opacity(0.95) : Theme.selectionFill))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isOpen ? Theme.accentBorder : (isModeTriggerHovering ? Theme.accentBorder.opacity(0.5) : .clear), lineWidth: 0.85)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isModeTriggerHovering = $0 }
        .help("切换对话模式：日常倾诉 / 9步决策 / 冷启动访谈 / 周期反思")
    }

    private var composerModelTrigger: some View {
        Group {
            if state.config != nil {
                let isOpen = activePopover == .model
                let isReady = activeProvider?.isConfigured == true
                let labelText: String = {
                    if let p = activeProvider, p.isConfigured {
                        return p.displayModelName
                    }
                    return configuredProviders.isEmpty ? "未配置模型" : (activeProvider?.displayModelName ?? "选择模型")
                }()

                Button {
                    togglePopover(.model)
                } label: {
                    HStack(spacing: 5.5) {
                        Circle()
                            .fill(isReady ? Theme.success : Theme.warning)
                            .frame(width: 6, height: 6)
                        Text(labelText)
                            .font(.system(size: 11.5, weight: isOpen ? .semibold : .medium))
                            .foregroundStyle(isOpen ? Theme.accentInk : (isModelTriggerHovering ? Theme.textPrimary : Theme.textSecondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(isOpen ? Theme.accentInk.opacity(0.75) : Theme.textTertiary)
                    }
                    .padding(.horizontal, 9.5)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(
                                isOpen
                                ? Theme.selectionFill
                                : (isModelTriggerHovering ? Theme.hoverFill.opacity(0.92) : Theme.surfaceSubtle.opacity(0.85))
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isOpen ? Theme.accentBorder : (isModelTriggerHovering ? Theme.borderSubtle : .clear),
                                lineWidth: 0.8
                            )
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { isModelTriggerHovering = $0 }
                .frame(maxWidth: 190)
                .help(activeProvider.map { "\($0.name) · \($0.displayModelName)" } ?? "选择已配置的模型")
            }
        }
    }

    // MARK: Main Column

    @ViewBuilder
    private func chatColumn(canShowInspector: Bool) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                toolbar(canShowInspector: canShowInspector)

                if state.messages.isEmpty {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if activePopover != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissPopover()
                    }
                    .zIndex(10)

                Button("") {
                    dismissPopover()
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }

            VStack(spacing: 8) {
                if let popover = activePopover {
                    floatingPopoverRow(for: popover)
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .scale(scale: 0.96, anchor: popover.anchor))
                                    .combined(with: .offset(y: 6)),
                                removal: .opacity
                                    .combined(with: .scale(scale: 0.97, anchor: popover.anchor))
                            )
                        )
                }

                composer
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 28)
            .padding(.bottom, 18)
            .zIndex(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: isComposerFocused) { _, focused in
            if focused && activePopover != nil {
                dismissPopover()
            }
        }
        .onChange(of: state.currentSessionId) { _, _ in
            if activePopover != nil {
                dismissPopover()
            }
        }
    }

    @ViewBuilder
    private func floatingPopoverRow(for popover: ComposerPopover) -> some View {
        switch popover {
        case .model:
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ComposerModelPopover(
                    providers: configuredProviders,
                    selectedProviderId: state.selectedProviderId,
                    defaultProviderId: state.config?.activeProviderId ?? "",
                    chatgptPlanType: state.config?.chatgptOauth?.planType ?? "",
                    chatgptConnected: state.config?.chatgptOauth?.connected == true,
                    onSelect: { provider in
                        state.selectedProviderId = provider.id
                        dismissPopover()
                    },
                    onOpenSettings: {
                        dismissPopover()
                        state.openModelsSettings()
                    },
                    onStartChatGPTLogin: {
                        dismissPopover()
                        state.openModelsSettings()
                        Task {
                            await state.startChatGPTLogin(forceRegister: false, openBrowser: true)
                        }
                    }
                )
            }
            .padding(.trailing, 4)

        case .mode:
            HStack(spacing: 0) {
                ComposerModePopover(
                    selectedMode: state.chatMode,
                    onSelect: { mode in
                        state.chatMode = mode
                        dismissPopover()
                    },
                    onStartInterview: {
                        dismissPopover()
                        Task { await state.startGuidedInterview(focusSlot: nil) }
                    }
                )
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)

        case .context:
            HStack(spacing: 0) {
                ChatContextOptionsPopover()
                    .environment(state)
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
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
                composerModeTrigger

                ComposerChip(
                    icon: state.useAsOfDate ? "calendar.badge.clock" : "calendar",
                    text: state.useAsOfDate ? "回溯 \(formattedAsOfShort)" : "回溯",
                    isOn: state.useAsOfDate || activePopover == .context
                ) {
                    togglePopover(.context)
                }
                .help("按历史日期回溯：仅检索该日期之前的记忆")

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
                        dismissPopover()
                        Task { await state.extractProposals() }
                    }
                    .disabled(state.isExtractingProposals || state.isStreaming)
                    .help("从当前对话提炼记忆提案（半自动确认写入）")
                }

                Spacer(minLength: 6)

                composerModelTrigger

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

                GlassSectionHeader(title: "检索上下文")
                VStack(spacing: 0) {
                    InspectorToggleRow(icon: "calendar", title: "按历史日期回溯", isOn: $state.useAsOfDate)
                    if state.useAsOfDate {
                        HStack {
                            Text("截止日期")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            DatePicker("", selection: $state.asOfDate, displayedComponents: .date)
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

// MARK: - Redesigned Floating Glass Composer Popovers

private struct ComposerModelPopover: View {
    let providers: [ProviderPresetDTO]
    let selectedProviderId: String
    let defaultProviderId: String
    let chatgptPlanType: String
    let chatgptConnected: Bool
    let onSelect: (ProviderPresetDTO) -> Void
    let onOpenSettings: () -> Void
    let onStartChatGPTLogin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("已配置模型")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if !providers.isEmpty {
                    Text("\(providers.count) 个可用")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 7)

            if providers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.warningSoft)
                                .frame(width: 30, height: 30)
                            Image(systemName: "key.horizontal")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.warning)
                        }

                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("暂无已配置模型")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("请先在设置中填写 API Key 或完成 ChatGPT 订阅授权。")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !chatgptConnected {
                        Button(action: onStartChatGPTLogin) {
                            Label("使用 ChatGPT 授权登录", systemImage: "person.badge.key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SprucePrimaryButtonStyle(compact: true))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                let listContent = VStack(spacing: 3) {
                    ForEach(providers) { provider in
                        let isSelected = provider.id == selectedProviderId
                        let tag: String? = {
                            if provider.kind == "chatgpt_oauth", !chatgptPlanType.isEmpty {
                                return chatgptPlanType.uppercased()
                            }
                            if providers.count > 1 && provider.id == defaultProviderId {
                                return "默认"
                            }
                            return nil
                        }()

                        ComposerModelPopoverRow(
                            provider: provider,
                            badgeText: tag,
                            isSelected: isSelected
                        ) {
                            onSelect(provider)
                        }
                    }
                }
                .padding(.horizontal, 6)

                if providers.count > 5 {
                    ScrollView(.vertical, showsIndicators: true) {
                        listContent
                    }
                    .frame(maxHeight: 264)
                } else {
                    listContent
                }
            }

            Rectangle()
                .fill(Theme.borderSubtle.opacity(0.65))
                .frame(height: 0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            PopoverFooterActionRow(
                icon: "slider.horizontal.3",
                title: "配置模型与授权…",
                action: onOpenSettings
            )
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(width: 292)
        .glassPopover(cornerRadius: 16)
    }
}

private struct ComposerModelPopoverRow: View {
    let provider: ProviderPresetDTO
    let badgeText: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Theme.cardSolid : Theme.surfaceSubtle)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isSelected ? Theme.accentBorder.opacity(0.65) : .clear, lineWidth: 0.7)
                        )
                    Image(systemName: provider.kindIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected || isHovering ? Theme.accentInk : Theme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(provider.displayModelName)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Theme.accentInk : Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let badgeText {
                            Text(badgeText)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(isSelected ? Theme.accentInk : Theme.textTertiary)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? Theme.cardSolid.opacity(0.85) : Theme.surfaceSubtle)
                                )
                        }
                    }

                    Text(provider.name)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Theme.accentInk.opacity(0.75) : Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isSelected {
                    ZStack {
                        Circle()
                            .fill(Theme.accent.opacity(0.18))
                            .frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accentInk)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                        ? Theme.selectionFill
                        : (isHovering ? Theme.hoverFill.opacity(0.75) : .clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentBorder.opacity(0.45) : .clear, lineWidth: 0.65)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct ComposerModePopover: View {
    let selectedMode: ChatMode
    let onSelect: (ChatMode) -> Void
    let onStartInterview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("对话模式")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 11)
                .padding(.bottom, 7)

            VStack(spacing: 3) {
                ForEach(ChatMode.allCases) { mode in
                    ComposerModePopoverRow(
                        mode: mode,
                        isSelected: mode == selectedMode
                    ) {
                        onSelect(mode)
                    }
                }
            }
            .padding(.horizontal, 6)

            Rectangle()
                .fill(Theme.borderSubtle.opacity(0.65))
                .frame(height: 0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            PopoverFooterActionRow(
                icon: "mic.badge.plus",
                title: "让顾问主动发起冷启动访谈…",
                action: onStartInterview
            )
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        .frame(width: 272)
        .glassPopover(cornerRadius: 16)
    }
}

private struct ComposerModePopoverRow: View {
    let mode: ChatMode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Theme.cardSolid : Theme.surfaceSubtle)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isSelected ? Theme.accentBorder.opacity(0.65) : .clear, lineWidth: 0.7)
                        )
                    Image(systemName: mode.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected || isHovering ? Theme.accentInk : Theme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.accentInk : Theme.textPrimary)
                        .lineLimit(1)
                    Text(mode.shortSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Theme.accentInk.opacity(0.75) : Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if isSelected {
                    ZStack {
                        Circle()
                            .fill(Theme.accent.opacity(0.18))
                            .frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accentInk)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                        ? Theme.selectionFill
                        : (isHovering ? Theme.hoverFill.opacity(0.75) : .clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentBorder.opacity(0.45) : .clear, lineWidth: 0.65)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct PopoverFooterActionRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHovering ? Theme.accentInk : Theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isHovering ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovering ? Theme.hoverFill.opacity(0.78) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Context Options Popover

private struct ChatContextOptionsPopover: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        VStack(alignment: .leading, spacing: 0) {
            Text("检索上下文")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.top, 11)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(state.useAsOfDate ? Theme.selectionFill : Theme.surfaceSubtle)
                            .frame(width: 28, height: 28)
                        Image(systemName: state.useAsOfDate ? "calendar.badge.clock" : "calendar")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(state.useAsOfDate ? Theme.accentInk : Theme.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("按历史日期回溯")
                            .font(.system(size: 12.5, weight: .medium))
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

                if state.useAsOfDate {
                    HStack {
                        Text("截止日期")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        DatePicker("", selection: $state.asOfDate, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.surfaceSubtle.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Theme.borderSubtle.opacity(0.65))
                .frame(height: 0.5)
                .padding(.horizontal, 12)

            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state.allowSensitive ? Theme.warningSoft : Theme.surfaceSubtle)
                        .frame(width: 28, height: 28)
                    Image(systemName: state.allowSensitive ? "lock.open" : "lock.shield")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(state.allowSensitive ? Theme.warning : Theme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("本轮允许敏感记忆")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("默认拦截 privacy: sensitive，开启仅本轮放行")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 6)

                Toggle("", isOn: $state.allowSensitive)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(state.allowSensitive ? Theme.warning : Theme.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 312)
        .glassPopover(cornerRadius: 16)
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
                        Text("正在结合你的记忆思考…")
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
