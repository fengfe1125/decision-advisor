import AppKit
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case profile = "个人画像"
    case models = "大模型"
    case index = "语义索引"
    case backend = "远程服务器"
    case snapshots = "版本快照"
    case about = "关于与更新"

    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(UpdateChecker.self) private var updater
    @State private var activeTab: SettingsTab = .profile
    @State private var expandedProviderIds: Set<String> = []
    @State private var providers: [ProviderPresetDTO] = []
    @State private var activeProviderId: String = ""
    @State private var publicBaseUrl: String = ""
    @State private var remoteURLDraft: String = ""
    @State private var remoteTokenDraft: String = ""
    @State private var newServerPassword: String = ""
    @State private var manualCallbackURL: String = ""
    @State private var showManualCallbackBox: Bool = false
    @State private var embedding = EmbeddingConfigDTO(
        mode: "local_bge_zh",
        localModel: "BAAI/bge-small-zh-v1.5",
        apiBaseUrl: "https://api.openai.com/v1",
        apiKey: "",
        apiModel: "text-embedding-3-small"
    )
    @State private var loadedOnce = false

    private func syncFromConfig() {
        remoteURLDraft = state.remoteServerURL
        remoteTokenDraft = state.remoteAccessToken
        guard let cfg = state.config else { return }
        providers = cfg.providers
        activeProviderId = cfg.activeProviderId
        publicBaseUrl = cfg.publicBaseUrl
        embedding = cfg.embedding
        if expandedProviderIds.isEmpty {
            expandedProviderIds.insert(cfg.activeProviderId)
        }
        loadedOnce = true
    }

    private func copyToPasteboard(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        state.showBanner("已复制\(label)")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Aligned Seamless Header Bar with Unified Sub-Tabs
            ZStack {
                WindowDragHandle()
                HStack(spacing: 12) {
                    SidebarRevealButtons()

                    UnifiedSegmentedControl(
                        options: SettingsTab.allCases,
                        selection: $activeTab,
                        label: { $0.rawValue },
                        compact: true
                    )

                    Spacer()

                    Button {
                        Task {
                            await state.saveSettings(
                                providers: providers,
                                activeProviderId: activeProviderId,
                                embedding: embedding,
                                publicBaseUrl: publicBaseUrl,
                                newAccessToken: newServerPassword.isEmpty ? nil : newServerPassword
                            )
                            newServerPassword = ""
                            syncFromConfig()
                        }
                    } label: {
                        Label("保存配置", systemImage: "checkmark")
                    }
                    .buttonStyle(SprucePrimaryButtonStyle(compact: true))
                    .keyboardShortcut("s", modifiers: .command)
                }
                .padding(.leading, 14)
                .padding(.trailing, 16)
            }
            .frame(height: Theme.headerHeight)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Color.clear
                            .frame(height: 0)
                            .id("settings-top")

                        switch activeTab {
                        case .profile:
                            profileSection
                        case .models:
                            modelsSection
                        case .index:
                            indexSection
                        case .backend:
                            backendSection
                        case .snapshots:
                            snapshotsSection
                        case .about:
                            aboutSection
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                    .padding(.bottom, 26)
                }
                .onAppear {
                    proxy.scrollTo("settings-top", anchor: .top)
                }
                .onChange(of: activeTab) { _, _ in
                    proxy.scrollTo("settings-top", anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            applyPreferredTab()
            if !loadedOnce { syncFromConfig() }
        }
        .onChange(of: state.settingsPreferredTab) { _, _ in
            applyPreferredTab()
        }
        .onChange(of: state.config?.activeProviderId) { _, _ in
            syncFromConfig()
        }
        .onChange(of: state.config?.chatgptOauth?.updatedAt) { _, _ in
            syncFromConfig()
        }
        .task {
            await state.refreshHealthAndConfig()
            await state.refreshOnboardingStatus(autoPresent: false)
            await state.refreshGitHistory()
            syncFromConfig()
        }
    }

    private func applyPreferredTab() {
        switch state.settingsPreferredTab {
        case "backend":
            activeTab = .backend
        case "about":
            activeTab = .about
        case "models":
            activeTab = .models
        case "profile":
            activeTab = .profile
        default:
            break
        }
        state.settingsPreferredTab = ""
    }

    // MARK: - Tab 0: Profile & Onboarding

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSectionContainer(
                title: "个人画像与初始化",
                subtitle: "管理你的 5 项核心自我档案、开启引导访谈或从其他 Agent 迁移记忆"
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    if let status = state.onboardingStatus {
                        CoreSelfProgressBanner(status: status) { slot in
                            Task { await state.startGuidedInterview(focusSlot: slot.id) }
                        }
                    } else {
                        Text("正在读取核心自我档案状态…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(cornerRadius: 14)
                    }

                    HStack(spacing: 10) {
                        Button {
                            state.openOnboardingWizard(route: "hub")
                        } label: {
                            Label("完善个人画像", systemImage: "person.crop.circle.badge.plus")
                        }
                        .buttonStyle(SprucePrimaryButtonStyle())

                        Button {
                            state.openMemoryImportSheet()
                        } label: {
                            Label("导入其他 Agent 记忆", systemImage: "square.and.arrow.down.on.square")
                        }
                        .buttonStyle(SubtleOutlineButtonStyle())

                        Button {
                            Task { await state.startGuidedInterview(focusSlot: nil) }
                        } label: {
                            Label(state.isStartingInterview ? "开启中…" : "1 对 1 冷启动访谈", systemImage: "mic")
                        }
                        .buttonStyle(SubtleOutlineButtonStyle())
                        .disabled(state.isStartingInterview)

                        Spacer()
                    }
                }
            }

            SettingsSectionContainer(
                title: "远程记忆库与连接状态",
                subtitle: "桌面端与手机端共用 24/7 云端 VPS 记忆库与 4 路混合检索索引"
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        IndexMetricTile(
                            label: "连接状态",
                            value: state.isOnline ? "VPS 在线" : "未连接",
                            isText: true
                        )
                        IndexMetricTile(
                            label: "记忆篇数",
                            value: state.health.map { "\($0.stats.total)" } ?? "—"
                        )
                        IndexMetricTile(
                            label: "向量已索引",
                            value: state.health?.index.map { "\($0.embeddedDocs)" } ?? "—"
                        )
                    }

                    HStack(spacing: 10) {
                        Button {
                            activeTab = .backend
                        } label: {
                            Label("配置远程服务器", systemImage: "server.rack")
                        }
                        .buttonStyle(SubtleOutlineButtonStyle(compact: true))

                        Button {
                            activeTab = .index
                        } label: {
                            Label("管理语义索引", systemImage: "sparkle.magnifyingglass")
                        }
                        .buttonStyle(SubtleOutlineButtonStyle(compact: true))

                        Spacer()

                        Button {
                            Task { await state.backupRemoteVaultToLocalICloud() }
                        } label: {
                            Label(state.isBackingUpVault ? "备份中…" : "备份回本机 iCloud", systemImage: "icloud.and.arrow.down")
                        }
                        .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                        .disabled(state.isBackingUpVault || !state.isOnline)
                    }
                }
                .padding(16)
                .glassCard(cornerRadius: 16)
            }
        }
    }

    // MARK: - Tab 1: Models

    private var chatgptOAuthCard: some View {
        let oauth = state.config?.chatgptOauth
        let connected = oauth?.connected == true
        let models = oauth?.availableModels ?? []
        let gptProviderIndex = providers.firstIndex(where: { $0.kind == "chatgpt_oauth" })
        let currentGptModel = gptProviderIndex.map { providers[$0].model } ?? ""

        return SettingsSectionContainer(
            title: "ChatGPT 订阅账号授权登录",
            subtitle: "官方 Sign in with ChatGPT（OAuth 2.0 PKCE），直接调用你的 ChatGPT Plus / Pro / Go / Business 额度和可用模型"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // Status Header
                HStack(spacing: 10) {
                    Circle()
                        .fill(connected ? Theme.success : (state.isAwaitingChatGPTCallback ? Theme.accent : Theme.warning))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(connected ? "已授权连接 ChatGPT 订阅" : (state.isAwaitingChatGPTCallback ? "正在等待浏览器完成授权…" : "尚未授权 ChatGPT 账号"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)

                            if connected, let plan = oauth?.planType, !plan.isEmpty {
                                Text(plan.uppercased())
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Theme.accentSoft, in: Capsule())
                            }

                            if connected {
                                let hasScope = oauth?.hasPlanUsageScope == true
                                Text(hasScope ? "已授予订阅额度" : "未勾选订阅额度")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(hasScope ? Theme.success : Theme.warning)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(hasScope ? Theme.successSoft : Theme.warningSoft, in: Capsule())
                            }
                        }

                        if connected {
                            let identity = [oauth?.accountEmail, oauth?.accountName]
                                .compactMap { $0 }
                                .first(where: { !$0.isEmpty }) ?? "已登录 ChatGPT 账号"
                            let refreshHint = oauth?.canRefresh == true ? "自动续期已开启" : "令牌有效期内"
                            Text("\(identity) · \(refreshHint) · 已发现 \(models.count) 个可用模型")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            Text("点击下方按钮在浏览器登录 OpenAI 官方授权页并同意额度权限，授权后自动同步可用模型，无需填写 API Key。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    Spacer()

                    if state.isAwaitingChatGPTCallback {
                        ProgressView().controlSize(.small)
                        Button("取消") {
                            state.cancelChatGPTLoginWait()
                        }
                        .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                    }
                }

                // Primary Actions Row
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await state.startChatGPTLogin(forceRegister: false, openBrowser: true)
                        }
                    } label: {
                        if state.isStartingChatGPTAuth {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("正在生成授权链接…")
                            }
                        } else {
                            Label(connected ? "重新授权 / 续期" : "使用 ChatGPT 授权登录", systemImage: "person.badge.key.fill")
                        }
                    }
                    .buttonStyle(SprucePrimaryButtonStyle(compact: true))
                    .disabled(state.isStartingChatGPTAuth)

                    Button {
                        Task {
                            if state.chatgptAuthURL.isEmpty {
                                await state.startChatGPTLogin(forceRegister: false, openBrowser: false)
                            }
                            if !state.chatgptAuthURL.isEmpty {
                                copyToPasteboard(state.chatgptAuthURL, label: "ChatGPT 授权登录链接")
                            }
                        }
                    } label: {
                        Label("复制授权链接", systemImage: "link")
                    }
                    .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                    .disabled(state.isStartingChatGPTAuth)

                    if connected {
                        Button {
                            Task {
                                await state.refreshChatGPTModels()
                                syncFromConfig()
                            }
                        } label: {
                            if state.isRefreshingChatGPTModels {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.mini)
                                    Text("刷新中")
                                }
                            } else {
                                Label("刷新模型", systemImage: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                        .disabled(state.isRefreshingChatGPTModels)

                        if let idx = gptProviderIndex {
                            let pid = providers[idx].id
                            Button {
                                activeProviderId = pid
                                Task {
                                    await state.saveSettings(
                                        providers: providers,
                                        activeProviderId: pid,
                                        embedding: embedding,
                                        publicBaseUrl: publicBaseUrl
                                    )
                                    await state.testProvider(pid)
                                }
                            } label: {
                                Label("设为默认并测试", systemImage: "checkmark.circle")
                            }
                            .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                            .disabled(state.testingProviderId == pid)
                        }
                    }

                    Spacer()

                    if connected {
                        Menu {
                            Button("切换账号（重新动态注册）") {
                                Task {
                                    await state.startChatGPTLogin(forceRegister: true, openBrowser: true)
                                }
                            }
                            Divider()
                            Button("退出登录", role: .destructive) {
                                Task {
                                    await state.logoutChatGPT(resetClient: false)
                                    syncFromConfig()
                                }
                            }
                            Button("退出并重置客户端 ID", role: .destructive) {
                                Task {
                                    await state.logoutChatGPT(resetClient: true)
                                    syncFromConfig()
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }

                // Generated Authorization URL Box (always visible once generated so user can inspect/open/copy)
                if !state.chatgptAuthURL.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("已生成官方 OAuth 授权登录链接")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button {
                                if let url = URL(string: state.chatgptAuthURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("浏览器打开", systemImage: "safari")
                            }
                            .buttonStyle(SubtleOutlineButtonStyle(compact: true))

                            Button {
                                copyToPasteboard(state.chatgptAuthURL, label: "授权链接")
                            } label: {
                                Label("复制", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                        }

                        Text(state.chatgptAuthURL)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Theme.borderSubtle, lineWidth: 0.8)
                            )
                    }
                }

                // Live Discovered Subscription Models Picker
                if connected && !models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前账号可调用的 GPT 模型（点击切换）")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(models) { item in
                                    let selected = currentGptModel.trimmingCharacters(in: .whitespacesAndNewlines) == item.slug
                                    Button {
                                        if let idx = gptProviderIndex {
                                            providers[idx].model = item.slug
                                            activeProviderId = providers[idx].id
                                            Task {
                                                await state.saveSettings(
                                                    providers: providers,
                                                    activeProviderId: providers[idx].id,
                                                    embedding: embedding,
                                                    publicBaseUrl: publicBaseUrl
                                                )
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(item.displayName)
                                                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                                            if item.displayName != item.slug {
                                                Text(item.slug)
                                                    .font(.system(size: 10.5, design: .monospaced))
                                                    .foregroundStyle(selected ? Theme.accent.opacity(0.85) : Theme.textTertiary)
                                            }
                                        }
                                        .foregroundStyle(selected ? Theme.accent : Theme.textPrimary)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(selected ? Theme.accentSoft : Theme.cardBg, in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(selected ? Theme.accentBorder : Theme.borderSubtle, lineWidth: 0.9)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }

                // Fallback Manual Callback Paste Box (for remote browsers / blocked loopback)
                DisclosureGroup(isExpanded: $showManualCallbackBox) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("如果在其他设备打开授权链接，浏览器最后跳转到一个无法访问的 127.0.0.1 回调地址，把完整地址栏链接粘贴到这里即可完成授权：")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                        HStack(spacing: 8) {
                            UnifiedFieldBox {
                                TextField("http://127.0.0.1:.../auth/callback?code=...&state=...", text: $manualCallbackURL)
                            }
                            Button {
                                let urlStr = manualCallbackURL
                                Task {
                                    await state.completeChatGPTManualCallback(urlStr)
                                    manualCallbackURL = ""
                                    syncFromConfig()
                                }
                            } label: {
                                if state.isCompletingChatGPTCallback {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Text("完成授权")
                                }
                            }
                            .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                            .disabled(state.isCompletingChatGPTCallback || manualCallbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("手动粘贴回调链接（远程浏览器或自动回传未触发时使用）")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(18)
            .glassCard(cornerRadius: 16, isSelected: connected)
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            chatgptOAuthCard

            SettingsSectionContainer(
                title: "云端大模型配置",
                subtitle: "支持 ChatGPT 订阅授权、DeepSeek、OpenAI 兼容中转站、Claude 与 Gemini 原生 API；点击任意卡片展开编辑"
            ) {
                VStack(spacing: 10) {
                    ForEach($providers) { $p in
                        let pid = p.id
                        ProviderConfigCard(
                            provider: $p,
                            chatgptModels: state.config?.chatgptOauth?.availableModels ?? [],
                            isActive: activeProviderId == pid,
                            isExpanded: expandedProviderIds.contains(pid),
                            canDelete: providers.count > 1,
                            isTesting: state.testingProviderId == pid,
                            onToggleExpand: {
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                                    if expandedProviderIds.contains(pid) {
                                        expandedProviderIds.remove(pid)
                                    } else {
                                        expandedProviderIds.insert(pid)
                                    }
                                }
                            },
                            onSetActive: {
                                activeProviderId = pid
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                                    _ = expandedProviderIds.insert(pid)
                                }
                            },
                            onTest: {
                                Task {
                                    await state.saveSettings(
                                        providers: providers,
                                        activeProviderId: activeProviderId,
                                        embedding: embedding,
                                        publicBaseUrl: publicBaseUrl
                                    )
                                    await state.testProvider(pid)
                                }
                            },
                            onDelete: {
                                providers.removeAll { $0.id == pid }
                                expandedProviderIds.remove(pid)
                                if activeProviderId == pid, let first = providers.first {
                                    activeProviderId = first.id
                                    expandedProviderIds.insert(first.id)
                                }
                            }
                        )
                    }

                    Button {
                        let newId = "custom-\(Int(Date().timeIntervalSince1970))"
                        providers.append(
                            ProviderPresetDTO(
                                id: newId,
                                name: "新中转站",
                                kind: "openai_compatible",
                                baseUrl: "https://api.openai.com/v1",
                                apiKey: "",
                                model: "gpt-6.2-sol"
                            )
                        )
                        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                            _ = expandedProviderIds.insert(newId)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                            Text("新增中转站 / 模型预设")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.accentSoft.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.accentBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Tab 2: Vector & Graph Index

    private var indexSection: some View {
        SettingsSectionContainer(
            title: "中文语义向量与图谱索引",
            subtitle: "离线本地 BGE 或自定义 Embedding API，支持双时间轴与关系图谱召回"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if let idx = state.health?.index {
                    HStack(spacing: 10) {
                        IndexMetricTile(label: "记忆总数", value: "\(idx.totalDocs)")
                        IndexMetricTile(label: "已向量化", value: "\(idx.embeddedDocs)")
                        IndexMetricTile(label: "图谱关联边", value: "\(idx.graphEdges)")
                        IndexMetricTile(label: "当前模型", value: idx.embeddingModel.components(separatedBy: "/").last ?? idx.embeddingModel, isText: true)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("向量引擎")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 96, alignment: .leading)

                        Picker("", selection: $embedding.mode) {
                            Text("本地离线中文 BGE 向量（免费隐私）").tag("local_bge_zh")
                            Text("OpenAI 兼容 Embedding API").tag("openai_compatible")
                            Text("关闭向量（仅词法 + 图谱）").tag("disabled")
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if embedding.mode == "local_bge_zh" {
                        SettingsInlineRow(label: "本地中文模型") {
                            UnifiedFieldBox {
                                TextField("BAAI/bge-small-zh-v1.5", text: $embedding.localModel)
                            }
                        }
                    } else if embedding.mode == "openai_compatible" {
                        SettingsInlineRow(label: "Base URL") {
                            UnifiedFieldBox {
                                TextField("https://api.openai.com/v1", text: $embedding.apiBaseUrl)
                            }
                        }
                        SettingsInlineRow(label: "Embedding 模型") {
                            UnifiedFieldBox {
                                TextField("text-embedding-3-small", text: $embedding.apiModel)
                            }
                        }
                        SettingsInlineRow(label: "API Key") {
                            UnifiedFieldBox {
                                SecureField(embedding.hasApiKey == true ? "已保存，留空不修改" : "粘贴 Embedding API Key", text: $embedding.apiKey)
                            }
                        }
                    }

                    HStack {
                        Spacer()
                        Button {
                            Task { await state.rebuildVectorIndex() }
                        } label: {
                            if state.isRebuildingIndex {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("重建索引中…")
                                }
                            } else {
                                Label("立即重建向量与图谱索引", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(SubtleOutlineButtonStyle())
                        .disabled(state.isRebuildingIndex)
                    }
                    .padding(.top, 4)
                }
                .padding(18)
                .glassCard(cornerRadius: 16)
            }
        }
    }

    // MARK: - Tab 3: Remote VPS Server & Mobile API / MCP

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Card 1: Remote VPS Connection & Vault Backup
            SettingsSectionContainer(
                title: "远程 VPS 服务器（桌面与手机端统一后端）",
                subtitle: "桌面端、iOS 端与 ChatGPT Remote MCP 共享同一云端记忆库与会话记录，不再在本地运行内置后端"
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        IndexMetricTile(label: "连接状态", value: state.isOnline ? "在线" : "未连接", isText: true)
                        IndexMetricTile(label: "服务版本", value: state.health?.version.map { "v\($0)" } ?? "—", isText: true)
                        IndexMetricTile(label: "记忆总数", value: state.health.map { "\($0.stats.total) 篇" } ?? "—", isText: true)
                    }

                    SettingsInlineRow(label: "远程 API 地址") {
                        UnifiedFieldBox {
                            TextField("https://decision.sakuramu.edu.kg", text: $remoteURLDraft)
                        }
                    }

                    SettingsInlineRow(label: "连接访问密码") {
                        UnifiedFieldBox {
                            SecureField("输入 VPS 访问密码 (X-Access-Token)", text: $remoteTokenDraft)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task {
                                await state.testRemoteConnection(url: remoteURLDraft, token: remoteTokenDraft)
                            }
                        } label: {
                            if state.isTestingRemoteConnection {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("校验中…")
                                }
                            } else {
                                Label("测试远程连接", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .buttonStyle(SubtleOutlineButtonStyle())
                        .disabled(state.isTestingRemoteConnection)

                        Button {
                            Task {
                                await state.saveRemoteConnection(url: remoteURLDraft, token: remoteTokenDraft)
                                syncFromConfig()
                            }
                        } label: {
                            Label("应用并重连 VPS", systemImage: "checkmark.icloud")
                        }
                        .buttonStyle(SprucePrimaryButtonStyle())

                        Spacer()

                        Button {
                            Task { await state.backupRemoteVaultToLocalICloud() }
                        } label: {
                            if state.isBackingUpVault {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.mini)
                                    Text("同步备份中…")
                                }
                            } else {
                                Label("备份回本机 iCloud", systemImage: "arrow.down.doc")
                            }
                        }
                        .buttonStyle(SubtleOutlineButtonStyle())
                        .disabled(state.isBackingUpVault || !state.isOnline)
                        .help("将 VPS 上的纯 Markdown 记忆库打包下载并同步到本地 iCloud 决策目录")
                    }

                    let cleanRemote = remoteURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let mcpURL = cleanRemote.isEmpty ? "" : "\(cleanRemote)/mcp"
                    if !mcpURL.isEmpty {
                        Rectangle().fill(Theme.borderSubtle.opacity(0.65)).frame(height: 1)
                        CopyableEndpointRow(label: "手机端 API", value: "\(cleanRemote)/api") {
                            copyToPasteboard("\(cleanRemote)/api", label: "手机端 API 地址")
                        }
                        CopyableEndpointRow(label: "ChatGPT MCP", value: mcpURL) {
                            copyToPasteboard(mcpURL, label: "ChatGPT MCP URL")
                        }
                    }

                    if !remoteTokenDraft.isEmpty {
                        Rectangle().fill(Theme.borderSubtle.opacity(0.65)).frame(height: 1)
                        HStack(spacing: 12) {
                            Text("当前密码")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 96, alignment: .leading)
                            Text("已保存在本机偏好设置（用于直连 VPS 与手机端/ChatGPT 授权）")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button {
                                copyToPasteboard(remoteTokenDraft, label: "访问密码")
                            } label: {
                                Label("复制密码", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                        }
                    }
                }
                .padding(18)
                .glassCard(cornerRadius: 16)
            }

            // Card 2: Server Public Base URL & Access Password Rotation
            SettingsSectionContainer(
                title: "服务端安全与 MCP 元数据",
                subtitle: "修改远程后端的 OAuth 公网域名或访问密码（点击右上角「保存配置」生效）"
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsInlineRow(label: "公网 HTTPS 域名") {
                        UnifiedFieldBox {
                            TextField("https://decision.sakuramu.edu.kg", text: $publicBaseUrl)
                        }
                    }

                    SettingsInlineRow(label: "重设访问密码") {
                        UnifiedFieldBox {
                            SecureField("留空表示保持当前服务端密码不变", text: $newServerPassword)
                        }
                    }
                }
                .padding(18)
                .glassCard(cornerRadius: 16)
            }
        }
    }

    // MARK: - Tab 4: Remote Git Snapshots

    private var snapshotsSection: some View {
        SettingsSectionContainer(
            title: "云端 Git 自动版本快照",
            subtitle: "由远程服务器外置 .memory-git 自动维护，每次记忆变更自动留档"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if state.gitHistory.isEmpty {
                    CalmEmptyState(
                        icon: "clock.arrow.circlepath",
                        title: "暂无快照记录",
                        subtitle: "保存或写入新记忆后会自动生成外置 Git 版本快照"
                    )
                    .frame(height: 220)
                } else {
                    ForEach(Array(state.gitHistory.prefix(15).enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 12) {
                            Text(item.hash)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                            Text(item.message)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)

                            Spacer()

                            Text(String(item.date.prefix(16)))
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        if idx < min(state.gitHistory.count, 15) - 1 {
                            Rectangle()
                                .fill(Theme.borderSubtle.opacity(0.65))
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .glassCard(cornerRadius: 16)
        }
    }
}

extension SettingsView {
    // MARK: - Tab 5: About & Updates

    fileprivate var aboutSection: some View {
        @Bindable var updater = updater
        return SettingsSectionContainer(
            title: "关于与更新",
            subtitle: "从公开仓库 GitHub Releases 检查新版本，下载后自动替换并重新打开 App"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    IndexMetricTile(label: "当前版本", value: "v\(updater.currentVersion)", isText: true)
                    IndexMetricTile(label: "最新发布", value: updater.latest.map { "v\($0.version)" } ?? "—", isText: true)
                    IndexMetricTile(label: "服务端版本", value: state.health?.version.map { "v\($0)" } ?? "—", isText: true)
                }

                HStack(spacing: 10) {
                    Image(systemName: updateStatusIcon)
                        .foregroundStyle(updater.hasUpdate ? Theme.accent : Theme.textSecondary)
                    Text(updateStatusText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await updater.check(userInitiated: true) }
                    } label: {
                        if updater.phase == .checking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("检查中…")
                            }
                        } else {
                            Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(SubtleOutlineButtonStyle())
                    .disabled(updater.isBusy)

                    if updater.hasUpdate {
                        Button {
                            Task { await updater.downloadAndInstall() }
                        } label: {
                            Label("下载并安装 v\(updater.latest?.version ?? "")", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(SprucePrimaryButtonStyle())
                        .disabled(updater.isBusy)
                    }

                    Spacer()

                    Button {
                        NSWorkspace.shared.open(updater.latest?.pageURL ?? UpdateChecker.releasesPage)
                    } label: {
                        Label("发布页", systemImage: "safari")
                    }
                    .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                }

                Rectangle().fill(Theme.borderSubtle.opacity(0.65)).frame(height: 1)

                Toggle(isOn: $updater.autoCheckEnabled) {
                    Text("启动时自动检查更新（每 12 小时最多一次）")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textPrimary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(18)
            .glassCard(cornerRadius: 16)
        }
    }

    private var updateStatusIcon: String {
        switch updater.phase {
        case .available: return "sparkles"
        case .upToDate: return "checkmark.seal"
        case .failed: return "exclamationmark.triangle"
        case .downloading, .installing, .checking: return "arrow.down.circle"
        case .idle: return "clock"
        }
    }

    private var updateStatusText: String {
        let last = updater.lastChecked.map { "上次检查：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未检查"
        switch updater.phase {
        case .idle: return last
        case .checking: return "正在连接 GitHub 检查更新…"
        case .upToDate: return "已是最新版本 · \(last)"
        case .available: return "发现新版本 v\(updater.latest?.version ?? "") · \(last)"
        case .downloading: return "正在下载新版本安装包…"
        case .installing: return "正在安装，App 将自动重启…"
        case .failed(let msg): return "检查失败：\(msg)"
        }
    }
}

// MARK: - Settings Supporting Components

private struct SettingsSectionContainer<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            content
        }
    }
}

private struct ProviderConfigCard: View {
    @Binding var provider: ProviderPresetDTO
    let chatgptModels: [ChatGPTModelOption]
    let isActive: Bool
    let isExpanded: Bool
    let canDelete: Bool
    let isTesting: Bool
    let onToggleExpand: () -> Void
    let onSetActive: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    private var isChatGPTOAuth: Bool {
        provider.kind == "chatgpt_oauth"
    }

    private var baseUrlPlaceholder: String {
        switch provider.kind {
        case "chatgpt_oauth": return "https://api.openai.com/v1"
        case "deepseek": return "https://api.deepseek.com/v1"
        case "claude": return "https://api.anthropic.com"
        case "gemini": return "https://generativelanguage.googleapis.com"
        default: return "https://api.openai.com/v1"
        }
    }

    private var modelPlaceholder: String {
        recommendedModels.first ?? "gpt-6.2-sol"
    }

    private var recommendedModels: [String] {
        switch provider.kind {
        case "chatgpt_oauth":
            if !chatgptModels.isEmpty {
                return chatgptModels.map(\.slug)
            }
            return ["gpt-5.4", "gpt-5.2", "gpt-5", "gpt-4.1", "gpt-4o"]
        case "deepseek":
            return ["deepseek-v4-pro", "deepseek-flash"]
        case "claude":
            return ["claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2", "claude-haiku-5-5"]
        case "gemini":
            return ["gemini-4-neon", "gemini-4-carbon", "gemini-4-hydrogen", "gemini-4-argon", "gemini-3.5-flash-lite"]
        default:
            return ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6.1-terra", "gpt-6-luna"]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card Header Row
            HStack(spacing: 10) {
                Button(action: onSetActive) {
                    ZStack {
                        Circle()
                            .strokeBorder(isActive ? Theme.accent : Theme.borderStrong, lineWidth: 1.8)
                            .frame(width: 17, height: 17)
                        if isActive {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 9, height: 9)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("设为默认对话模型")

                Button(action: onToggleExpand) {
                    HStack(spacing: 8) {
                        Text(provider.name.isEmpty ? "未命名预设" : provider.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        if !isExpanded && !provider.model.isEmpty {
                            Text(provider.model)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }

                        if isActive {
                            Text("默认")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.accentSoft, in: Capsule())
                        }

                        if provider.hasApiKey == true {
                            let badgeText = isChatGPTOAuth
                                ? "已授权 \(provider.apiKeyMasked ?? "")"
                                : "已配 Key \(provider.apiKeyMasked ?? "")"
                            Text(badgeText)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.success)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.successSoft, in: Capsule())
                        } else {
                            Text(isChatGPTOAuth ? "未授权" : "未填 Key")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.warning)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Theme.warningSoft, in: Capsule())
                        }

                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onTest) {
                    if isTesting {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("测试中")
                        }
                    } else {
                        Text("测试连通")
                    }
                }
                .buttonStyle(SubtleOutlineButtonStyle(compact: true))
                .disabled(isTesting)

                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.danger.opacity(0.85))
                    }
                    .buttonStyle(GhostIconButtonStyle(size: 28))
                    .help("删除此模型预设")
                }

                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GhostIconButtonStyle(size: 26))
                .help(isExpanded ? "收起详情" : "展开配置")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if isExpanded {
                Rectangle()
                    .fill(Theme.borderSubtle.opacity(0.65))
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        FieldLabel("名称")
                        UnifiedFieldBox {
                            TextField("名称", text: $provider.name)
                        }
                        FieldLabel("协议")
                        Picker("", selection: $provider.kind) {
                            Text("ChatGPT 订阅授权 (OAuth)").tag("chatgpt_oauth")
                            Text("DeepSeek 官方").tag("deepseek")
                            Text("OpenAI 兼容中转站").tag("openai_compatible")
                            Text("Claude 原生 API").tag("claude")
                            Text("Gemini 原生 API").tag("gemini")
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GridRow {
                        FieldLabel("Base URL")
                        UnifiedFieldBox {
                            TextField(baseUrlPlaceholder, text: $provider.baseUrl)
                        }
                        FieldLabel("模型名")
                        UnifiedFieldBox {
                            TextField(modelPlaceholder, text: $provider.model)
                        }
                    }

                    GridRow {
                        FieldLabel("推荐模型")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(recommendedModels, id: \.self) { candidate in
                                    let selected = provider.model.trimmingCharacters(in: .whitespacesAndNewlines) == candidate
                                    Button {
                                        provider.model = candidate
                                    } label: {
                                        Text(candidate)
                                            .font(.system(size: 11, weight: selected ? .semibold : .regular, design: .monospaced))
                                            .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                selected ? Theme.accentSoft : Theme.cardBg,
                                                in: Capsule()
                                            )
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(selected ? Theme.accentBorder : Theme.borderSubtle, lineWidth: 0.85)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .gridCellColumns(3)
                    }

                    GridRow {
                        FieldLabel(isChatGPTOAuth ? "授权方式" : "API Key")
                        if isChatGPTOAuth {
                            Text("使用上方「ChatGPT 订阅账号授权登录」OAuth 令牌自动鉴权与续期，无需填写 API Key")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.vertical, 4)
                                .gridCellColumns(3)
                        } else {
                            UnifiedFieldBox {
                                SecureField(provider.hasApiKey == true ? "已安全保存，留空表示不修改" : "粘贴 API Key", text: $provider.apiKey)
                            }
                            .gridCellColumns(3)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .glassCard(cornerRadius: 16, isSelected: isActive)
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 62, alignment: .leading)
    }
}

private struct SettingsInlineRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 96, alignment: .leading)
            content
        }
    }
}

private struct CopyableEndpointRow: View {
    let label: String
    let value: String
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 96, alignment: .leading)

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: onCopy) {
                Label("复制", systemImage: "doc.on.doc")
            }
            .buttonStyle(SubtleOutlineButtonStyle(compact: true))
        }
    }
}

private struct IndexMetricTile: View {
    let label: String
    let value: String
    var isText: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .font(.system(size: isText ? 12.5 : 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }
}
