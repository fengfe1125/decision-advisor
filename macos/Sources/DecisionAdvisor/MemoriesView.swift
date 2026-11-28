import SwiftUI

struct MemoriesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        HStack(spacing: 0) {
            // MARK: Left Column — Navigation, Search & Memory List
            VStack(spacing: 0) {
                // Aligned 52pt Top Header
                ZStack {
                    WindowDragHandle()
                    HStack(spacing: 8) {
                        SidebarRevealButtons()

                        UnifiedSegmentedControl(
                            options: MemoryViewMode.allCases,
                            selection: $state.memoryViewMode,
                            label: { $0.rawValue },
                            compact: true
                        )
                        .onChange(of: state.memoryViewMode) { _, _ in
                            Task { await state.refreshMemories() }
                        }

                        Button {
                            state.openMemoryImportSheet()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(GhostIconButtonStyle(size: 30))
                        .padding(2)
                        .glassCapsule()
                        .help("导入其他 Agent 记忆（ChatGPT / Claude / 通用 JSON）")
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: Theme.headerHeight)

                // Search & Filters (List / Semantic)
                if state.memoryViewMode == .list || state.memoryViewMode == .semantic {
                    VStack(spacing: 9) {
                        HStack(spacing: 7) {
                            Image(systemName: state.memoryViewMode == .semantic ? "sparkle.magnifyingglass" : "magnifyingglass")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textTertiary)

                            TextField(
                                state.memoryViewMode == .semantic ? "自然语言语义检索（如：被否定后的焦虑）" : "搜索标题、人物、感受…",
                                text: $state.memoryQuery
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textPrimary)
                            .onSubmit {
                                Task { await state.refreshMemories() }
                            }

                            if !state.memoryQuery.isEmpty {
                                Button {
                                    state.memoryQuery = ""
                                    Task { await state.refreshMemories() }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }

                            if state.memoryViewMode == .semantic {
                                Button("检索") {
                                    Task { await state.refreshMemories() }
                                }
                                .buttonStyle(SprucePrimaryButtonStyle(compact: true))
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .glassCard(cornerRadius: 11)

                        if state.memoryViewMode == .list {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(state.categories) { cat in
                                        FilterPillButton(
                                            title: cat.label,
                                            isSelected: state.selectedCategory == cat.id
                                        ) {
                                            state.selectedCategory = cat.id
                                            Task { await state.refreshMemories() }
                                        }
                                    }

                                    FilterPillButton(
                                        title: "★ 高显著",
                                        isSelected: state.highImportanceOnly
                                    ) {
                                        state.highImportanceOnly.toggle()
                                        Task { await state.refreshMemories() }
                                    }
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                FilterPillButton(
                                    title: "回溯截止日期",
                                    isSelected: state.searchUseAsOf
                                ) {
                                    state.searchUseAsOf.toggle()
                                }
                                if state.searchUseAsOf {
                                    DatePicker("", selection: $state.searchAsOfDate, displayedComponents: .date)
                                        .labelsHidden()
                                        .datePickerStyle(.compact)
                                        .controlSize(.small)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }

                // Content List per View Mode
                Group {
                    switch state.memoryViewMode {
                    case .list, .semantic:
                        MemoryCardsListView()
                    case .timeline:
                        MemoryTimelineListView()
                    case .graph:
                        MemoryGraphListView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: state.isSidebarVisible ? 340 : 372)
            .glassPanel()
            .padding(.leading, Theme.panelInset)
            .padding(.vertical, Theme.panelInset)

            // MARK: Right Column — Reader & Native Markdown Editor
            MemoryReaderPane()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Filter Pill

private struct FilterPillButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.accentInk : (isHovering ? Theme.textPrimary : Theme.textSecondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(
                    Capsule()
                        .fill(isSelected ? AnyShapeStyle(Theme.selectionFill) : AnyShapeStyle(isHovering ? Theme.cardSolid : Theme.cardBg))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.clear : Color.black.opacity(0.06), lineWidth: 0.5)
                )
                .shadow(color: Theme.accent.opacity(isSelected ? 0.1 : 0), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - List / Semantic Cards

private struct MemoryCardsListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.memories.isEmpty {
            CalmEmptyState(
                icon: state.memoryViewMode == .semantic ? "sparkle.magnifyingglass" : "doc.text",
                title: state.memoryViewMode == .semantic ? "语义记忆检索" : "暂无匹配记忆",
                subtitle: state.memoryViewMode == .semantic
                    ? "输入一个场景、情绪或问题，回车通过中文向量与图谱召回相关记忆"
                    : "尝试调整分类筛选或搜索关键词"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(state.memories) { item in
                        MemoryListCard(
                            item: item,
                            isSelected: state.selectedMemoryPath == item.path
                        ) {
                            Task { await state.openMemory(path: item.path) }
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}

private struct MemoryListCard: View {
    let item: MemorySummary
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(item.categoryLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(isSelected ? Theme.accent.opacity(0.14) : Theme.surfaceSubtle)
                        )
                }

                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.system(size: 12))
                        .lineSpacing(2.5)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 7) {
                    if !item.eventTime.isEmpty {
                        Text(item.eventTime)
                            .monospacedDigit()
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(item.importance >= 7 ? Theme.warning : Theme.textTertiary)
                        Text("\(item.importance)")
                            .monospacedDigit()
                    }
                    if item.privacy == "sensitive" {
                        HStack(spacing: 2) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8.5))
                            Text("敏感")
                        }
                        .foregroundStyle(Theme.danger)
                    }
                    if let reasons = item.reasons, !reasons.isEmpty {
                        Text(reasons.joined(separator: " · "))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    } else if let firstEmo = item.emotions.first {
                        Text(firstEmo)
                            .foregroundStyle(Theme.accent.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 13, isSelected: isSelected, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Visual Vertical Timeline

private struct MemoryTimelineListView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.timelineItems.isEmpty {
            CalmEmptyState(
                icon: "calendar.day.timeline.left",
                title: "时间轴暂无记录",
                subtitle: "记录经历并标注事件发生时间后，将在此按人生轨迹呈现"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.timelineItems.enumerated()), id: \.element.id) { idx, item in
                        TimelineRowCard(
                            item: item,
                            isSelected: state.selectedMemoryPath == item.path,
                            isFirst: idx == 0,
                            isLast: idx == state.timelineItems.count - 1
                        ) {
                            Task { await state.openMemory(path: item.path) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct TimelineRowCard: View {
    let item: TimelineItem
    let isSelected: Bool
    let isFirst: Bool
    let isLast: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                // Vertical Timeline Spine & Dot
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(isFirst ? .clear : Theme.borderStrong.opacity(0.7))
                        .frame(width: 1.5, height: 14)

                    Circle()
                        .fill(item.importance >= 7 || isSelected ? Theme.accent : Theme.cardBg)
                        .overlay(
                            Circle()
                                .strokeBorder(Theme.accent, lineWidth: 1.8)
                        )
                        .frame(width: item.importance >= 7 ? 10 : 8, height: item.importance >= 7 ? 10 : 8)

                    Rectangle()
                        .fill(isLast ? .clear : Theme.borderStrong.opacity(0.7))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 14)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(item.eventTime.isEmpty ? item.recordedAt : item.eventTime)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                        Text("·")
                            .foregroundStyle(Theme.textTertiary)
                        Text(item.categoryLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Text("★\(item.importance)")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(item.importance >= 7 ? Theme.warning : Theme.textTertiary)
                    }

                    Text(item.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    if !item.snippet.isEmpty {
                        Text(item.snippet)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 12, isSelected: isSelected, isHovering: isHovering)
                .padding(.bottom, 10)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Interactive Mini Graph + Edges List

private struct MemoryGraphListView: View {
    @Environment(AppState.self) private var state

    private var nodeMap: [String: GraphNode] {
        Dictionary(uniqueKeysWithValues: state.graphData.nodes.map { ($0.id, $0) })
    }

    var body: some View {
        if state.graphData.nodes.isEmpty {
            CalmEmptyState(
                icon: "point.3.connected.trianglepath.dotted",
                title: "暂无图谱关联",
                subtitle: "记忆中出现双链、共同人物或同章节时将自动编织关系图谱"
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Interactive Radial Graph Preview
                    InteractiveGraphCanvas(
                        nodes: state.graphData.nodes,
                        edges: state.graphData.edges,
                        selectedPath: state.selectedMemoryPath
                    ) { nodeId in
                        Task { await state.openMemory(path: nodeId) }
                    }
                    .frame(height: 220)
                    .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.85)
                    )

                    if state.graphData.edges.isEmpty {
                        Text("已收录 \(state.graphData.nodes.count) 篇记忆节点，暂未发现显式关联边")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 4)
                    } else {
                        Text("关联关系（\(state.graphData.edges.count)）")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 4)

                        LazyVStack(spacing: 6) {
                            ForEach(state.graphData.edges) { edge in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(relationLabel(edge.relationType))
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(relationColor(edge.relationType))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(relationColor(edge.relationType).opacity(0.12), in: Capsule())

                                    HStack(spacing: 6) {
                                        Button {
                                            Task { await state.openMemory(path: edge.source) }
                                        } label: {
                                            Text(nodeMap[edge.source]?.title ?? edge.source)
                                                .font(.system(size: 12.5, weight: .medium))
                                                .foregroundStyle(Theme.textPrimary)
                                                .lineLimit(1)
                                        }
                                        .buttonStyle(.plain)

                                        Image(systemName: "arrow.left.arrow.right")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(Theme.textTertiary)

                                        Button {
                                            Task { await state.openMemory(path: edge.target) }
                                        } label: {
                                            Text(nodeMap[edge.target]?.title ?? edge.target)
                                                .font(.system(size: 12.5, weight: .medium))
                                                .foregroundStyle(Theme.textPrimary)
                                                .lineLimit(1)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.cardBg.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Theme.borderSubtle.opacity(0.8), lineWidth: 0.75)
                                )
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func relationLabel(_ type: String) -> String {
        switch type {
        case "wikilink": return "双链关联"
        case "shared_person": return "共同人物"
        default: return "同一章节"
        }
    }

    private func relationColor(_ type: String) -> Color {
        switch type {
        case "wikilink": return Theme.accent
        case "shared_person": return Theme.warning
        default: return Theme.textSecondary
        }
    }
}

private struct InteractiveGraphCanvas: View {
    let nodes: [GraphNode]
    let edges: [GraphEdge]
    let selectedPath: String?
    let onSelectNode: (String) -> Void

    private var displayedNodes: [GraphNode] {
        Array(nodes.prefix(16))
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cx = w / 2
            let cy = h / 2
            let rx = max(50, w * 0.34)
            let ry = max(45, h * 0.34)

            let positions: [String: CGPoint] = {
                var dict: [String: CGPoint] = [:]
                let count = displayedNodes.count
                for (i, node) in displayedNodes.enumerated() {
                    if count == 1 {
                        dict[node.id] = CGPoint(x: cx, y: cy)
                    } else {
                        let angle = (Double(i) / Double(count)) * Double.pi * 2 - Double.pi / 2
                        dict[node.id] = CGPoint(
                            x: cx + CGFloat(cos(angle)) * rx,
                            y: cy + CGFloat(sin(angle)) * ry
                        )
                    }
                }
                return dict
            }()

            ZStack {
                Canvas { context, _ in
                    for edge in edges {
                        guard let p1 = positions[edge.source], let p2 = positions[edge.target] else { continue }
                        let highlighted = selectedPath == edge.source || selectedPath == edge.target
                        var path = Path()
                        path.move(to: p1)
                        let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
                        let ctrl = CGPoint(x: (mid.x + cx) / 2, y: (mid.y + cy) / 2)
                        path.addQuadCurve(to: p2, control: ctrl)
                        context.stroke(
                            path,
                            with: .color(highlighted ? Theme.accent.opacity(0.75) : Theme.borderStrong.opacity(0.55)),
                            lineWidth: highlighted ? 1.8 : 1.0
                        )
                    }
                }

                ForEach(displayedNodes) { node in
                    if let pt = positions[node.id] {
                        let isSel = selectedPath == node.id
                        Button {
                            onSelectNode(node.id)
                        } label: {
                            VStack(spacing: 3) {
                                Circle()
                                    .fill(isSel ? Theme.accent : Theme.cardBg)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(isSel ? Theme.accent : Theme.accent.opacity(0.65), lineWidth: isSel ? 2.5 : 1.6)
                                    )
                                    .frame(width: node.importance >= 7 ? 14 : 11, height: node.importance >= 7 ? 14 : 11)
                                    .shadow(color: Theme.accent.opacity(isSel ? 0.35 : 0.1), radius: 4)

                                Text(String(node.title.prefix(6)))
                                    .font(.system(size: 9.5, weight: isSel ? .semibold : .regular))
                                    .foregroundStyle(isSel ? Theme.accent : Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .position(pt)
                        .help(node.title)
                    }
                }
            }
        }
    }
}

// MARK: - Right Reader & Native Markdown Editor

private struct MemoryReaderPane: View {
    @Environment(AppState.self) private var state
    @State private var showDeleteConfirm = false

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            // Aligned 52pt Top Header
            ZStack {
                WindowDragHandle()
                HStack(spacing: 10) {
                    if let detail = state.currentMemoryDetail {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.accent)
                            Text(detail.path)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .glassCapsule()

                        if detail.privacy == "sensitive" {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10))
                                Text("敏感保护")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Theme.danger)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.dangerSoft, in: Capsule())
                        }

                        Spacer()

                        if state.isEditingMemory {
                            Button("取消") {
                                state.editorText = detail.raw
                                state.isEditingMemory = false
                            }
                            .buttonStyle(SubtleOutlineButtonStyle(compact: true))

                            Button {
                                Task { await state.saveEditedMemory() }
                            } label: {
                                Label("保存", systemImage: "checkmark")
                            }
                            .buttonStyle(SprucePrimaryButtonStyle(compact: true))
                            .keyboardShortcut("s", modifiers: .command)
                        } else {
                            Button {
                                showDeleteConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.danger.opacity(0.85))
                            }
                            .buttonStyle(GhostIconButtonStyle(size: 28))
                            .help("删除此记忆文件（自动留存 Git 快照）")

                            Button {
                                state.isEditingMemory = true
                            } label: {
                                Label("编辑原文", systemImage: "pencil")
                            }
                            .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                        }
                    } else {
                        Spacer()
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: Theme.headerHeight)

            // Main Reader or Editor Body
            if let detail = state.currentMemoryDetail {
                if state.isEditingMemory {
                    VStack(spacing: 0) {
                        TextEditor(text: $state.editorText)
                            .font(.system(size: 13.5, design: .monospaced))
                            .lineSpacing(5)
                            .foregroundStyle(Theme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(22)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .glassCard(cornerRadius: 16)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            // Editorial Document Title & Meta
                            VStack(alignment: .leading, spacing: 10) {
                                Text(detail.title)
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .textSelection(.enabled)

                                FlowLayout(spacing: 8, lineSpacing: 6) {
                                    MetaTagPill(icon: "folder", text: detail.categoryLabel, tint: Theme.accent, bg: Theme.accentSoft)
                                    MetaTagPill(icon: "star.fill", text: "显著性 \(detail.importance)/10", tint: detail.importance >= 7 ? Theme.warning : Theme.textSecondary, bg: detail.importance >= 7 ? Theme.warningSoft : Theme.surfaceSubtle)
                                    if !detail.eventTime.isEmpty {
                                        MetaTagPill(icon: "calendar", text: "发生于 \(detail.eventTime)", tint: Theme.textSecondary, bg: Theme.surfaceSubtle)
                                    }
                                    if !detail.recordedAt.isEmpty {
                                        MetaTagPill(icon: "clock", text: "记录于 \(String(detail.recordedAt.prefix(10)))", tint: Theme.textTertiary, bg: Theme.surfaceSubtle.opacity(0.7))
                                    }
                                }
                            }

                            // Structured Emotions Breakdown
                            if let emos = detail.emotionsDetail?.filter({ !($0.name ?? "").isEmpty }), !emos.isEmpty {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                                    ForEach(emos) { em in
                                        EmotionDetailCard(emotion: em)
                                    }
                                }
                            }

                            Rectangle()
                                .fill(Theme.borderSubtle.opacity(0.8))
                                .frame(height: 1)

                            RichMarkdownView(text: detail.body, fontSize: 15)
                        }
                        .padding(.horizontal, 30)
                        .padding(.vertical, 28)
                        .frame(maxWidth: 780, alignment: .leading)
                        .glassCard(cornerRadius: 18)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                }
            } else {
                CalmEmptyState(
                    icon: "book.pages",
                    title: "选择一篇记忆开始阅读",
                    subtitle: "支持情绪结构卡片、中文语义召回、人生双时间轴与原生 Markdown 实时编辑"
                )
            }
        }
        .alert("确认删除这篇记忆？", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await state.deleteCurrentMemory() }
            }
        } message: {
            Text("删除「\(state.currentMemoryDetail?.title ?? "")」后会自动记录一次 Git 版本快照，方便日后追溯恢复。")
        }
    }
}

private struct MetaTagPill: View {
    let icon: String
    let text: String
    let tint: Color
    let bg: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(bg, in: Capsule())
    }
}

private struct EmotionDetailCard: View {
    let emotion: EmotionDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(emotion.name ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let intensity = emotion.intensity {
                    Text("\(intensity)/10")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.accentSoft, in: Capsule())
                }
            }

            if let intensity = emotion.intensity {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.surfaceSubtle)
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: g.size.width * CGFloat(max(0, min(10, intensity))) / 10.0)
                    }
                }
                .frame(height: 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let trig = emotion.trigger, !trig.isEmpty {
                    EmotionKVRow(label: "触发", value: trig)
                }
                if let body = emotion.body, !body.isEmpty {
                    EmotionKVRow(label: "身体", value: body)
                }
                if let thought = emotion.thought, !thought.isEmpty {
                    EmotionKVRow(label: "念头", value: thought)
                }
            }
        }
        .padding(13)
        .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.borderSubtle, lineWidth: 0.85)
        )
    }
}

private struct EmotionKVRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 28, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
