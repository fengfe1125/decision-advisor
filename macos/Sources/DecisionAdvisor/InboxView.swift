import SwiftUI

struct InboxView: View {
    @Environment(AppState.self) private var state
    @FocusState private var isEditorFocused: Bool

    private let moods: [(String, Color)] = [
        ("平静", Color(red: 0.25, green: 0.55, blue: 0.46)),
        ("开心", Color(red: 0.85, green: 0.60, blue: 0.16)),
        ("释然", Color(red: 0.24, green: 0.58, blue: 0.62)),
        ("充能", Color(red: 0.28, green: 0.62, blue: 0.36)),
        ("焦虑", Color(red: 0.80, green: 0.44, blue: 0.20)),
        ("委屈", Color(red: 0.48, green: 0.46, blue: 0.72)),
        ("迷茫", Color(red: 0.54, green: 0.54, blue: 0.50)),
        ("疲惫", Color(red: 0.62, green: 0.44, blue: 0.40)),
    ]

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            // Aligned 52pt Seamless Header
            ZStack {
                WindowDragHandle()
                HStack(spacing: 10) {
                    if !state.isSidebarVisible {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                state.isSidebarVisible = true
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 13.5))
                        }
                        .buttonStyle(GhostIconButtonStyle(size: 28))
                        .padding(.leading, Theme.trafficLightClearance - 8)
                        .help("显示侧边栏 (⌘\\)")
                    }

                    Text("速记收件箱")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer()

                    Button {
                        state.selectedSection = .chat
                        state.startNewChat()
                        state.chatMode = .reflect
                        Task {
                            await state.sendChat(overrideText: "请帮我读取 99-收件箱/inbox.md 和近期经历，整理出值得归档的经历、情绪洞察与待更新事项。")
                        }
                    } label: {
                        Label("让 AI 整理入库", systemImage: "sparkles")
                    }
                    .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                }
                .padding(.horizontal, 20)
            }
            .frame(height: Theme.headerHeight)

            Rectangle()
                .fill(Theme.borderSubtle.opacity(0.7))
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Intro Header
                    VStack(alignment: .leading, spacing: 5) {
                        Text("10 秒捕捉此刻的想法与情绪")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("随时记录情绪波动、灵光一闪或日常小事，之后可在周期反思里一键整理入库。")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    // Unified Capture Card
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("此刻状态")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textTertiary)

                            FlowLayout(spacing: 7, lineSpacing: 7) {
                                ForEach(moods, id: \.0) { mood, dotColor in
                                    let isSelected = state.inboxMood == mood
                                    Button {
                                        state.inboxMood = isSelected ? "" : mood
                                    } label: {
                                        HStack(spacing: 5) {
                                            Circle()
                                                .fill(isSelected ? Theme.accent : dotColor.opacity(0.8))
                                                .frame(width: 6.5, height: 6.5)
                                            Text(mood)
                                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                        }
                                        .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 5.5)
                                        .background(
                                            Capsule()
                                                .fill(isSelected ? Theme.accentSoft : Theme.surfaceSubtle.opacity(0.75))
                                        )
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(isSelected ? Theme.accentBorder : .clear, lineWidth: 0.9)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }

                                // Inline Custom Mood Field
                                TextField("自定义情绪…", text: $state.inboxMood)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(width: 108)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5.5)
                                    .background(Theme.canvasBg, in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.85)
                                    )
                            }
                        }

                        // Text Capture Box
                        ZStack(alignment: .topLeading) {
                            if state.inboxText.isEmpty {
                                Text("记下此刻的感受、发生的小事，或脑海里闪过的一个念头…")
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 12)
                                    .allowsHitTesting(false)
                            }

                            TextEditor(text: $state.inboxText)
                                .font(.system(size: 14.5))
                                .lineSpacing(5)
                                .foregroundStyle(Theme.textPrimary)
                                .scrollContentBackground(.hidden)
                                .focused($isEditorFocused)
                                .frame(minHeight: 128, maxHeight: 220)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 8)
                        }
                        .background(Theme.canvasBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isEditorFocused ? Theme.accentBorder : Theme.borderSubtle, lineWidth: isEditorFocused ? 1.1 : 0.85)
                        )

                        // Bottom Action Bar
                        HStack {
                            Text(
                                state.backendMode == .remoteVPS
                                    ? "追加保存至 VPS 云端 99-收件箱/inbox.md · 与未来手机端互通"
                                    : "追加保存至本地 99-收件箱/inbox.md · 自动同步 iCloud"
                            )
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)

                            Spacer()

                            Button {
                                Task { await state.submitInbox() }
                            } label: {
                                Label("存入收件箱", systemImage: "tray.and.arrow.down")
                            }
                            .buttonStyle(SprucePrimaryButtonStyle())
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(state.inboxText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(20)
                    .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.9)
                    )
                    .shadow(color: .black.opacity(0.035), radius: 10, y: 3)

                    // Current Inbox Content Card
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            HStack(spacing: 7) {
                                Image(systemName: "doc.plaintext")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.accent)
                                Text("收件箱记录")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Spacer()
                            Button {
                                Task { await state.refreshInbox() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(GhostIconButtonStyle(size: 26))
                            .help("刷新收件箱")
                        }

                        Rectangle()
                            .fill(Theme.borderSubtle.opacity(0.8))
                            .frame(height: 1)

                        if state.inboxRawContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("收件箱目前是空的，有想法随时丢进来。")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.vertical, 12)
                        } else {
                            RichMarkdownView(text: state.inboxRawContent, fontSize: 14)
                        }
                    }
                    .padding(20)
                    .background(Theme.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.9)
                    )
                }
                .frame(maxWidth: 740, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasBg)
        .task {
            await state.refreshInbox()
        }
    }
}
