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
                    SidebarRevealButtons()

                    VStack(alignment: .leading, spacing: 1) {
                        Text("速记收件箱")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("99-收件箱/inbox.md")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.leading, state.isSidebarVisible ? 10 : 0)

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
                .padding(.leading, 14)
                .padding(.trailing, 16)
            }
            .frame(height: Theme.headerHeight)

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
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(dotColor.opacity(0.85))
                                                .frame(width: 14, height: 14)
                                                .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
                                            Text(mood)
                                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                        }
                                        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                                        .padding(.leading, 6)
                                        .padding(.trailing, 12)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule()
                                                .fill(isSelected ? Theme.cardSolid : Color.black.opacity(0.04))
                                        )
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2)
                                        )
                                        .shadow(color: Theme.accent.opacity(isSelected ? 0.18 : 0), radius: 5, y: 2)
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
                                    .background(Color.black.opacity(0.04), in: Capsule())
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
                        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isEditorFocused ? Theme.accentBorder : Color.clear, lineWidth: 1.1)
                        )

                        // Bottom Action Bar
                        HStack {
                            Text("追加保存至 VPS 云端 99-收件箱/inbox.md · 与手机端实时互通")
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
                    .padding(22)
                    .glassPanel(cornerRadius: 22, tint: Theme.cardBg)

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
                    .glassCard(cornerRadius: 18)
                }
                .frame(maxWidth: 740, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await state.refreshInbox()
        }
    }
}
