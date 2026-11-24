import Foundation

/// 对话回复引用的记忆卡片（与后端 `/api/chat/stream` meta 及 `/api/sessions/{id}` 对齐）。
struct MessageReference: Codable, Identifiable, Equatable, Sendable {
    var path: String
    var title: String
    var category: String? = nil
    var importance: Int? = nil
    var source: String? = nil
    var reasons: [String]? = nil

    var id: String { path }
}

/// 一条本机保存的消息。服务器确认前 `state` 为 pending，失败后为 failed。
struct StoredMessage: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case sent, pending, failed, streaming }

    var id: String
    var role: String
    var content: String
    var state: State = .sent
    var failure: String? = nil
    var reasoning: String? = nil
    var modelName: String? = nil
    var providerName: String? = nil
    var references: [MessageReference]? = nil
}

/// 一段会话。`id` 在服务器确认前是 `local-` 开头的本机编号。
struct StoredConversation: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var mode: String = "chat"
    var updatedAt: String
    var messages: [StoredMessage] = []
    var loaded = false

    var isLocal: Bool { id.hasPrefix("local-") }
}

/// 待上传到 VPS 的操作，按顺序补传。每条都带一个固定 `clientID`，服务器据此去重。
struct OutboxItem: Codable, Identifiable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case chat(conversationID: String, messageID: String)
        case note(text: String)
        case memory(path: String, content: String, title: String)
    }

    var id: String { clientID }
    var clientID: String
    var kind: Kind
    var createdAt: Date
    var failure: String? = nil
    /// 本轮是否允许敏感记忆（可选字段，保持与旧版 state.json 向后兼容）。
    var allowSensitive: Bool? = nil
    /// 本轮历史时间切片 `yyyy-MM-dd`（可选字段，保持向后兼容）。
    var asOf: String? = nil

    var summary: String {
        switch kind {
        case .chat: "对话消息"
        case .note(let text): "速记：\(text.prefix(24))"
        case .memory(_, _, let title): "新记忆：\(title)"
        }
    }
}

struct CachedMemory: Codable, Identifiable, Equatable, Sendable {
    let path: String
    let title: String
    let categoryLabel: String
    let snippet: String
    var id: String { path }
}

struct AdvisorSnapshot: Codable, Sendable {
    var conversations: [StoredConversation] = []
    var outbox: [OutboxItem] = []
    var memories: [CachedMemory] = []
    var lastSync: Date?
}

/// 本机缓存：Application Support 下一个受数据保护的 JSON 文件。
enum AdvisorStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "AdvisorCache/state.json")
    }

    static func load() -> AdvisorSnapshot {
        guard let data = try? Data(contentsOf: url) else { return AdvisorSnapshot() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AdvisorSnapshot.self, from: data)) ?? AdvisorSnapshot()
    }

    static func save(_ snapshot: AdvisorSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        let target = url
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func erase() {
        try? FileManager.default.removeItem(at: url)
    }
}
