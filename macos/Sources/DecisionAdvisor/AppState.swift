import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedSection: AdvisorSection = .chat
    var settingsPreferredTab: String = "models"
    var isSidebarVisible: Bool = true
    var isInspectorVisible: Bool = true
    var isOnline: Bool = false
    var statusBanner: String? = nil

    // Remote Server Connection
    var remoteServerURL: String
    var remoteAccessToken: String
    var isTestingRemoteConnection: Bool = false
    var isBackingUpVault: Bool = false

    private enum PrefKeys {
        static let remoteURL = "da.remote_server_url"
        static let remoteToken = "da.remote_access_token"
    }

    init() {
        let defaults = UserDefaults.standard
        let savedURL = defaults.string(forKey: PrefKeys.remoteURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.remoteServerURL = savedURL.isEmpty ? APIClient.defaultRemoteURL : savedURL

        if let savedToken = defaults.string(forKey: PrefKeys.remoteToken), !savedToken.isEmpty {
            self.remoteAccessToken = savedToken
        } else {
            let seeded = APIClient.readSeedAccessToken()
            self.remoteAccessToken = seeded
            if !seeded.isEmpty {
                defaults.set(seeded, forKey: PrefKeys.remoteToken)
            }
        }
    }

    var activeBaseURL: String {
        let cleaned = remoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? APIClient.defaultRemoteURL : cleaned
    }

    var activeAccessToken: String {
        remoteAccessToken
    }

    var localICloudVaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/决策")
    }

    // Health & Config
    var health: HealthResponse?
    var config: PublicConfigDTO?
    var gitHistory: [GitSnapshotItem] = []

    // Chat & SQLite Sessions
    var sessions: [SessionSummary] = []
    var currentSessionId: String? = nil
    var messages: [ChatMessageItem] = []
    var chatMode: ChatMode = .chat
    var selectedProviderId: String = ""
    var allowSensitive: Bool = false
    var useAsOfDate: Bool = false
    var asOfDate: Date = Date()
    var chatInput: String = ""
    var isStreaming: Bool = false

    // Semi-Auto Proposals
    var isExtractingProposals: Bool = false
    var proposals: [MemoryProposal] = []
    var showProposalSheet: Bool = false
    var isCommittingProposals: Bool = false

    // Memories / Search / Timeline / Graph
    var memoryViewMode: MemoryViewMode = .list
    var categories: [CategoryInfo] = []
    var allEmotions: [String] = []
    var selectedCategory: String = "all"
    var selectedEmotion: String = ""
    var highImportanceOnly: Bool = false
    var memoryQuery: String = ""
    var searchUseAsOf: Bool = false
    var searchAsOfDate: Date = Date()
    var memories: [MemorySummary] = []
    var timelineItems: [TimelineItem] = []
    var graphData: GraphResponse = GraphResponse(nodes: [], edges: [])
    var selectedMemoryPath: String? = nil
    var currentMemoryDetail: MemoryDetail? = nil
    var isEditingMemory: Bool = false
    var editorText: String = ""

    // Inbox
    var inboxMood: String = ""
    var inboxText: String = ""
    var inboxRawContent: String = ""

    // Settings Feedback
    var isRebuildingIndex: Bool = false
    var testingProviderId: String? = nil

    // Sign in with ChatGPT OAuth
    var chatgptAuthURL: String = ""
    var chatgptPendingState: String? = nil
    var isStartingChatGPTAuth: Bool = false
    var isAwaitingChatGPTCallback: Bool = false
    var isRefreshingChatGPTModels: Bool = false
    var isCompletingChatGPTCallback: Bool = false
    private let oauthCallbackCatcher = LocalOAuthCallbackCatcher()
    private var oauthPollingTask: Task<Void, Never>? = nil

    private var api: APIClient {
        APIClient(baseURL: activeBaseURL, accessToken: activeAccessToken)
    }

    func showBanner(_ message: String) {
        statusBanner = message
        Task {
            try? await Task.sleep(for: .seconds(3.2))
            if self.statusBanner == message {
                self.statusBanner = nil
            }
        }
    }

    func openBackendSettings() {
        settingsPreferredTab = "backend"
        selectSection(.settings)
    }

    func bootstrap() async {
        await refreshHealthAndConfig()
        await refreshSessions()
        await refreshMemories()
    }

    func saveRemoteConnection(url: String, token: String) async {
        let cleanedURL = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let finalURL = cleanedURL.isEmpty ? APIClient.defaultRemoteURL : cleanedURL
        let cleanedTok = token.trimmingCharacters(in: .whitespacesAndNewlines)

        let urlChanged = finalURL != remoteServerURL
        remoteServerURL = finalURL
        remoteAccessToken = cleanedTok
        UserDefaults.standard.set(finalURL, forKey: PrefKeys.remoteURL)
        UserDefaults.standard.set(cleanedTok, forKey: PrefKeys.remoteToken)

        if urlChanged {
            currentSessionId = nil
            messages = []
            selectedMemoryPath = nil
            currentMemoryDetail = nil
            isEditingMemory = false
        }

        await bootstrap()
        if isOnline {
            showBanner("✅ 已连接远程服务器：\(finalURL)")
        }
    }

    func testRemoteConnection(url: String, token: String) async {
        isTestingRemoteConnection = true
        defer { isTestingRemoteConnection = false }

        let cleanedURL = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetURL = cleanedURL.isEmpty ? APIClient.defaultRemoteURL : cleanedURL
        let client = APIClient(baseURL: targetURL, accessToken: token)

        let started = Date()
        do {
            let res = try await client.verifyAuth()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let ver = res.version ?? "?"
            showBanner("✅ 远程 VPS 校验通过（v\(ver) · \(ms)ms）")
        } catch {
            showBanner("❌ 远程连接校验失败：\(error.localizedDescription)")
        }
    }

    func backupRemoteVaultToLocalICloud() async {
        guard !isBackingUpVault else { return }
        isBackingUpVault = true
        defer { isBackingUpVault = false }

        do {
            let zipData = try await api.downloadVaultArchive()
            let tempZip = FileManager.default.temporaryDirectory
                .appendingPathComponent("decision-vault-\(UUID().uuidString).zip")
            try zipData.write(to: tempZip)
            defer { try? FileManager.default.removeItem(at: tempZip) }

            let dstDir = URL(fileURLWithPath: localICloudVaultPath, isDirectory: true)
            try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = ["-oq", tempZip.path, "-d", dstDir.path]
            try proc.run()
            proc.waitUntilExit()

            if proc.terminationStatus == 0 {
                showBanner("✅ 已将云端 Markdown 记忆库备份同步回本机 iCloud 目录")
            } else {
                showBanner("❌ 解压同步失败 (exit \(proc.terminationStatus))")
            }
        } catch {
            showBanner("❌ 云端备份失败：\(error.localizedDescription)")
        }
    }

    func selectSection(_ section: AdvisorSection) {
        selectedSection = section
        Task {
            if section == .memories { await refreshMemories() }
            if section == .inbox { await refreshInbox() }
            if section == .settings {
                await refreshHealthAndConfig()
                await refreshGitHistory()
            }
        }
    }

    func refreshHealthAndConfig() async {
        do {
            async let h = api.fetchHealth()
            async let c = api.fetchConfig()
            let (healthRes, cfgRes) = try await (h, c)
            self.health = healthRes
            self.config = cfgRes
            self.isOnline = true
            if self.selectedProviderId.isEmpty {
                self.selectedProviderId = cfgRes.activeProviderId
            }
        } catch {
            self.isOnline = false
            self.showBanner(error.localizedDescription)
        }
    }

    // MARK: - Sessions & Streaming Chat

    func refreshSessions() async {
        do {
            let res = try await api.fetchSessions()
            self.sessions = res.items
        } catch {
            // Keep silent if offline
        }
    }

    func openSession(_ id: String) async {
        do {
            let detail = try await api.fetchSession(id: id)
            self.currentSessionId = detail.id
            self.chatMode = ChatMode(rawValue: detail.mode) ?? .chat
            if !detail.providerId.isEmpty {
                self.selectedProviderId = detail.providerId
            }
            self.messages = detail.messages.map { dto in
                ChatMessageItem(
                    id: dto.id.map(String.init) ?? UUID().uuidString,
                    role: dto.role,
                    content: dto.content,
                    reasoning: dto.reasoning ?? "",
                    model: dto.model ?? "",
                    providerName: dto.providerName ?? "",
                    references: dto.references ?? []
                )
            }
        } catch {
            self.showBanner("加载历史对话失败：\(error.localizedDescription)")
        }
    }

    func startNewChat() {
        currentSessionId = nil
        messages = []
    }

    func deleteSession(_ id: String) async {
        do {
            try await api.deleteSession(id: id)
            if currentSessionId == id {
                startNewChat()
            }
            await refreshSessions()
            showBanner("已删除历史对话")
        } catch {
            showBanner(error.localizedDescription)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    func sendChat(overrideText: String? = nil) async {
        guard !isStreaming else { return }
        let text = (overrideText ?? chatInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        chatInput = ""
        let historyToSend = messages + [ChatMessageItem(role: "user", content: text)]
        messages.append(ChatMessageItem(role: "user", content: text))

        let assistantIdx = messages.count
        messages.append(ChatMessageItem(role: "assistant", content: "", isStreaming: true))
        isStreaming = true

        let asOfStr = useAsOfDate ? formatDate(asOfDate) : nil
        let stream = api.streamChat(
            sessionId: currentSessionId,
            messages: historyToSend,
            mode: chatMode,
            providerId: selectedProviderId.isEmpty ? nil : selectedProviderId,
            allowSensitive: allowSensitive,
            asOf: asOfStr
        )

        do {
            for try await event in stream {
                guard assistantIdx < messages.count else { break }
                switch event {
                case .meta(let sid, let pname, let model, let refs):
                    if !sid.isEmpty { currentSessionId = sid }
                    messages[assistantIdx].providerName = pname
                    messages[assistantIdx].model = model
                    messages[assistantIdx].references = refs
                case .reasoning(let delta):
                    messages[assistantIdx].reasoning += delta
                case .text(let delta):
                    messages[assistantIdx].content += delta
                case .error(let detail):
                    messages[assistantIdx].content = "⚠️ 调用失败：\(detail)\n\n请在「模型与设置」中检查对应模型的 API Key 与 Base URL。"
                case .done(let sid):
                    if !sid.isEmpty { currentSessionId = sid }
                }
            }
        } catch {
            if assistantIdx < messages.count {
                messages[assistantIdx].content = "⚠️ 连接失败：\(error.localizedDescription)"
            }
        }

        if assistantIdx < messages.count {
            messages[assistantIdx].isStreaming = false
        }
        isStreaming = false
        await refreshSessions()
    }

    // MARK: - Semi-Auto Proposals

    func extractProposals() async {
        guard !messages.isEmpty, !isExtractingProposals else { return }
        isExtractingProposals = true
        defer { isExtractingProposals = false }
        do {
            let res = try await api.extractProposals(
                sessionId: currentSessionId,
                messages: messages,
                providerId: selectedProviderId.isEmpty ? nil : selectedProviderId,
                allowSensitive: allowSensitive
            )
            if res.proposals.isEmpty {
                showBanner("本轮对话暂无需要新沉淀的正式记忆")
                return
            }
            self.proposals = res.proposals
            self.showProposalSheet = true
        } catch {
            showBanner("提炼失败：\(error.localizedDescription)")
        }
    }

    func commitSelectedProposals() async {
        let chosen = proposals.filter { $0.selected }
        guard !chosen.isEmpty else {
            showBanner("请至少勾选 1 条记忆")
            return
        }
        isCommittingProposals = true
        defer { isCommittingProposals = false }
        do {
            let res = try await api.commitProposals(sessionId: currentSessionId, proposals: chosen)
            showProposalSheet = false
            showBanner("已写入 \(res.written.count) 篇记忆并生成 Git 快照")
            await refreshHealthAndConfig()
            await refreshMemories()
        } catch {
            showBanner("写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Memories / Timeline / Graph

    func refreshMemories() async {
        do {
            switch memoryViewMode {
            case .list:
                let res = try await api.fetchMemories(
                    category: selectedCategory,
                    query: memoryQuery,
                    emotion: selectedEmotion,
                    minImportance: highImportanceOnly ? 7 : 1
                )
                if let cats = res.categories {
                    self.categories = [CategoryInfo(id: "all", label: "全部")] + cats
                }
                if let emos = res.emotions {
                    self.allEmotions = emos
                }
                self.memories = res.items
                if self.selectedMemoryPath == nil, let first = res.items.first {
                    await self.openMemory(path: first.path)
                }
            case .semantic:
                let q = memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if q.isEmpty {
                    self.memories = []
                } else {
                    let res = try await api.semanticSearch(
                        query: q,
                        asOf: searchUseAsOf ? formatDate(searchAsOfDate) : ""
                    )
                    self.memories = res.items
                if self.selectedMemoryPath == nil, let first = res.items.first {
                    await self.openMemory(path: first.path)
                }
                }
            case .timeline:
                let res = try await api.fetchTimeline()
                self.timelineItems = res.items
            case .graph:
                self.graphData = try await api.fetchGraph()
            }
        } catch {
            showBanner("加载记忆失败：\(error.localizedDescription)")
        }
    }

    func openMemory(path: String) async {
        selectedMemoryPath = path
        do {
            let detail = try await api.fetchMemoryFile(path: path)
            self.currentMemoryDetail = detail
            self.editorText = detail.raw
            self.isEditingMemory = false
        } catch {
            showBanner("读取记忆失败：\(error.localizedDescription)")
        }
    }

    func jumpToMemory(path: String) async {
        selectedSection = .memories
        memoryViewMode = .list
        await refreshMemories()
        await openMemory(path: path)
    }

    func saveEditedMemory() async {
        guard let detail = currentMemoryDetail else { return }
        do {
            try await api.saveMemoryFile(path: detail.path, content: editorText)
            showBanner("已保存到 VPS 云端并刷新索引与快照")
            await openMemory(path: detail.path)
            await refreshMemories()
            await refreshHealthAndConfig()
        } catch {
            showBanner("保存失败：\(error.localizedDescription)")
        }
    }

    func deleteCurrentMemory() async {
        guard let detail = currentMemoryDetail else { return }
        do {
            try await api.deleteMemoryFile(path: detail.path)
            selectedMemoryPath = nil
            currentMemoryDetail = nil
            isEditingMemory = false
            showBanner("已删除记忆并记录 Git 快照")
            await refreshMemories()
            await refreshHealthAndConfig()
        } catch {
            showBanner("删除失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Inbox

    func refreshInbox() async {
        do {
            let doc = try await api.fetchMemoryFile(path: "99-收件箱/inbox.md")
            self.inboxRawContent = doc.body
        } catch {
            self.inboxRawContent = ""
        }
    }

    func submitInbox() async {
        let text = inboxText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showBanner("先写下此刻的感受或想法吧")
            return
        }
        do {
            try await api.addInbox(text: text, mood: inboxMood)
            inboxText = ""
            inboxMood = ""
            showBanner("已存入收件箱并同步 iCloud")
            await refreshInbox()
            await refreshHealthAndConfig()
        } catch {
            showBanner(error.localizedDescription)
        }
    }

    // MARK: - Settings

    func refreshGitHistory() async {
        do {
            let res = try await api.fetchGitHistory()
            self.gitHistory = res.items
        } catch {}
    }

    func saveSettings(
        providers: [ProviderPresetDTO],
        activeProviderId: String,
        embedding: EmbeddingConfigDTO,
        publicBaseUrl: String,
        newAccessToken: String? = nil
    ) async {
        var payload: [String: Any] = [
            "active_provider_id": activeProviderId,
            "public_base_url": publicBaseUrl,
            "providers": providers.map {
                [
                    "id": $0.id,
                    "name": $0.name,
                    "kind": $0.kind,
                    "base_url": $0.baseUrl,
                    "model": $0.model,
                    "api_key": $0.apiKey,
                ]
            },
            "embedding": [
                "mode": embedding.mode,
                "local_model": embedding.localModel,
                "api_base_url": embedding.apiBaseUrl,
                "api_model": embedding.apiModel,
                "api_key": embedding.apiKey,
            ],
        ]
        if let tok = newAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !tok.isEmpty {
            payload["access_token"] = tok
        }
        do {
            let updated = try await api.saveConfig(payload)
            if let tok = newAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !tok.isEmpty {
                remoteAccessToken = tok
                UserDefaults.standard.set(tok, forKey: PrefKeys.remoteToken)
            }
            self.config = updated
            self.selectedProviderId = updated.activeProviderId
            showBanner("✅ 设置已保存")
        } catch {
            showBanner("保存设置失败：\(error.localizedDescription)")
        }
    }

    func testProvider(_ id: String) async {
        testingProviderId = id
        defer { testingProviderId = nil }
        do {
            let res = try await api.testProvider(providerId: id)
            showBanner("✅ \(res.provider) 连通成功：\(res.reply)")
        } catch {
            showBanner("❌ 连通失败：\(error.localizedDescription)")
        }
    }

    func rebuildVectorIndex() async {
        isRebuildingIndex = true
        defer { isRebuildingIndex = false }
        do {
            let res = try await api.rebuildIndex()
            showBanner("索引完成：\(res.embeddedDocs)/\(res.totalDocs) 篇已向量化，\(res.graphEdges) 条图谱边")
            await refreshHealthAndConfig()
        } catch {
            showBanner("重建失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Sign in with ChatGPT (OAuth 2.0 PKCE + Subscription Quota)

    func cancelChatGPTLoginWait() {
        oauthPollingTask?.cancel()
        oauthPollingTask = nil
        oauthCallbackCatcher.stop()
        isAwaitingChatGPTCallback = false
        chatgptPendingState = nil
    }

    func startChatGPTLogin(forceRegister: Bool = false, openBrowser: Bool = true) async {
        guard !isStartingChatGPTAuth else { return }
        isStartingChatGPTAuth = true
        defer { isStartingChatGPTAuth = false }

        cancelChatGPTLoginWait()

        var redirectPort: Int? = nil
        let remoteClient = self.api
        do {
            let port = try await oauthCallbackCatcher.start { [weak self] callbackURL in
                do {
                    let res = try await remoteClient.completeChatGPTOAuthCallback(callbackUrl: callbackURL)
                    await MainActor.run {
                        guard let self else { return }
                        self.config = res.config
                        self.selectedProviderId = res.config.activeProviderId
                        self.isAwaitingChatGPTCallback = false
                        self.chatgptPendingState = nil
                        let count = res.oauth.availableModels.count
                        let email = res.oauth.accountEmail.isEmpty ? "ChatGPT 账号" : res.oauth.accountEmail
                        self.showBanner(
                            count > 0
                                ? "✅ \(email) 授权成功，已同步 \(count) 个可用模型"
                                : "✅ \(email) 授权成功，可直接调用 GPT 模型"
                        )
                    }
                    let emailText = res.oauth.accountEmail.isEmpty ? "你的 ChatGPT 账号" : res.oauth.accountEmail
                    return (
                        true,
                        "ChatGPT 授权登录成功",
                        "\(emailText) 已授权完成并同步到你的决策顾问后端，现在可以直接调用订阅额度和模型。"
                    )
                } catch {
                    await MainActor.run {
                        guard let self else { return }
                        self.isAwaitingChatGPTCallback = false
                        self.showBanner("❌ 授权回调处理失败：\(error.localizedDescription)")
                    }
                    return (false, "ChatGPT 授权未完成", error.localizedDescription)
                }
            }
            redirectPort = port
        } catch {
            showBanner("⚠️ 启动本机回调端口失败，将改用手动粘贴回调链接模式：\(error.localizedDescription)")
        }

        do {
            let res = try await api.startChatGPTOAuth(
                forceRegister: forceRegister,
                redirectPort: redirectPort
            )
            chatgptAuthURL = res.authUrl
            chatgptPendingState = res.state
            isAwaitingChatGPTCallback = true

            if openBrowser, let url = URL(string: res.authUrl) {
                NSWorkspace.shared.open(url)
                showBanner("已在浏览器打开 ChatGPT 官方授权页，完成登录并同意额度权限后将自动回传")
            } else {
                showBanner("已生成 ChatGPT 官方授权登录链接，可点击复制并在浏览器打开")
            }

            // Poll backend status so embedded-local callbacks (or manual callback pastes) refresh UI automatically
            let stateToken = res.state
            let client = self.api
            oauthPollingTask = Task { @MainActor [weak self] in
                for _ in 0..<180 {
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(1.8))
                    if Task.isCancelled { return }
                    guard let self else { return }
                    if !self.isAwaitingChatGPTCallback { return }
                    do {
                        let st = try await client.fetchChatGPTOAuthStatus(state: stateToken)
                        if let flow = st.flow {
                            if flow.status == "completed" {
                                self.isAwaitingChatGPTCallback = false
                                self.chatgptPendingState = nil
                                self.oauthCallbackCatcher.stop()
                                await self.refreshHealthAndConfig()
                                if let cfg = self.config,
                                   let gpt = cfg.providers.first(where: { $0.kind == "chatgpt_oauth" }) {
                                    self.selectedProviderId = cfg.activeProviderId.isEmpty ? gpt.id : cfg.activeProviderId
                                }
                                let email = st.accountEmail.isEmpty ? "ChatGPT 账号" : st.accountEmail
                                self.showBanner("✅ \(email) 授权登录成功，已同步 \(st.availableModels.count) 个模型")
                                return
                            } else if flow.status == "error" {
                                self.isAwaitingChatGPTCallback = false
                                self.chatgptPendingState = nil
                                self.oauthCallbackCatcher.stop()
                                self.showBanner("❌ ChatGPT 授权失败：\(flow.error)")
                                return
                            }
                        }
                    } catch {
                        // Keep polling across transient network hiccups
                    }
                }
            }
        } catch {
            cancelChatGPTLoginWait()
            showBanner("❌ 生成 ChatGPT 授权链接失败：\(error.localizedDescription)")
        }
    }

    func completeChatGPTManualCallback(_ callbackURL: String) async {
        let trimmed = callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showBanner("请先粘贴浏览器地址栏里的完整回调链接")
            return
        }
        isCompletingChatGPTCallback = true
        defer { isCompletingChatGPTCallback = false }
        do {
            let res = try await api.completeChatGPTOAuthCallback(callbackUrl: trimmed)
            cancelChatGPTLoginWait()
            self.config = res.config
            self.selectedProviderId = res.config.activeProviderId
            let email = res.oauth.accountEmail.isEmpty ? "ChatGPT 账号" : res.oauth.accountEmail
            showBanner("✅ \(email) 授权成功，已同步 \(res.oauth.availableModels.count) 个可用模型")
        } catch {
            showBanner("❌ 回调授权失败：\(error.localizedDescription)")
        }
    }

    func refreshChatGPTModels() async {
        guard !isRefreshingChatGPTModels else { return }
        isRefreshingChatGPTModels = true
        defer { isRefreshingChatGPTModels = false }
        do {
            let res = try await api.refreshChatGPTModels()
            self.config = res.config
            showBanner("✅ 已刷新 ChatGPT 可用模型，共 \(res.models.count) 个")
        } catch {
            showBanner("❌ 刷新模型失败：\(error.localizedDescription)")
        }
    }

    func logoutChatGPT(resetClient: Bool = false) async {
        cancelChatGPTLoginWait()
        do {
            let res = try await api.logoutChatGPTOAuth(resetClient: resetClient)
            self.config = res.config
            self.chatgptAuthURL = ""
            showBanner(resetClient ? "已退出 ChatGPT 并重置客户端注册" : "已退出 ChatGPT 授权登录")
        } catch {
            showBanner("❌ 退出失败：\(error.localizedDescription)")
        }
    }
}
