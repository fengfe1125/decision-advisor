import Network
import SwiftUI

typealias Proposal = AdvisorAPI.Proposal

/// 手动新建记忆时可选的类别，路径规则与后端提案保持一致。
enum MemoryKind: String, CaseIterable, Identifiable {
    case experience = "经历与感受"
    case relation = "重要关系"
    case decision = "决策实验室"

    var id: String { rawValue }

    var type: String {
        switch self {
        case .experience: "经历"
        case .relation: "人物"
        case .decision: "决策"
        }
    }

    func path(title: String, day: String) -> String {
        let name = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#\n\r\t"))
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        let safe = String((name.isEmpty ? "未命名" : name).prefix(40))
        switch self {
        case .experience: return "02-经历与感受/\(day.prefix(4))/\(day)-\(safe).md"
        case .relation: return "03-重要关系/\(safe).md"
        case .decision: return "04-决策实验室/进行中/\(day)-\(safe).md"
        }
    }
}

enum ChatMode: String, CaseIterable, Identifiable {
    case chat, decision, interview, reflect
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: "日常倾诉"
        case .decision: "9步决策"
        case .interview: "深度访谈"
        case .reflect: "周期反思"
        }
    }

    var shortLabel: String {
        switch self {
        case .chat: "日常"
        case .decision: "决策"
        case .interview: "访谈"
        case .reflect: "复盘"
        }
    }

    var icon: String {
        switch self {
        case .chat: "bubble.left"
        case .decision: "safari"
        case .interview: "mic"
        case .reflect: "sparkles"
        }
    }

    var heroTitle: String {
        switch self {
        case .chat: "今天想聊点什么？"
        case .decision: "冷静拆解这个重要选择"
        case .interview: "建立你的个人记忆档案"
        case .reflect: "回望近期轨迹与情绪模式"
        }
    }

    var placeholder: String {
        switch self {
        case .chat: "说说今天的经历、情绪或正在思考的事…"
        case .decision: "描述你正在权衡的决定与顾虑…"
        case .interview: "聊聊你的背景、价值取向或早期经历…"
        case .reflect: "指定想回顾的时间段、人物或情绪主题…"
        }
    }
}

@MainActor
final class AdvisorModel: ObservableObject {
    @AppStorage("advisor-server") private var savedServer = "https://decision.sakuramu.edu.kg"
    @Published var server = "https://decision.sakuramu.edu.kg"
    @Published var password = ""
    @Published var connected = false
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published private(set) var extracting = false
    @Published private(set) var syncing = false
    @Published private(set) var online = true
    @Published private(set) var conversations: [StoredConversation] = []
    @Published var activeID: String?
    @Published var draft = ""
    @Published var mode = ChatMode.chat
    @Published var useAsOfDate = false
    @Published var asOfDate = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date()
    @Published var allowSensitive = false
    @Published var proposals: [Proposal] = []
    @Published private(set) var memories: [CachedMemory] = []
    @Published var memoryFile: AdvisorAPI.MemoryFile?
    @Published private(set) var outbox: [OutboxItem] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSyncFailure: String?

    private let monitor = NWPathMonitor()
    private var cachedMemories: [CachedMemory] = []
    private var streamErrors: [String: String] = [:]
    private var activeStreamTask: Task<Void, Error>?
    private var activeStreamMetaReceived = false

