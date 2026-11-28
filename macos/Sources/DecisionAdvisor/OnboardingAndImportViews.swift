import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Three-in-One Onboarding Sheet ("认识我" 初始化向导)

struct OnboardingSheetView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    enum Route: String {
        case hub
        case quick
        case importMemory
    }

    @State private var route: Route = .hub
    @State private var quickStep: Int = 0

    // Quick Profile Form Draft
    @State private var preferredName: String = ""
    @State private var lifeStage: String = ""
    @State private var currentFocus: String = ""
    @State private var selectedValues: [String] = []
    @State private var valuesNote: String = ""
    @State private var boundariesText: String = ""
    @State private var patternsText: String = ""
    @State private var goalsText: String = ""
    @State private var advisorStyle: String = "balanced"
    @State private var advisorStyleNote: String = ""

    private let valuePresets: [String] = [
        "自主权", "健康", "长期成长", "真实",
        "财务安全", "自由", "深度关系", "创造力",
        "家庭", "平静", "掌控感", "影响力",
    ]

    private var styleOptions: [AdvisorStyleOptionDTO] {
        state.onboardingStatus?.advisorStyles ?? [
            AdvisorStyleOptionDTO(id: "direct_critic", label: "直率泼冷水", description: "少客套，直接指出盲区、自欺与隐性代价，给我清醒的反方视角。"),
            AdvisorStyleOptionDTO(id: "balanced", label: "理性均衡", description: "先接住真实感受，再冷静拆解事实、利弊与反方观点，保持克制清醒。"),
            AdvisorStyleOptionDTO(id: "warm_gentle", label: "温和陪伴", description: "语气更温和细腻、循序渐进，在尊重情绪节奏的前提下温和提醒风险。"),
        ]
    }

    private var hasAnyQuickInput: Bool {
        !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !lifeStage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !currentFocus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedValues.isEmpty
            || !valuesNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !boundariesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !patternsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !goalsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !advisorStyleNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var plannedQuickFiles: [String] {
        var out: [String] = []
        if !preferredName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !lifeStage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !currentFocus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !advisorStyle.isEmpty {
            out.append("00-核心自我/identity.md（基本画像与沟通风格）")
        }
        if !selectedValues.isEmpty || !valuesNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("00-核心自我/values.md（核心价值观）")
        }
        if !boundariesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("00-核心自我/boundaries.md（红线与底线）")
        }
        if !patternsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("00-核心自我/patterns.md（情绪与决策模式）")
        }
        if !goalsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("00-核心自我/goals.md（当下课题与目标）")
        }
        return out
    }

    private func buildQuickPayload(commit: Bool) -> QuickProfilePayload {
        QuickProfilePayload(
            preferredName: preferredName,
            lifeStage: lifeStage,
            currentFocus: currentFocus,
            coreValues: selectedValues,
            valuesNote: valuesNote,
            boundaries: boundariesText,
            patterns: patternsText,
            goals: goalsText,
            advisorStyle: advisorStyle,
            advisorStyleNote: advisorStyleNote,
            commit: commit
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            Group {
                switch route {
                case .hub:
                    hubView
                case .quick:
                    quickProfileView
                case .importMemory:
                    MemoryImportWorkspace(isEmbedded: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvasBg)
        }
        .frame(width: 800, height: 640)
        .background(Theme.canvasBg)
        .tint(Theme.accent)
        .onAppear {
            switch state.onboardingInitialRoute {
            case "quick": route = .quick
            case "import": route = .importMemory
            default: route = .hub
            }
            Task {
                await state.refreshOnboardingStatus(autoPresent: false)
                await state.ensureImportPromptsLoaded()
            }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            if route != .hub {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        route = .hub
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("返回选择")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                }
                .buttonStyle(SubtleOutlineButtonStyle(compact: true))
            } else {
                CompassEmblem(size: 32)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(headerSubtitle)
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
        .padding(.vertical, 14)
        .background(Theme.canvasBg)
    }

    private var headerTitle: String {
        switch route {
        case .hub: return "让顾问先真正认识你"
        case .quick: return "3 分钟快速建立核心自我"
        case .importMemory: return "导入其他 Agent 的记忆"
        }
    }

    private var headerSubtitle: String {
        switch route {
        case .hub: return "选择任意一种最轻松的方式初始化个人记忆库，后续也可随时补充或迭代"
        case .quick: return "填完自动生成纯 Markdown 核心档案（已有内容会安全融合，不会覆盖）"
        case .importMemory: return "支持 ChatGPT / Claude / Gemini / DeepSeek 提示词复制、官方导出与通用记忆 JSON"
        }
    }

    // MARK: Route 0 — Welcome Hub

    private var hubView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let status = state.onboardingStatus {
                        CoreSelfProgressBanner(status: status) { slot in
                            Task { await state.startGuidedInterview(focusSlot: slot.id) }
                        }
                    }

                    VStack(spacing: 12) {
                        OnboardingPathCard(
                            icon: "bolt.fill",
                            badge: "推荐 · 约 3 分钟",
                            title: "3 分钟快速建立个人画像",
                            subtitle: "用 4 步轻量卡片填好称呼、核心价值观、底线、情绪惯性与希望顾问的说话风格，立刻让 9 步决策和日常对话贴合你本人。",
                            actionLabel: "开始填写"
                        ) {
                            quickStep = 0
                            withAnimation(.easeInOut(duration: 0.18)) { route = .quick }
                        }

                        OnboardingPathCard(
                            icon: "square.and.arrow.down.on.square",
                            badge: "零冷启动迁移",
                            title: "导入其他 Agent 的记忆",
                            subtitle: "不想从头讲一遍人生？复制内置提示词让 ChatGPT / Claude / Gemini 吐出对你的记忆，或直接拖入官方导出 JSON/ZIP、Mem0 / PAM 记忆文件，提炼审阅 Diff 后一键入库。",
                            actionLabel: "开始导入"
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) { route = .importMemory }
                        }

                        OnboardingPathCard(
                            icon: "mic.fill",
                            badge: "零压力聊天建库",
                            title: "1 对 1 冷启动深度访谈",
                            subtitle: "不爱填表？直接让顾问先开口，围绕你目前空白的核心维度每次只问 1～2 个温和、有画面感的问题，聊完点一下「提炼记忆」即可入库。",
                            actionLabel: state.isStartingInterview ? "开启中…" : "让顾问先开口",
                            isBusy: state.isStartingInterview
                        ) {
                            Task { await state.startGuidedInterview(focusSlot: nil) }
                        }
                    }
                }
                .padding(22)
            }

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.accent)
                    Text("纯 Markdown 记忆库 · 所有 AI 提炼均需你确认 Diff 后才落盘")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer()

                if state.onboardingStatus?.completed == true {
                    Button("关闭") { dismiss() }
                        .buttonStyle(SubtleOutlineButtonStyle())
                } else {
                    Button("稍后再说") {
                        Task { await state.dismissOnboarding() }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(Theme.sidebarBg.opacity(0.65))
        }
    }

    // MARK: Route 1 — Quick Profile 4-Step Wizard

    private var quickProfileView: some View {
        VStack(spacing: 0) {
            // Stepper Header
            HStack(spacing: 8) {
                ForEach(Array(["1. 基本画像", "2. 价值观与底线", "3. 模式与课题", "4. 沟通风格"].enumerated()), id: \.offset) { idx, label in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) { quickStep = idx }
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(idx <= quickStep ? Theme.accent : Theme.borderStrong)
                                .frame(width: 6, height: 6)
                            Text(label)
                                .font(.system(size: 12, weight: idx == quickStep ? .semibold : .medium))
                                .foregroundStyle(idx == quickStep ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(idx == quickStep ? Theme.selectionFill : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Theme.sidebarBg.opacity(0.45))

            Rectangle().fill(Theme.borderSubtle.opacity(0.7)).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch quickStep {
                    case 0:
                        quickStepIdentity
                    case 1:
                        quickStepValuesAndBoundaries
                    case 2:
                        quickStepPatternsAndGoals
                    default:
                        quickStepStyleAndReview
                    }
                }
                .padding(22)
            }

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            HStack(spacing: 10) {
                if quickStep > 0 {
                    Button("上一步") {
                        withAnimation(.easeInOut(duration: 0.16)) { quickStep -= 1 }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                }

                Spacer()

                if quickStep < 3 {
                    Button("跳过这一步") {
                        withAnimation(.easeInOut(duration: 0.16)) { quickStep += 1 }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())

                    Button("下一步") {
                        withAnimation(.easeInOut(duration: 0.16)) { quickStep += 1 }
                    }
                    .buttonStyle(SprucePrimaryButtonStyle())
                } else {
                    Button("预览 Diff 后确认") {
                        Task { _ = await state.submitQuickProfile(buildQuickPayload(commit: false), commit: false) }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                    .disabled(state.isSubmittingQuickProfile || !hasAnyQuickInput)

                    Button {
                        Task { _ = await state.submitQuickProfile(buildQuickPayload(commit: true), commit: true) }
                    } label: {
                        if state.isSubmittingQuickProfile {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("建档中…")
                            }
                        } else {
                            Label("确认建档并写入", systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(SprucePrimaryButtonStyle())
                    .disabled(state.isSubmittingQuickProfile || !hasAnyQuickInput)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(Theme.sidebarBg.opacity(0.65))
        }
    }

    private var quickStepIdentity: some View {
        VStack(alignment: .leading, spacing: 16) {
            WizardField(title: "希望顾问平时怎么称呼你？", hint: "名字、昵称或英文名都可以") {
                TextField("例如：阿明 / Sakura", text: $preferredName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .padding(10)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.borderSubtle, lineWidth: 0.8))
            }

            WizardField(title: "你现在的职业、角色或所处的人生阶段", hint: "让顾问理解你的现实语境，不做脱离实际的建议") {
                TextField("例如：互联网产品经理第 5 年，正在思考是否转独立开发 / 刚组建家庭", text: $lifeStage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .padding(10)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.borderSubtle, lineWidth: 0.8))
            }

            WizardField(title: "最近生活和工作里最占精力的重心是什么？", hint: "选填，一两句话即可") {
                WizardTextArea(
                    text: $currentFocus,
                    placeholder: "例如：主业节奏很紧，同时晚上在做自己的小产品，精力经常不够用…"
                )
            }
        }
    }

    private var quickStepValuesAndBoundaries: some View {
        VStack(alignment: .leading, spacing: 18) {
            WizardField(title: "做重要选择时，你最看重的价值观（可多选）", hint: "9 步决策会用它们做「价值观体检」") {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(valuePresets, id: \.self) { val in
                        let isSelected = selectedValues.contains(val)
                        Button {
                            if isSelected {
                                selectedValues.removeAll { $0 == val }
                            } else {
                                selectedValues.append(val)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                Text(val)
                                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            }
                            .foregroundStyle(isSelected ? Theme.accentInk : Theme.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(isSelected ? Theme.selectionFill : Theme.surfaceSubtle)
                            )
                            .overlay(
                                Capsule().strokeBorder(isSelected ? Theme.accent : Theme.borderSubtle, lineWidth: isSelected ? 1.1 : 0.7)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            WizardField(title: "价值观补充说明（选填）", hint: "例如哪些原则高于短期收益") {
                WizardTextArea(
                    text: $valuesNote,
                    placeholder: "例如：宁愿少赚 20%，也不想牺牲自主权和睡眠健康…",
                    minHeight: 68
                )
            }

            WizardField(title: "明确拒绝的红线与底线", hint: "什么事一旦踩线会让你极度内耗或事后后悔？") {
                WizardTextArea(
                    text: $boundariesText,
                    placeholder: "例如：不接受长期失控加班、不和缺乏基本尊重的人共事、不在情绪上头时当晚拍板大决定…",
                    minHeight: 80
                )
            }
        }
    }

    private var quickStepPatternsAndGoals: some View {
        VStack(alignment: .leading, spacing: 18) {
            WizardField(title: "你的情绪与决策惯性（高压/犹豫时常见反应）", hint: "帮顾问在关键时刻提前提醒你的盲区") {
                WizardTextArea(
                    text: $patternsText,
                    placeholder: "例如：一焦虑就容易过度搜集信息拖延；被他人期待推着走时容易勉强答应；独处散步和写下来最能帮我恢复能量…",
                    minHeight: 96
                )
            }

            WizardField(title: "未来 6～12 个月最想推进的目标或正在纠结的课题", hint: "让顾问知道你当下最重要的主线") {
                WizardTextArea(
                    text: $goalsText,
                    placeholder: "例如：1. 把副业跑通第一批真实付费用户；2. 决定今年底是否换城市生活；3. 建立规律运动习惯…",
                    minHeight: 96
                )
            }
        }
    }

    private var quickStepStyleAndReview: some View {
        VStack(alignment: .leading, spacing: 18) {
            WizardField(title: "你希望顾问平时怎么和你说话？", hint: "写入 identity.md，每次对话自动生效") {
                VStack(spacing: 9) {
                    ForEach(styleOptions) { opt in
                        let isSelected = advisorStyle == opt.id
                        Button {
                            advisorStyle = opt.id
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                                    .padding(.top, 1)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(opt.label)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(Theme.textPrimary)
                                    Text(opt.description)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .glassCard(cornerRadius: 12, isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            WizardField(title: "其他沟通约定（选填）", hint: "例如“结论先行、不要说教、多举我自己的历史例子”") {
                TextField("例如：先说核心判断，再展开分析，别给我灌鸡汤", text: $advisorStyleNote)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.borderSubtle, lineWidth: 0.8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("本次将写入/融合的核心自我文件")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                if plannedQuickFiles.isEmpty {
                    Text("你还没有填写任何内容，请返回前面步骤至少填一项。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                } else {
                    ForEach(plannedQuickFiles, id: \.self) { fileDesc in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                            Text(fileDesc)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceSubtle.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - Standalone Cross-Agent Memory Import Sheet

struct MemoryImportSheetView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accentSoft)
                        .frame(width: 34, height: 34)
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("导入其他 Agent 的记忆")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("先本地解析预览（零额度消耗），筛选后由大模型去重提炼为提案，经你确认 Diff 再写入")
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
            .padding(.vertical, 14)
            .background(Theme.canvasBg)

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            MemoryImportWorkspace(isEmbedded: false)
        }
        .frame(width: 820, height: 650)
        .background(Theme.canvasBg)
        .tint(Theme.accent)
        .onAppear {
            Task { await state.ensureImportPromptsLoaded() }
        }
    }
}

// MARK: - Reusable Cross-Agent Memory Import Workspace

private enum ImportChannel: String, CaseIterable, Identifiable {
    case paste = "粘贴 AI 记忆"
    case officialExport = "ChatGPT / Claude 导出"
    case genericJson = "通用记忆 JSON"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .paste: return "doc.on.clipboard"
        case .officialExport: return "archivebox"
        case .genericJson: return "curlybraces"
        }
    }
}

private struct StagedImportFile: Identifiable {
    let id = UUID()
    let name: String
    let data: Data

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

struct MemoryImportWorkspace: View {
    @Environment(AppState.self) private var state
    let isEmbedded: Bool

    @State private var channel: ImportChannel = .paste
    @State private var selectedPromptIdx: Int = 0
    @State private var copiedPrompt: Bool = false
    @State private var pastedText: String = ""
    @State private var genericJsonText: String = ""
    @State private var stagedFiles: [StagedImportFile] = []
    @State private var isDropTargeted: Bool = false
    @State private var parseError: String? = nil

    // Phase 2: Local preview & selection
    @State private var previewResult: ImportPreviewResponse? = nil
    @State private var editableItems: [ImportChunkDTO] = []

    private var promptTemplates: [ImportPromptTemplateDTO] {
        if !state.importPromptTemplates.isEmpty {
            return state.importPromptTemplates
        }
        return [
            ImportPromptTemplateDTO(
                id: "universal_full",
                title: "完整画像迁移提示词（全平台通用）",
                subtitle: "适用于 ChatGPT、Claude、Gemini、DeepSeek、豆包等任意对话 AI",
                prompt: "请把我过去与你对话里、以及你「记忆/自定义指令」中记住的关于我的一切重要信息，整理成一份简洁客观的 Markdown 个人档案，按以下 6 项输出（无记录写暂无，严禁编造）：1. 我是谁与当下阶段 2. 核心价值观与红线底线 3. 性格、情绪与决策模式 4. 重要人物与关系 5. 关键经历与过往决策 6. 当下课题与目标。请勿包含密码或绝密凭据。"
            ),
        ]
    }

    private var activePrompt: ImportPromptTemplateDTO {
        promptTemplates[min(selectedPromptIdx, max(0, promptTemplates.count - 1))]
    }

    private var selectedItems: [ImportChunkDTO] {
        editableItems.filter(\.selected)
    }

    private var selectedChars: Int {
        selectedItems.reduce(0) { $0 + $1.charCount }
    }

    private var canPreview: Bool {
        switch channel {
        case .paste:
            return !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .officialExport:
            return !stagedFiles.isEmpty
        case .genericJson:
            return !stagedFiles.isEmpty || !genericJsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        if let preview = previewResult {
            previewSelectionPhase(preview)
        } else {
            inputPhase
        }
    }

    // MARK: Phase 1 — Input

    private var inputPhase: some View {
        VStack(spacing: 0) {
            HStack {
                UnifiedSegmentedControl(
                    options: ImportChannel.allCases,
                    selection: $channel,
                    label: { $0.rawValue },
                    icon: { $0.icon }
                )
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.sidebarBg.opacity(0.4))

            Rectangle().fill(Theme.borderSubtle.opacity(0.7)).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch channel {
                    case .paste:
                        pasteChannelView
                    case .officialExport:
                        officialExportChannelView
                    case .genericJson:
                        genericJsonChannelView
                    }

                    if let err = parseError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.danger)
                            Text(err)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.danger)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(20)
            }

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            HStack {
                Text("第一步：先做纯本地解析与个人相关性筛选（不消耗大模型额度）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    Task { await runPreview() }
                } label: {
                    if state.isPreviewingImport {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("解析中…")
                        }
                    } else {
                        Label("解析并预览内容", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(SprucePrimaryButtonStyle())
                .disabled(!canPreview || state.isPreviewingImport)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(Theme.sidebarBg.opacity(0.65))
        }
    }

    private var pasteChannelView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Prompt export helper card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("步骤 1：复制提取提示词发给旧 AI")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(activePrompt.subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()

                    if promptTemplates.count > 1 {
                        HStack(spacing: 4) {
                            ForEach(Array(promptTemplates.enumerated()), id: \.offset) { idx, tpl in
                                Button(idx == 0 ? "完整版" : "精简版") {
                                    selectedPromptIdx = idx
                                }
                                .font(.system(size: 11.5, weight: selectedPromptIdx == idx ? .semibold : .medium))
                                .foregroundStyle(selectedPromptIdx == idx ? Theme.accentInk : Theme.textSecondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(selectedPromptIdx == idx ? Theme.selectionFill : Theme.surfaceSubtle)
                                )
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(activePrompt.prompt, forType: .string)
                        copiedPrompt = true
                        state.showBanner("已复制迁移提示词，直接发给 ChatGPT / Claude / Gemini 即可")
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copiedPrompt = false
                        }
                    } label: {
                        Label(copiedPrompt ? "已复制" : "复制提示词", systemImage: copiedPrompt ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(SubtleOutlineButtonStyle(compact: true, isActive: copiedPrompt))
                }

                Text(activePrompt.prompt)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)
                    .lineLimit(5)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(14)
            .glassCard(cornerRadius: 14)

            WizardField(title: "步骤 2：把旧 AI 的回复粘贴到这里", hint: "也可以直接粘贴任意自我介绍、ChatGPT 记忆清单或 Markdown 个人档案") {
                WizardTextArea(
                    text: $pastedText,
                    placeholder: "在此粘贴 ChatGPT / Claude / Gemini / DeepSeek 导出的个人记忆内容…",
                    minHeight: 190
                )
            }
        }
    }

    private var officialExportChannelView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ExportHintMiniCard(
                    title: "ChatGPT 官方导出",
                    steps: "设置 → 数据控制 → 导出数据，上传收到的 .zip 或解压后的 conversations.json"
                )
                ExportHintMiniCard(
                    title: "Claude 官方导出",
                    steps: "设置 → 隐私 → 导出数据，上传 .zip 或里面的 memories.json / conversations.json"
                )
            }

            fileDropZone(
                title: "拖入 ChatGPT / Claude 导出的 .zip 或 .json 文件",
                subtitle: "自动过滤低价值代码报错/翻译问答，优先精选高个人相关性对话与官方记忆",
                allowedExtensions: ["json", "zip"]
            )

            stagedFilesList
        }
    }

    private var genericJsonChannelView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("兼容多种通用 Agent 记忆格式")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("自动识别 Mem0（results/memory）、Portable AI Memory (PAM)、Letta / MemGPT（core_memory/blocks）、通用记忆数组 JSON，也兼容 .md / .txt 档案文件。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceSubtle.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            fileDropZone(
                title: "选择或拖入记忆文件（.json / .zip / .md / .txt）",
                subtitle: "支持一次拖入多个文件",
                allowedExtensions: ["json", "zip", "md", "txt"]
            )

            stagedFilesList

            WizardField(title: "或者直接粘贴 JSON 内容（选填）", hint: "粘贴 Mem0 / PAM / 自定义记忆 JSON 后可直接解析") {
                WizardTextArea(
                    text: $genericJsonText,
                    placeholder: "{\"memories\": [{\"content\": \"...\"}]} 或 [{\"memory\": \"...\"}]",
                    minHeight: 110
                )
            }
        }
    }

    private func fileDropZone(title: String, subtitle: String, allowedExtensions: [String]) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(isDropTargeted ? Theme.accentInk : Theme.accent)

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button("选择本地文件…") {
                pickFiles(allowedExtensions: allowedExtensions)
            }
            .buttonStyle(SubtleOutlineButtonStyle(compact: true))
            .padding(.top, 2)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDropTargeted ? Theme.selectionFill : Theme.codeBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Theme.accent : Theme.borderStrong.opacity(0.7),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 1.5 : 1, dash: [6, 4])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            loadFileURLs(urls, allowedExtensions: allowedExtensions)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    @ViewBuilder
    private var stagedFilesList: some View {
        if !stagedFiles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("已添加 \(stagedFiles.count) 个文件")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("清空") { stagedFiles.removeAll() }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .buttonStyle(.plain)
                }

                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(stagedFiles) { f in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                            Text(f.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(f.sizeText)
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                            Button {
                                stagedFiles.removeAll { $0.id == f.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.cardSolid, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.borderSubtle, lineWidth: 0.8))
                    }
                }
            }
        }
    }

    // MARK: Phase 2 — Local Preview & Selection

    private func previewSelectionPhase(_ preview: ImportPreviewResponse) -> some View {
        VStack(spacing: 0) {
            // Top summary strip
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            previewResult = nil
                            editableItems = []
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("重选素材")
                        }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle(compact: true))

                    Text(preview.detectedLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Theme.selectionFill, in: Capsule())

                    Spacer()

                    Button("仅选推荐") {
                        for idx in editableItems.indices {
                            editableItems[idx].selected = editableItems[idx].recommended
                        }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle(compact: true))

                    Button("全选") {
                        for idx in editableItems.indices { editableItems[idx].selected = true }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle(compact: true))

                    Button("全不选") {
                        for idx in editableItems.indices { editableItems[idx].selected = false }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                }

                Text(preview.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)

                ForEach(preview.warnings, id: \.self) { warn in
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warning)
                        Text(warn)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.sidebarBg.opacity(0.45))

            Rectangle().fill(Theme.borderSubtle.opacity(0.7)).frame(height: 0.5)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($editableItems) { $chunk in
                        ImportChunkRow(chunk: $chunk)
                    }
                }
                .padding(18)
            }

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            HStack {
                Text("已勾选 \(selectedItems.count) / \(editableItems.count) 条片段（约 \(selectedChars) 字）")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                Button {
                    Task {
                        _ = await state.extractAgentImport(
                            items: selectedItems,
                            sourceLabel: preview.detectedLabel
                        )
                    }
                } label: {
                    if state.isExtractingImport {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("大模型提炼去重中…")
                        }
                    } else {
                        Label("提炼为记忆提案 (\(selectedItems.count))", systemImage: "sparkles")
                    }
                }
                .buttonStyle(SprucePrimaryButtonStyle())
                .disabled(selectedItems.isEmpty || state.isExtractingImport)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(Theme.sidebarBg.opacity(0.65))
        }
    }

    // MARK: Actions

    private func pickFiles(allowedExtensions: [String]) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            loadFileURLs(panel.urls, allowedExtensions: allowedExtensions)
        }
    }

    private func loadFileURLs(_ urls: [URL], allowedExtensions: [String]) {
        parseError = nil
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if !allowedExtensions.isEmpty && !allowedExtensions.contains(ext) {
                parseError = "不支持的文件类型：\(url.lastPathComponent)"
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                if data.count > 25 * 1024 * 1024 {
                    parseError = "\(url.lastPathComponent) 超过 25MB，请先解压后选择核心 JSON 文件"
                    continue
                }
                if !stagedFiles.contains(where: { $0.name == url.lastPathComponent && $0.data.count == data.count }) {
                    stagedFiles.append(StagedImportFile(name: url.lastPathComponent, data: data))
                }
            } catch {
                parseError = "无法读取 \(url.lastPathComponent)：\(error.localizedDescription)"
            }
        }
    }

    private func runPreview() async {
        parseError = nil
        let rawText: String
        let filesToSend: [(name: String, data: Data)]
        let hint: String

        switch channel {
        case .paste:
            rawText = pastedText
            filesToSend = []
            hint = "prompt_paste"
        case .officialExport:
            rawText = ""
            filesToSend = stagedFiles.map { ($0.name, $0.data) }
            hint = "official_export"
        case .genericJson:
            rawText = genericJsonText
            filesToSend = stagedFiles.map { ($0.name, $0.data) }
            hint = "generic_json"
        }

        do {
            let res = try await state.previewAgentImport(rawText: rawText, files: filesToSend, sourceHint: hint)
            if res.items.isEmpty {
                parseError = res.warnings.first ?? res.summary
                return
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                previewResult = res
                editableItems = res.items
            }
        } catch {
            parseError = "解析失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Reusable Subcomponents

struct CoreSelfProgressBanner: View {
    let status: OnboardingStatusDTO
    let onTapSlot: (OnboardingSlotDTO) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("核心自我档案完整度")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("已建立 \(status.readyCount)/\(status.totalSlots) 项核心档案 · 另有 \(status.nonCoreMemories) 篇历史记忆")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text("\(status.completeness)%")
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(status.completeness >= 60 ? Theme.success : Theme.accentInk)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceSubtle)
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: max(8, geo.size.width * CGFloat(status.completeness) / 100.0))
                }
            }
            .frame(height: 6)

            FlowLayout(spacing: 7, lineSpacing: 7) {
                ForEach(status.slots) { slot in
                    Button {
                        onTapSlot(slot)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: slotIcon(slot.status))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(slotColor(slot.status))
                            Text(slot.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(slot.status == "ready" ? Theme.textPrimary : Theme.textSecondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(
                            Capsule().fill(slot.status == "ready" ? Theme.selectionFill : Theme.surfaceSubtle.opacity(0.85))
                        )
                        .overlay(
                            Capsule().strokeBorder(slot.status == "ready" ? Theme.accentBorder : Theme.borderSubtle, lineWidth: 0.7)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(slot.status == "ready" ? "已建立：\(slot.excerpt)" : "点击针对「\(slot.title)」开启 1 对 1 访谈")
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 14)
    }

    private func slotIcon(_ status: String) -> String {
        switch status {
        case "ready": return "checkmark.circle.fill"
        case "partial": return "circle.lefthalf.filled"
        default: return "circle.dashed"
        }
    }

    private func slotColor(_ status: String) -> Color {
        switch status {
        case "ready": return Theme.success
        case "partial": return Theme.warning
        default: return Theme.textTertiary
        }
    }
}

private struct OnboardingPathCard: View {
    let icon: String
    let badge: String
    let title: String
    let subtitle: String
    let actionLabel: String
    var isBusy: Bool = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                ColorIconTile(systemName: icon, color: Theme.accent, size: 40)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(badge)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.selectionFill, in: Capsule())
                    }
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2.5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(actionLabel)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.accentInk)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Theme.selectionFill, in: Capsule())
            }
            .padding(16)
            .glassCard(cornerRadius: 15, isHovering: isHovering)
            .offset(y: isHovering ? -1 : 0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { isHovering = $0 }
    }
}

private struct ExportHintMiniCard: View {
    let title: String
    let steps: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(steps)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceSubtle.opacity(0.65), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct ImportChunkRow: View {
    @Binding var chunk: ImportChunkDTO

    var body: some View {
        Button {
            chunk.selected.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: chunk.selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(chunk.selected ? Theme.accent : Theme.textTertiary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(chunk.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)

                        if chunk.recommended {
                            Text("推荐")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.success)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Theme.successSoft, in: Capsule())
                        }

                        Spacer()

                        if !chunk.date.isEmpty {
                            Text(chunk.date)
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }

                        Text("\(chunk.charCount) 字")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }

                    Text(chunk.preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .glassCard(cornerRadius: 12, isSelected: chunk.selected)
            .opacity(chunk.selected ? 1.0 : 0.72)
        }
        .buttonStyle(.plain)
    }
}

private struct WizardField<Content: View>: View {
    let title: String
    let hint: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            content()
        }
    }
}

private struct WizardTextArea: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 84

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: minHeight)
        }
        .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 0.8)
        )
    }
}
