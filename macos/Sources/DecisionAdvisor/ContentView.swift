import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        ZStack {
            MintBackdrop()

            HStack(spacing: 0) {
                if state.isSidebarVisible {
                    UnifiedSidebarView()
                        .frame(width: Theme.sidebarWidth)
                        .glassPanel()
                        .padding(.leading, Theme.panelInset)
                        .padding(.vertical, Theme.panelInset)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack(alignment: .top) {
                    Group {
                        switch state.selectedSection {
                        case .chat:
                            ChatView()
                        case .memories:
                            MemoriesView()
                        case .inbox:
                            InboxView()
                        case .settings:
                            SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let banner = state.statusBanner {
                        ToastBannerView(message: banner)
                            .padding(.top, Theme.headerHeight + 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(100)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: state.statusBanner)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all, edges: .top)
        .tint(Theme.accent)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: state.isSidebarVisible)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: state.isInspectorVisible)
        .sheet(isPresented: $state.showProposalSheet) {
            ProposalConfirmationSheet()
                .environment(state)
        }
    }
}

/// 侧边栏隐藏时，出现在各页面工具栏左侧的“显示侧边栏 / 新建对话”按钮组。
struct SidebarRevealButtons: View {
    @Environment(AppState.self) private var state
    var showNewChat: Bool = false

    var body: some View {
        if !state.isSidebarVisible {
            HStack(spacing: 2) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        state.isSidebarVisible = true
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13.5))
                }
                .buttonStyle(GhostIconButtonStyle(size: 30))
                .help("显示侧边栏 (⌘\\)")

                if showNewChat {
                    Button {
                        state.startNewChat()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(GhostIconButtonStyle(size: 30))
                    .help("新建对话 (⌘N)")
                }
            }
            .padding(2)
            .glassCapsule()
            .padding(.leading, Theme.trafficLightClearance - 14)
        }
    }
}

// MARK: - Floating Glass Sidebar