    init() {
        server = savedServer
        password = AdvisorPassword.load(server: savedServer)
        let snapshot = AdvisorStore.load()
        conversations = snapshot.conversations
        outbox = snapshot.outbox
        cachedMemories = snapshot.memories
        memories = snapshot.memories
        lastSync = snapshot.lastSync
        // 清理异常退出残留的 streaming 占位消息
        for c in conversations.indices {
            conversations[c].messages.removeAll { $0.state == .streaming && $0.content.isEmpty }
            for m in conversations[c].messages.indices where conversations[c].messages[m].state == .streaming {
                conversations[c].messages[m].state = .sent
            }
        }
        // 钥匙串里有密码就直接进入，离线也能看历史、记东西；联网后再校验。
        connected = !password.isEmpty
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let cameBack = reachable && !self.online
                self.online = reachable
                if cameBack { await self.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "advisor.network"))
    }

    // MARK: - 派生状态

    var active: StoredConversation? { conversations.first { $0.id == activeID } }
    var messages: [StoredMessage] { active?.messages ?? [] }
    var isReplying: Bool { messages.contains { $0.state == .streaming } }
    var pendingCount: Int { outbox.filter { $0.failure == nil }.count }
    var failedItems: [OutboxItem] { outbox.filter { $0.failure != nil } }

    var formattedAsOf: String {
        Self.dayFormatter.string(from: asOfDate)
    }

    var canExtractMemories: Bool {
        guard let active else { return false }
        return !active.messages.isEmpty && !active.isLocal && !busy && !extracting && !isReplying && online
    }

    func outboxItem(for message: StoredMessage) -> OutboxItem? {
        outbox.first {
            if case .chat(_, let id) = $0.kind { return id == message.id }
            return false
        }
    }

    private func api() throws -> AdvisorAPI {
        try AdvisorAPI(baseURL: AdvisorAPI.validateURL(server), password: password)
    }

    private func persist() {
        AdvisorStore.save(AdvisorSnapshot(
            conversations: conversations, outbox: outbox, memories: cachedMemories, lastSync: lastSync
        ))
    }

    // MARK: - 连接

    func connect() async {
        await perform {
            let client = try api()
            guard !client.password.isEmpty else {
                throw AdvisorAPI.APIError(errorDescription: "请输入 VPS 的访问密码。")
            }
            var publicClient = client
            publicClient.password = ""
            let auth: AdvisorAPI.AuthStatus = try await publicClient.request("api/auth/status")
            guard auth.authRequired else {
                throw AdvisorAPI.APIError(errorDescription: "请先在 VPS 上启用访问密码。")
            }
            let result: AdvisorAPI.Verification = try await client.request("api/auth/verify", method: "POST")
            guard result.deploymentMode == "remote_vps" else {
                throw AdvisorAPI.APIError(errorDescription: "该地址没有启用 VPS 模式。")
            }
            if server != savedServer { eraseLocalData() }
            try AdvisorPassword.save(password, server: server)
            savedServer = server
            connected = true
        }
        if connected { await sync() }
    }

    /// 断开并清空本机缓存（包括还没上传的内容）。
    func disconnect() {
        guard !busy else { return }
        stopReplying()
        AdvisorPassword.remove(server: server)
        password = ""
        connected = false
        eraseLocalData()
    }

    private func eraseLocalData() {
        conversations = []
        outbox = []
        memories = []
        cachedMemories = []
        lastSync = nil
        lastSyncFailure = nil
        newConversation()
        AdvisorStore.erase()
    }

    private func handleUnauthorized() {
        AdvisorPassword.remove(server: server)
        password = ""
        connected = false
        error = "访问密码已失效，请重新输入。未上传的内容仍保留在手机上。"
    }

    // MARK: - 同步

    /// 先把本机排队的内容按顺序传到 VPS，再拉取服务器上的会话列表。
    func sync() async {
        guard connected, !syncing else { return }
        syncing = true
        lastSyncFailure = nil
        defer { syncing = false }
        do {
            let client = try api()
            repeat {
                try await flushOutbox(client)
                try await pullSessions(client)
            } while outbox.contains { $0.failure == nil }
            lastSync = Date()
            lastSyncFailure = nil
            persist()
        } catch is CancellationError {
            persist()
        } catch let failure as AdvisorAPI.APIError where failure.status == 401 {
            handleUnauthorized()
        } catch {
            // 网络不可用或服务器暂时出错：内容留在队列里，同时记录原因以便界面提示重试。
            if online {
                lastSyncFailure = error.localizedDescription
            }
            persist()
        }
    }

    /// 手动中止正在流式输出的回复。
    func stopReplying() {
        activeStreamTask?.cancel()
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? AdvisorAPI.APIError, let status = failure.status {
            return status == 401 || status == 408 || status == 429 || status >= 500
        }
        return true
    }

    private func flushOutbox(_ client: AdvisorAPI) async throws {
        while let item = outbox.first(where: { $0.failure == nil }) {
            do {
                switch item.kind {
                case .chat(let conversationID, let messageID):
                    try await deliverChat(item, conversationID: conversationID, messageID: messageID, client: client)
                case .note(let text):
                    let _: AdvisorAPI.SaveResult = try await client.request(
                        "api/inbox", method: "POST", body: ["text": text, "client_id": item.clientID]
                    )
                    finish(item)
                case .memory(let path, let content, let title):
                    let _: AdvisorAPI.SaveResult = try await client.request(
                        "api/memories/file", method: "PUT",
                        body: ["path": path, "content": content, "create_only": true,
                               "commit_message": "mobile: 手机新建记忆 \(title)"]
                    )
                    finish(item)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Self.isTransient(error) { throw error }
                fail(item, reason: error.localizedDescription)
            }
        }
    }

    private func finish(_ item: OutboxItem) {
        outbox.removeAll { $0.clientID == item.clientID }
        persist()
    }

    private func fail(_ item: OutboxItem, reason: String) {
        guard let index = outbox.firstIndex(where: { $0.clientID == item.clientID }) else { return }
        outbox[index].failure = reason
        if case .chat(_, let messageID) = item.kind, let (c, m) = locate(messageID) {
            conversations[c].messages[m].state = .failed
            conversations[c].messages[m].failure = reason
        }
        persist()
    }

    private func locate(_ messageID: String) -> (Int, Int)? {
        for (c, conversation) in conversations.enumerated() {
            if let m = conversation.messages.firstIndex(where: { $0.id == messageID }) { return (c, m) }
        }
        return nil
    }

    private func deliverChat(
        _ item: OutboxItem, conversationID: String, messageID: String, client: AdvisorAPI
    ) async throws {
        guard let (c, m) = locate(messageID) else { return finish(item) }
        let conversation = conversations[c]
        let history = conversation.messages[...m]
            .filter { $0.state == .sent || $0.id == messageID }
            .suffix(20)
            .map { ["role": $0.role, "content": $0.content] }
        var body: [String: Any] = [
            "messages": Array(history),
            "mode": conversation.mode,
            "client_id": item.clientID,
            "allow_sensitive": item.allowSensitive ?? false,
        ]
        if let asOf = item.asOf, !asOf.isEmpty { body["as_of"] = asOf }
        if !conversation.isLocal { body["session_id"] = conversation.id }

        let replyID = "reply-\(item.clientID)"
        conversations[c].messages.removeAll { $0.id == replyID }
        conversations[c].messages.insert(
            StoredMessage(id: replyID, role: "assistant", content: "", state: .streaming), at: m + 1
        )
        streamErrors[replyID] = nil
        activeStreamMetaReceived = false

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let streamTask = Task {
            try await client.stream("api/chat/stream", bodyData: bodyData) { [weak self] event in
                guard let self else { return }
                switch event.type {
                case "meta":
                    self.activeStreamMetaReceived = true
                    if let id = event.sessionId { self.adopt(serverID: id, forMessage: messageID) }
                    self.applyMeta(event, to: replyID)
                case "reasoning":
                    self.appendReasoning(event.delta ?? "", to: replyID)
                case "text":
                    self.appendReply(event.delta ?? "", to: replyID)
                case "error":
                    self.streamErrors[replyID] = event.detail ?? "模型没有回应。"
                default:
                    break
                }
            }
        }
        activeStreamTask = streamTask
        defer { activeStreamTask = nil }

        do {
            try await streamTask.value
        } catch is CancellationError {
            handleCancelledStream(item: item, messageID: messageID, replyID: replyID)
            throw CancellationError()
        } catch {
            if streamTask.isCancelled || (error as? URLError)?.code == .cancelled {
                handleCancelledStream(item: item, messageID: messageID, replyID: replyID)
                throw CancellationError()
            }
            removeReply(replyID)
            throw error
        }

        if let streamError = streamErrors.removeValue(forKey: replyID) {
            removeReply(replyID)
            throw AdvisorAPI.APIError(errorDescription: streamError, status: 400)
        }
        if let (rc, rm) = locate(replyID) {
            conversations[rc].messages[rm].state = .sent
            if conversations[rc].messages[rm].content.isEmpty && (conversations[rc].messages[rm].reasoning ?? "").isEmpty {
                conversations[rc].messages.remove(at: rm)
            }
        }
        if let (uc, um) = locate(messageID) {
            conversations[uc].messages[um].state = .sent
            conversations[uc].messages[um].failure = nil
            conversations[uc].updatedAt = Self.now()
        }
        finish(item)
    }

    private func handleCancelledStream(item: OutboxItem, messageID: String, replyID: String) {
        if let (rc, rm) = locate(replyID) {
            let hasContent = !conversations[rc].messages[rm].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasContent {
                conversations[rc].messages[rm].state = .sent
            } else {
                conversations[rc].messages.remove(at: rm)
            }
        }
        if activeStreamMetaReceived {
            // 服务器已经收到请求，结束排队避免下次同步重复重发。
            if let (uc, um) = locate(messageID) {
                conversations[uc].messages[um].state = .sent
                conversations[uc].messages[um].failure = nil
            }
            finish(item)
        } else {
            // 尚未到达服务器前即手动取消，标记失败以便用户决定重试或删除。
            fail(item, reason: "已手动停止")
        }
    }

    private func applyMeta(_ event: AdvisorAPI.StreamEvent, to replyID: String) {
        guard let (c, m) = locate(replyID) else { return }
        if let model = event.model, !model.isEmpty { conversations[c].messages[m].modelName = model }
        if let provider = event.providerName, !provider.isEmpty { conversations[c].messages[m].providerName = provider }
        if let refs = event.references, !refs.isEmpty { conversations[c].messages[m].references = refs }
    }

    private func appendReasoning(_ delta: String, to replyID: String) {
        guard !delta.isEmpty, let (c, m) = locate(replyID) else { return }
        conversations[c].messages[m].reasoning = (conversations[c].messages[m].reasoning ?? "") + delta
    }

    private func appendReply(_ delta: String, to replyID: String) {
        guard !delta.isEmpty, let (c, m) = locate(replyID) else { return }
        conversations[c].messages[m].content += delta
    }

    private func removeReply(_ replyID: String) {
        guard let (c, m) = locate(replyID) else { return }
        conversations[c].messages.remove(at: m)
    }

    /// 本机新会话第一次上传后换成服务器编号。
    private func adopt(serverID: String, forMessage messageID: String) {
        guard let (c, _) = locate(messageID), conversations[c].id != serverID else { return }
        let old = conversations[c].id
        conversations.removeAll { $0.id == serverID }
        guard let (c2, _) = locate(messageID) else { return }
        conversations[c2].id = serverID
        conversations[c2].loaded = true
        if activeID == old { activeID = serverID }
        for index in outbox.indices {
            if case .chat(let cid, let mid) = outbox[index].kind, cid == old {
                outbox[index].kind = .chat(conversationID: serverID, messageID: mid)
            }
        }
        persist()
    }

    private func pullSessions(_ client: AdvisorAPI) async throws {
        let response: AdvisorAPI.Items<AdvisorAPI.Session> = try await client.request(
            "api/sessions", query: [.init(name: "limit", value: "200")]
        )
        let busyIDs = Set(outbox.compactMap { item -> String? in
            if case .chat(let cid, _) = item.kind { return cid }
            return nil
        })
        var merged: [StoredConversation] = conversations.filter { $0.isLocal || busyIDs.contains($0.id) }
        let kept = Set(merged.map(\.id))
        for remote in response.items where !kept.contains(remote.id) {
            var entry = conversations.first { $0.id == remote.id }
                ?? StoredConversation(id: remote.id, title: remote.title, updatedAt: remote.updatedAt ?? "")
            if entry.updatedAt != remote.updatedAt { entry.loaded = false }
            entry.title = remote.title
            entry.mode = remote.mode ?? entry.mode
            entry.updatedAt = remote.updatedAt ?? entry.updatedAt
            merged.append(entry)
        }
        conversations = merged.sorted { Self.date($0.updatedAt) > Self.date($1.updatedAt) }
        if let activeID, conversations.first(where: { $0.id == activeID }) == nil { newConversation() }
        if let active, !active.loaded, !active.isLocal { try await loadMessages(active.id, client: client) }
        persist()
    }

    private func loadMessages(_ id: String, client: AdvisorAPI) async throws {
        let detail: AdvisorAPI.Session = try await client.request("api/sessions/\(id)")
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let unsent = conversations[index].messages.filter { $0.state != .sent }
        conversations[index].messages = (detail.messages ?? []).map {
            StoredMessage(
                id: "srv-\($0.id ?? 0)",
                role: $0.role,
                content: $0.content,
                reasoning: ($0.reasoning?.isEmpty == false) ? $0.reasoning : nil,
                modelName: ($0.model?.isEmpty == false) ? $0.model : nil,
                providerName: ($0.providerName?.isEmpty == false) ? $0.providerName : nil,
                references: ($0.references?.isEmpty == false) ? $0.references : nil
            )
        } + unsent
        conversations[index].loaded = true
        persist()
    }

    private static let iso = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func now() -> String { iso.string(from: Date()) }
    private static func date(_ text: String) -> Date { iso.date(from: text) ?? .distantPast }

    // MARK: - 对话

    func newConversation() {
        activeID = nil
        draft = ""
        proposals = []
    }

    func open(_ conversation: StoredConversation) async {
        activeID = conversation.id
        mode = ChatMode(rawValue: conversation.mode) ?? .chat
        proposals = []
        guard !conversation.isLocal, online, let client = try? api() else { return }
        try? await loadMessages(conversation.id, client: client)
    }

    func send() async {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !isReplying else { return }
        if activeID == nil {
            let conversation = StoredConversation(
                id: "local-\(UUID().uuidString)", title: String(content.prefix(40)),
                mode: mode.rawValue, updatedAt: Self.now(), loaded: true
            )
            conversations.insert(conversation, at: 0)
            activeID = conversation.id
        }
        guard let activeID, let index = conversations.firstIndex(where: { $0.id == activeID }) else { return }
        let message = StoredMessage(id: UUID().uuidString, role: "user", content: content, state: .pending)
        conversations[index].messages.append(message)
        conversations[index].updatedAt = Self.now()
        outbox.append(OutboxItem(
            clientID: UUID().uuidString,
            kind: .chat(conversationID: activeID, messageID: message.id),
            createdAt: Date(),
            allowSensitive: allowSensitive ? true : nil,
            asOf: useAsOfDate ? formattedAsOf : nil
        ))
        draft = ""
        persist()
        await sync()
    }

    /// 把当前聊天草稿直接存进「99-收件箱/inbox.md」，不触发对话。
    func saveDraftToInbox() async {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        draft = ""
        await saveNote(content)
        if online && error == nil {
            notice = "已存入收件箱速记。"
        }
    }

    func retry(_ item: OutboxItem) async {
        guard let index = outbox.firstIndex(where: { $0.clientID == item.clientID }) else { return }
        outbox[index].failure = nil
        if case .chat(_, let messageID) = item.kind, let (c, m) = locate(messageID) {
            conversations[c].messages[m].state = .pending
            conversations[c].messages[m].failure = nil
        }
        persist()
        await sync()
    }

    func discard(_ item: OutboxItem) {
        outbox.removeAll { $0.clientID == item.clientID }
        if case .chat(_, let messageID) = item.kind, let (c, m) = locate(messageID) {
            conversations[c].messages.remove(at: m)
            if conversations[c].isLocal && conversations[c].messages.isEmpty {
                if activeID == conversations[c].id { newConversation() }
                conversations.remove(at: c)
            }
        }
        persist()
    }

    func delete(_ conversation: StoredConversation) async {
        if !conversation.isLocal {
            await perform {
                let _: AdvisorAPI.SaveResult = try await api().request(
                    "api/sessions/\(conversation.id)", method: "DELETE"
                )
            }
            guard error == nil else { return }
        }
        outbox.removeAll {
            if case .chat(let cid, _) = $0.kind { return cid == conversation.id }
            return false
        }
        conversations.removeAll { $0.id == conversation.id }
        if activeID == conversation.id { newConversation() }
        persist()
    }

    func changeMode(_ value: ChatMode) {
        mode = value
        guard let activeID, let index = conversations.firstIndex(where: { $0.id == activeID }) else { return }
        conversations[index].mode = value.rawValue
        persist()
    }

    // MARK: - 记忆提案

    func extract() async {
        guard let active, !active.messages.isEmpty, !extracting else { return }
        guard !active.isLocal else {
            notice = "这段对话还没上传到 VPS，上传后再提炼记忆。"
            return
        }
        extracting = true
        defer { extracting = false }
        await perform {
            let recent = active.messages.filter { $0.state == .sent }.suffix(16)
                .map { ["role": $0.role, "content": $0.content] }
            let result: AdvisorAPI.ProposalList = try await api().request(
                "api/proposals/extract", method: "POST",
                body: [
                    "session_id": active.id,
                    "messages": Array(recent),
                    "allow_sensitive": allowSensitive,
                ]
            )
            proposals = result.proposals
            if proposals.isEmpty { notice = "这段对话暂时没有记忆提案。" }
        }
    }

    func saveProposals(_ ids: Set<String>) async {
        guard let activeID, !ids.isEmpty else { return }
        await perform {
            let chosen = proposals.filter { ids.contains($0.id) }
            let result: AdvisorAPI.SaveResult = try await api().request(
                "api/proposals/commit", method: "POST",
                body: ["session_id": activeID, "items": chosen.map(\.writeParameters)]
            )
            if result.ok {
                proposals = []
                notice = "已保存 \(result.written?.count ?? chosen.count) 条记忆。"
            }
        }
    }

    // MARK: - 记忆库

    func saveNote(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enqueue(.note(text: trimmed))
        await sync()
    }

    func createMemory(kind: MemoryKind, title: String, body: String, importance: Int, privacy: String) async {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let day = Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        let quotedTitle = String(decoding: (try? JSONEncoder().encode(cleanTitle)) ?? Data(), as: UTF8.self)
        let content = """
        ---
        title: \(quotedTitle)
        type: \(kind.type)
        event_time: \(day)
        recorded_at: \(day)
        importance: \(importance)
        privacy: \(privacy)
        source: mobile
        ---

        # \(cleanTitle)

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
        enqueue(.memory(path: kind.path(title: cleanTitle, day: day), content: content, title: cleanTitle))
        await sync()
    }

    private func enqueue(_ kind: OutboxItem.Kind) {
        outbox.append(OutboxItem(clientID: UUID().uuidString, kind: kind, createdAt: Date()))
        persist()
        if !online { notice = "已存到手机，联网后会自动上传到 VPS。" }
    }

    func findMemories(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result: AdvisorAPI.Items<AdvisorAPI.Memory> = try await api().request(
                query.isEmpty ? "api/memories" : "api/memories/search",
                query: query.isEmpty ? [] : [.init(name: "q", value: query)]
            )
            memories = result.items.map {
                CachedMemory(path: $0.path, title: $0.title, categoryLabel: $0.categoryLabel, snippet: $0.snippet)
            }
            if query.isEmpty {
                cachedMemories = memories
                persist()
            }
        } catch let failure as AdvisorAPI.APIError where failure.status == 401 {
            handleUnauthorized()
        } catch {
            memories = query.isEmpty ? cachedMemories : cachedMemories.filter {
                $0.title.localizedCaseInsensitiveContains(query) || $0.snippet.localizedCaseInsensitiveContains(query)
            }
        }
    }

    func openMemory(_ path: String) async {
        await perform {
            memoryFile = try await api().request("api/memories/file", query: [.init(name: "path", value: path)])
        }
    }

    func saveMemoryEdit(path: String, raw: String) async {
        await perform {
            let _: AdvisorAPI.SaveResult = try await api().request(
                "api/memories/file", method: "PUT",
                body: ["path": path, "content": raw, "commit_message": "mobile: 手机编辑 \(path)"]
            )
            memoryFile = try await api().request("api/memories/file", query: [.init(name: "path", value: path)])
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await work()
        } catch let failure as AdvisorAPI.APIError where failure.status == 401 && connected {
            handleUnauthorized()
        } catch {
            self.error = Self.isTransient(error) && !online
                ? "当前离线，这个操作需要联网。"
                : error.localizedDescription
        }
    }
}
