import SwiftUI
import UIKit

// MARK: - 原生自适应多行 UITextView（彻底解决 SwiftUI TextField 在 iOS/中文输入法下的错位与抢回车问题）

final class GrowingChatTextView: UITextView {
    var maxVisibleLines: Int = 6 {
        didSet { syncScrollState() }
    }
    var onCommandReturn: (() -> Void)?

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .placeholderText
        label.isUserInteractionEnabled = false
        label.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var lastLaidOutWidth: CGFloat = 0

    var placeholderText: String = "" {
        didSet {
            if placeholderLabel.text != placeholderText {
                placeholderLabel.text = placeholderText
            }
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        backgroundColor = .clear
        isScrollEnabled = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        keyboardDismissMode = .interactive
        returnKeyType = .default
        textContainerInset = UIEdgeInsets(top: 10, left: 2, bottom: 8, right: 2)
        textContainer.lineFragmentPadding = 4
        adjustsFontForContentSizeCategory = true
        font = .preferredFont(forTextStyle: .body)
        textColor = .label

        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor, constant: textContainerInset.top),
            placeholderLabel.leadingAnchor.constraint(
                equalTo: frameLayoutGuide.leadingAnchor,
                constant: textContainerInset.left + textContainer.lineFragmentPadding
            ),
            placeholderLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: frameLayoutGuide.trailingAnchor,
                constant: -(textContainerInset.right + textContainer.lineFragmentPadding)
            ),
        ])
        placeholderLabel.font = font
    }

    override var font: UIFont? {
        didSet { placeholderLabel.font = font }
    }

    override var text: String! {
        didSet {
            updatePlaceholderVisibility()
            syncScrollState()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let sendCommand = UIKeyCommand(
            input: "\r",
            modifierFlags: .command,
            action: #selector(handleCommandReturn)
        )
        sendCommand.discoverabilityTitle = "发送消息"
        return [sendCommand]
    }

    @objc private func handleCommandReturn() {
        onCommandReturn?()
    }

    func updatePlaceholderVisibility() {
        let shouldHide = !(text ?? "").isEmpty || markedTextRange != nil
        if placeholderLabel.isHidden != shouldHide {
            placeholderLabel.isHidden = shouldHide
        }
    }

    var minContentHeight: CGFloat {
        let lineHeight = font?.lineHeight ?? 21
        return ceil(lineHeight + textContainerInset.top + textContainerInset.bottom)
    }

    var maxContentHeight: CGFloat {
        let lineHeight = font?.lineHeight ?? 21
        return ceil(lineHeight * CGFloat(maxVisibleLines) + textContainerInset.top + textContainerInset.bottom)
    }

    /// 纯计算：在给定宽度下的目标高度，不触发任何布局副作用。
    func clampedContentHeight(forWidth width: CGFloat) -> CGFloat {
        let safeWidth = max(width, 40)
        let fitting = sizeThatFits(CGSize(width: safeWidth, height: .greatestFiniteMagnitude)).height
        return min(max(ceil(fitting), minContentHeight), maxContentHeight)
    }

    func syncScrollState() {
        let width = bounds.width > 1 ? bounds.width : lastLaidOutWidth
        guard width > 1 else { return }
        let fitting = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let shouldScroll = fitting > maxContentHeight + 1
        if isScrollEnabled != shouldScroll {
            isScrollEnabled = shouldScroll
            if !shouldScroll {
                setContentOffset(.zero, animated: false)
            }
        }
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 1 ? bounds.width : (lastLaidOutWidth > 1 ? lastLaidOutWidth : 300)
        return CGSize(width: UIView.noIntrinsicMetric, height: clampedContentHeight(forWidth: width))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastLaidOutWidth) > 0.5 && bounds.width > 1 {
            lastLaidOutWidth = bounds.width
            placeholderLabel.preferredMaxLayoutWidth = max(
                10,
                bounds.width - textContainerInset.left - textContainerInset.right - textContainer.lineFragmentPadding * 2
            )
            syncScrollState()
            invalidateIntrinsicContentSize()
        }
    }
}

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    var maxVisibleLines: Int = 6
    var onCommandReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> GrowingChatTextView {
        let textView = GrowingChatTextView()
        textView.delegate = context.coordinator
        textView.placeholderText = placeholder
        textView.maxVisibleLines = maxVisibleLines
        textView.onCommandReturn = onCommandReturn
        textView.accessibilityLabel = accessibilityLabel
        textView.accessibilityIdentifier = accessibilityIdentifier
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.text = text
        return textView
    }

    func updateUIView(_ uiView: GrowingChatTextView, context: Context) {
        context.coordinator.parent = self
        uiView.placeholderText = placeholder
        uiView.maxVisibleLines = maxVisibleLines
        uiView.onCommandReturn = onCommandReturn
        uiView.accessibilityLabel = accessibilityLabel
        uiView.accessibilityIdentifier = accessibilityIdentifier

        // 清空草稿时（例如刚点发送）强行收尾输入法组合态并复位到单行高度。
        if text.isEmpty && (!(uiView.text ?? "").isEmpty || uiView.markedTextRange != nil) {
            uiView.unmarkText()
            uiView.text = ""
            uiView.isScrollEnabled = false
            uiView.setContentOffset(.zero, animated: false)
            uiView.updatePlaceholderVisibility()
            uiView.invalidateIntrinsicContentSize()
        } else if uiView.markedTextRange == nil && uiView.text != text {
            // 仅在非 IME 组字态下同步外部文本变动（如点击引导语或全屏编辑返回）。
            uiView.text = text
            let end = uiView.endOfDocument
            uiView.selectedTextRange = uiView.textRange(from: end, to: end)
            uiView.updatePlaceholderVisibility()
            uiView.syncScrollState()
            uiView.invalidateIntrinsicContentSize()
        } else {
            uiView.updatePlaceholderVisibility()
        }

        // 异步同步焦点，避免在 SwiftUI 视图更新周期内直接改写 UIResponder 链。
        if isFocused && !uiView.isFirstResponder && uiView.window != nil && !context.coordinator.pendingFocusChange {
            context.coordinator.pendingFocusChange = true
            Task { @MainActor in
                context.coordinator.pendingFocusChange = false
                if context.coordinator.parent.isFocused && !uiView.isFirstResponder && uiView.window != nil {
                    uiView.becomeFirstResponder()
                }
            }
        } else if !isFocused && uiView.isFirstResponder && !context.coordinator.pendingFocusChange {
            context.coordinator.pendingFocusChange = true
            Task { @MainActor in
                context.coordinator.pendingFocusChange = false
                if !context.coordinator.parent.isFocused && uiView.isFirstResponder {
                    uiView.resignFirstResponder()
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GrowingChatTextView, context: Context) -> CGSize? {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite, proposed > 1 {
            width = proposed
        } else if uiView.bounds.width > 1 {
            width = uiView.bounds.width
        } else {
            width = 300
        }
        let height = uiView.clampedContentHeight(forWidth: width)
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        var pendingFocusChange = false

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused {
                parent.isFocused = true
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            let current = textView.text ?? ""
            if parent.text != current {
                parent.text = current
            }
            if let growing = textView as? GrowingChatTextView {
                growing.updatePlaceholderVisibility()
                growing.syncScrollState()
                growing.invalidateIntrinsicContentSize()
                if growing.isScrollEnabled {
                    growing.scrollRangeToVisible(growing.selectedRange)
                }
            }
        }
    }
}

// MARK: - 重新设计的悬浮双层聊天输入框

struct AdvisorComposer: View {
    @ObservedObject var model: AdvisorModel
    @Binding var isFocused: Bool
    var onFocusChanged: (Bool) -> Void = { _ in }

    @State private var showContextSheet = false
    @State private var showExpandedEditor = false

    private var trimmedDraft: String {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !model.isReplying && !trimmedDraft.isEmpty
    }

    private var showExpandAffordance: Bool {
        model.draft.count >= 90 || model.draft.filter({ $0 == "\n" }).count >= 3
    }

    private var hasActiveContextChips: Bool {
        model.useAsOfDate || model.allowSensitive
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if hasActiveContextChips {
                    contextChipsStrip
                }

                // 顶部：全宽自适应多行输入区（仅在底层背景捕获周边空白点击，绝不拦截 UITextView 内光标与选词手势，且不撑开高度）
                ComposerTextView(
                    text: $model.draft,
                    isFocused: $isFocused,
                    placeholder: model.mode.placeholder,
                    accessibilityLabel: "消息输入框",
                    accessibilityIdentifier: "advisor-message",
                    maxVisibleLines: 6,
                    onCommandReturn: handleSend
                )
                .padding(.leading, 14)
                .padding(.trailing, showExpandAffordance ? 42 : 14)
                .padding(.top, hasActiveContextChips ? 2 : 6)
                .padding(.bottom, 2)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isFocused { isFocused = true }
                        }
                }
                .overlay(alignment: .topTrailing) {
                    if showExpandAffordance {
                        Button {
                            isFocused = false
                            showExpandedEditor = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AdvisorTheme.secondaryInk)
                                .frame(width: 28, height: 28)
                                .background(AdvisorTheme.chipFill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 10)
                        .padding(.trailing, 10)
                        .accessibilityLabel("全屏编辑草稿")
                        .transition(.scale.combined(with: .opacity))
                    }
                }

                // 底部：紧凑工具栏（上下文菜单 · 对话模式 · 提炼记忆 · 收起键盘 · 发送/停止）
                HStack(spacing: 6) {
                    toolsMenuButton
                    modeMenuPill

                    if !model.messages.isEmpty {
                        extractChip
                    }

                    Spacer(minLength: 4)

                    if isFocused {
                        Button {
                            isFocused = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(AdvisorTheme.secondaryInk)
                                .frame(width: 34, height: 34)
                                .background(AdvisorTheme.chipFill.opacity(0.85), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("收起键盘")
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }

                    primaryActionButton
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
            .floatingComposerSurface(cornerRadius: 24, isFocused: isFocused)
            .frame(maxWidth: AdvisorTheme.contentWidth)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, isFocused ? 8 : 6)
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.22), value: isFocused)
        .animation(.snappy(duration: 0.2), value: showExpandAffordance)
        .animation(.snappy(duration: 0.2), value: hasActiveContextChips)
        .onChange(of: isFocused) { _, focused in
            onFocusChanged(focused)
        }
        .sheet(isPresented: $showContextSheet) {
            ContextOptionsSheet(model: model)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showExpandedEditor) {
            ExpandedDraftSheet(model: model, onSend: {
                showExpandedEditor = false
                handleSend()
            })
        }
    }

    // MARK: - Subviews

    private var contextChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if model.useAsOfDate {
                    activeContextChip(
                        icon: "calendar.badge.clock",
                        title: "回溯 \(model.formattedAsOf)",
                        tint: AdvisorTheme.accentInk,
                        background: AdvisorTheme.accentSoft,
                        onTap: { showContextSheet = true },
                        onClear: { model.useAsOfDate = false }
                    )
                }
                if model.allowSensitive {
                    activeContextChip(
                        icon: "lock.open",
                        title: "本轮含敏感记忆",
                        tint: AdvisorTheme.warning,
                        background: AdvisorTheme.warningSoft,
                        onTap: { showContextSheet = true },
                        onClear: { model.allowSensitive = false }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    private func activeContextChip(
        icon: String,
        title: String,
        tint: Color,
        background: Color,
        onTap: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 5) {
            Button(action: onTap) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.plain)

            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭\(title)")
        }
        .foregroundStyle(tint)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(background, in: Capsule())
    }

    private var toolsMenuButton: some View {
        Menu {
            Button {
                isFocused = false
                showContextSheet = true
            } label: {
                Label(
                    model.useAsOfDate ? "历史回溯：\(model.formattedAsOf)" : "按历史日期回溯…",
                    systemImage: "calendar.badge.clock"
                )
            }

            Button {
                model.allowSensitive.toggle()
            } label: {
                Label(
                    model.allowSensitive ? "关闭本轮敏感记忆" : "本轮允许敏感记忆",
                    systemImage: model.allowSensitive ? "lock.shield" : "lock.open"
                )
            }

            Divider()

            Button {
                isFocused = false
                showExpandedEditor = true
            } label: {
                Label("全屏长文编辑", systemImage: "arrow.up.left.and.arrow.down.right")
            }

            if !trimmedDraft.isEmpty {
                Button {
                    isFocused = false
                    Task { await model.saveDraftToInbox() }
                } label: {
                    Label("顺手存入收件箱速记", systemImage: "tray.and.arrow.down")
                }

                Button(role: .destructive) {
                    model.draft = ""
                } label: {
                    Label("清空当前草稿", systemImage: "trash")
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hasActiveContextChips ? AdvisorTheme.accentInk : AdvisorTheme.secondaryInk)
                    .frame(width: 34, height: 34)
                    .background(
                        hasActiveContextChips ? AdvisorTheme.accentSoft : AdvisorTheme.chipFill,
                        in: Circle()
                    )

                if hasActiveContextChips {
                    Circle()
                        .fill(AdvisorTheme.accent)
                        .frame(width: 7, height: 7)
                        .offset(x: -1, y: 1)
                }
            }
        }
        .accessibilityLabel("更多上下文与输入工具")
    }

    private var modeMenuPill: some View {
        Menu {
            Picker("对话模式", selection: Binding(get: { model.mode }, set: model.changeMode)) {
                ForEach(ChatMode.allCases) { item in
                    Label(item.label, systemImage: item.icon).tag(item)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.mode.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AdvisorTheme.accentInk)
                Text(model.mode.shortLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdvisorTheme.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AdvisorTheme.tertiaryInk)
            }
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(AdvisorTheme.chipFill, in: Capsule())
        }
        .accessibilityLabel("对话模式：\(model.mode.label)")
    }

    private var extractChip: some View {
        Button {
            isFocused = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { await model.extract() }
        } label: {
            HStack(spacing: 4) {
                if model.extracting {
                    ProgressView()
                        .controlSize(.mini)
                    Text("提炼中")
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                    Text("提炼")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(model.canExtractMemories ? AdvisorTheme.accentInk : AdvisorTheme.tertiaryInk)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(
                model.canExtractMemories ? AdvisorTheme.accentSoft : AdvisorTheme.chipFill.opacity(0.6),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.canExtractMemories)
        .accessibilityLabel("从当前对话提炼记忆")
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if model.isReplying {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                model.stopReplying()
            } label: {
                ZStack {
                    Circle()
                        .fill(AdvisorTheme.ink)
                        .frame(width: 34, height: 34)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AdvisorTheme.paper)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("停止生成")
            .accessibilityIdentifier("advisor-stop")
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else {
            Button(action: handleSend) {
                ZStack {
                    Circle()
                        .fill(canSend ? AdvisorTheme.accent : AdvisorTheme.chipFill)
                        .frame(width: 34, height: 34)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(canSend ? AdvisorTheme.onAccent : AdvisorTheme.tertiaryInk)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .scaleEffect(canSend ? 1.0 : 0.96)
            .animation(.snappy(duration: 0.16), value: canSend)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("advisor-send")
        }
    }

    private func handleSend() {
        guard canSend else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        isFocused = false
        Task { await model.send() }
    }
}

// MARK: - 检索上下文选项弹窗

private struct ContextOptionsSheet: View {
    @ObservedObject var model: AdvisorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $model.useAsOfDate) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("按历史日期回溯")
                            Text("仅检索该日期之前的记忆，还原当时视角")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.useAsOfDate {
                        DatePicker(
                            "截止日期",
                            selection: $model.asOfDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                    }
                } header: {
                    Text("双时间轴检索")
                }

                Section {
                    Toggle(isOn: $model.allowSensitive) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本轮允许敏感记忆")
                            Text("默认拦截 privacy: sensitive 记忆，开启后仅放行你主动勾选的轮次")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(AdvisorTheme.warning)
                } header: {
                    Text("隐私防火墙")
                }
            }
            .navigationTitle("对话上下文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 全屏长文草稿编辑弹窗

private struct ExpandedDraftSheet: View {
    @ObservedObject var model: AdvisorModel
    let onSend: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    private var trimmed: String {
        model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Label(model.mode.label, systemImage: model.mode.icon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AdvisorTheme.accentInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(AdvisorTheme.accentSoft, in: Capsule())

                    Spacer()

                    Text("\(model.draft.count) 字")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                TextEditor(text: $model.draft)
                    .font(.body)
                    .focused($editorFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .accessibilityLabel("长文消息编辑")
            }
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("收起") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("存速记") {
                        dismiss()
                        Task { await model.saveDraftToInbox() }
                    }
                    .disabled(trimmed.isEmpty)

                    Button("发送") {
                        onSend()
                    }
                    .fontWeight(.semibold)
                    .disabled(trimmed.isEmpty || model.isReplying)
                }
            }
            .onAppear {
                editorFocused = true
            }
        }
    }
}
