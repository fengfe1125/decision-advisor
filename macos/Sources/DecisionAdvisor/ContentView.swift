import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state

        HStack(spacing: 0) {
            if state.isSidebarVisible {
                UnifiedSidebarView()
                    .frame(width: Theme.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(Theme.borderSubtle)
                    .frame(width: 1)
                    .ignoresSafeArea(.all, edges: .top)
            }

            ZStack(alignment: .top) {
                Theme.canvasBg
                    .ignoresSafeArea()

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasBg)
        .ignoresSafeArea(.all, edges: .top)
        .tint(Theme.accent)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: state.isSidebarVisible)
        .sheet(isPresented: $state.showProposalSheet) {
            ProposalConfirmationSheet()
                .environment(state)
        }
    }
}

// MARK: - Unified Left Sidebar

private struct UnifiedSidebarView: View {
    @Environment(AppState.self) private var state
    @State private var isNewChatHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Top Traffic-Light-Aligned Bar
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
                .padding(.trailing, 10)
            }
            .frame(height: 32)

            // Brand Header
            HStack(spacing: 10) {
                CompassEmblem(size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("成长决策顾问")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let ver = state.health?.version, !ver.isEmpty {
                            Text("v\(ver)")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
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
            .padding(.top, 8)
            .padding(.bottom, 14)

            // Primary New Chat CTA
            Button {
                state.selectedSection = .chat
                state.startNewChat()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("新建对话")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 10.5, weight: .medium).monospaced())
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8.5)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isNewChatHovering ? Theme.cardBg : Theme.cardBg.opacity(0.86))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isNewChatHovering ? Theme.accentBorder : Theme.borderSubtle, lineWidth: 0.9)
                )
                .shadow(color: .black.opacity(0.03), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .onHover { isNewChatHovering = $0 }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            // Navigation Tabs
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
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            // Subtle Divider before Integrated Conversations
            Rectangle()
                .fill(Theme.borderSubtle)
                .frame(height: 1)
                .padding(.horizontal, 14)

            // Integrated Recent Conversations
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("最近对话")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if !state.sessions.isEmpty {
                        Text("\(state.sessions.count)")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

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
                        LazyVStack(spacing: 2) {
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
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Serene Compact Footer
            Rectangle()
                .fill(Theme.borderSubtle)
                .frame(height: 1)

            HStack(spacing: 8) {
                Button {
                    state.openBackendSettings()
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.isOnline ? Theme.success : Theme.warning)
                            .frame(width: 7, height: 7)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Image(systemName: state.backendMode.icon)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.accent)
                                Text(
                                    state.isOnline
                                        ? (state.backendMode == .remoteVPS ? "VPS 远程在线" : "内置引擎在线")
                                        : (state.embeddedBackend.isStarting ? "内置引擎启动中…" : "服务未连接")
                                )
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                            }
                            if let stats = state.health?.stats {
                                let emb = state.health?.index?.embeddedDocs ?? 0
                                Text("\(stats.total) 记忆 · \(emb) 向量")
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击配置远程 VPS 或 App 内置本地后端")

                Spacer()

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: state.localICloudVaultPath))
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12.5))
                }
                .buttonStyle(GhostIconButtonStyle(size: 26))
                .help("在访达中打开本机 iCloud 记忆目录")

                Button {
                    Task { await state.bootstrap() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .buttonStyle(GhostIconButtonStyle(size: 26))
                .help("刷新状态与记忆 (⌘R)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Theme.sidebarBg)
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
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 18)

                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)

                Spacer()

                if let count = badgeCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(isSelected ? Theme.accent.opacity(0.12) : Theme.hoverFill.opacity(0.65))
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7.5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                        ? Theme.accentSoft
                        : (isHovering ? Theme.hoverFill.opacity(0.75) : .clear)
                    )
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
        let trimmed = String(session.updatedAt.dropFirst(5).prefix(11))
            .replacingOccurrences(of: "T", with: " ")
        return trimmed
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? "未命名对话" : session.title)
                        .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text("\(session.messageCount) 条")
                        Text("·")
                        Text(shortTime)
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(isActive ? Theme.accent.opacity(0.75) : Theme.textTertiary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("删除对话")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isActive
                    ? Theme.accentSoft.opacity(0.9)
                    : (isHovering ? Theme.hoverFill.opacity(0.65) : .clear)
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
        .background(Theme.cardBg, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Theme.borderSubtle, lineWidth: 0.9)
        )
        .shadow(color: .black.opacity(0.11), radius: 14, y: 5)
    }
}