private struct UnifiedSidebarView: View {
    @Environment(AppState.self) private var state
    @State private var isNewChatHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Traffic-light row
            ZStack {
                WindowDragHandle()
                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            state.isSidebarVisible = false
                        }
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 13.5, weight: .regular))
                    }
                    .buttonStyle(GhostIconButtonStyle(size: 28))
                    .help("隐藏侧边栏 (⌘\\)")
                }
                .padding(.leading, Theme.trafficLightClearance)
                .padding(.trailing, 8)
            }
            .frame(height: 38)

            // Brand
            HStack(spacing: 10) {
                CompassEmblem(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("成长决策顾问")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let ver = state.health?.version, !ver.isEmpty {
                            Text("v\(ver)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Theme.accentSoft, in: Capsule())
                        }
                    }
                    Text("长期记忆与决策伴侣")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 12)

            // New chat field-style button
            Button {
                state.selectedSection = .chat
                state.startNewChat()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Text("新建对话")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isNewChatHovering ? Theme.textPrimary : Theme.textSecondary)
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 10.5, weight: .medium).monospaced())
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isNewChatHovering ? Theme.cardSolid.opacity(0.9) : Color.black.opacity(0.045))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isNewChatHovering = $0 }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            // Navigation
            VStack(spacing: 2) {
                ForEach(AdvisorSection.allCases) { section in
                    SidebarNavRow(
                        section: section,
                        isSelected: state.selectedSection == section,
                        badgeCount: section == .memories ? state.health?.stats.total : nil
                    ) {
                        state.selectSection(section)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            // Recent conversations
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("最近对话")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    if !state.sessions.isEmpty {
                        Text("\(state.sessions.count)")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Button {
                        state.selectedSection = .chat
                        state.startNewChat()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(GhostIconButtonStyle(size: 22))
                    .help("新建对话 (⌘N)")
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.top, 10)

                if state.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("暂无历史对话")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                        Text("开始聊天后自动归档在此")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary.opacity(0.75))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 1) {
                            ForEach(state.sessions) { sess in
                                SessionSidebarRow(
                                    session: sess,
                                    isActive: state.selectedSection == .chat && state.currentSessionId == sess.id,
                                    onSelect: {
                                        state.selectedSection = .chat
                                        Task { await state.openSession(sess.id) }
                                    },
                                    onDelete: {
                                        Task { await state.deleteSession(sess.id) }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Footer status
            Rectangle()
                .fill(Theme.borderSubtle.opacity(0.7))
                .frame(height: 0.5)

            HStack(spacing: 6) {
                Button {
                    state.openBackendSettings()
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(state.isOnline ? Theme.success : Theme.warning)
                            .frame(width: 7, height: 7)
                            .shadow(color: (state.isOnline ? Theme.success : Theme.warning).opacity(0.5), radius: 3)
                        Text(state.isOnline ? "VPS 远程" : "未连接")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 10)
                    .padding(.vertical, 5)
                    .glassCapsule()
                    .contentShape(Capsule())
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help("点击配置远程 VPS 服务器与备份")

                if let stats = state.health?.stats {
                    let emb = state.health?.index?.embeddedDocs ?? 0
                    Text("\(stats.total) 记忆 · \(emb) 向量")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                }

                Spacer(minLength: 0)

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: state.localICloudVaultPath))
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                }
                .buttonStyle(GhostIconButtonStyle(size: 24))
                .help("在访达中打开本机 iCloud 备份目录")

                Button {
                    Task { await state.bootstrap() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11.5))
                }
                .buttonStyle(GhostIconButtonStyle(size: 24))
                .help("刷新状态与记忆 (⌘R)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
        }
    }
}

private struct SidebarNavRow: View {
    let section: AdvisorSection
    let isSelected: Bool
    let badgeCount: Int?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accentInk : Theme.accent)
                    .frame(width: 18)

                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accentInk : Theme.textPrimary)

                Spacer()

                if let count = badgeCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(isSelected ? Theme.accentInk.opacity(0.8) : Theme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                        ? AnyShapeStyle(Theme.selectionFill)
                        : AnyShapeStyle(isHovering ? Theme.hoverFill.opacity(0.7) : Color.clear)
                    )
                    .shadow(color: Theme.accent.opacity(isSelected ? 0.12 : 0), radius: 4, y: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct SessionSidebarRow: View {
    let session: SessionSummary
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    private var shortTime: String {
        String(session.updatedAt.dropFirst(5).prefix(11))
            .replacingOccurrences(of: "T", with: " ")
    }

    private var mode: ChatMode {
        ChatMode(rawValue: session.mode) ?? .chat
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Theme.cardSolid.opacity(isActive ? 1 : 0.8))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title.isEmpty ? "未命名对话" : session.title)
                            .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? Theme.accentInk : Theme.textPrimary)
                            .lineLimit(1)
                        Text("\(mode.label) · \(shortTime)")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("删除对话")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    isActive
                    ? Theme.accentSoft
                    : (isHovering ? Theme.hoverFill.opacity(0.6) : .clear)
                )
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("删除对话", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Refined Floating Toast Banner

private struct ToastBannerView: View {
    let message: String

    private var iconName: String {
        if message.contains("❌") || message.contains("失败") || message.contains("无法连接") {
            return "exclamationmark.circle.fill"
        }
        if message.contains("✅") || message.contains("已") || message.contains("完成") {
            return "checkmark.circle.fill"
        }
        return "info.circle.fill"
    }

    private var iconColor: Color {
        if message.contains("❌") || message.contains("失败") || message.contains("无法连接") {
            return Theme.danger
        }
        if message.contains("✅") || message.contains("已") || message.contains("完成") {
            return Theme.success
        }
        return Theme.accent
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 13.5))
                .foregroundStyle(iconColor)
            Text(message.replacingOccurrences(of: "✅ ", with: "").replacingOccurrences(of: "❌ ", with: ""))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassPanel(cornerRadius: 20, tint: Theme.cardBg)
    }
}
