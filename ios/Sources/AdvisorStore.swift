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
@MainActor
enum AdvisorStore {
    /// 启动时缓存没能正常读出的情况。两种情况都不会覆盖原文件。
    enum LoadIssue: Equatable {
        /// 内容无法解析，原文件已改名保留在缓存目录。
        case quarantined(fileName: String)
        /// 文件存在但暂时读不出来（如数据保护未解锁），本次运行不再写入。
        case unreadable
    }

    struct SaveBlocked: LocalizedError {
        var errorDescription: String? { "本机缓存暂时读不出来，为避免覆盖已暂停保存，请重启 App 后再试。" }
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "AdvisorCache")
    }

    private static var url: URL { directory.appending(path: "state.json") }

    /// 为真时拒绝写入，防止空快照覆盖一个只是暂时读不出来的缓存文件。
    private static var saveBlocked = false

    /// 读不出来不能当成空缓存：下一次保存会覆盖原文件，还没上传的内容就永久丢了。
    static func load() -> (snapshot: AdvisorSnapshot, issue: LoadIssue?) {
        let target = url
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            return (AdvisorSnapshot(), nil)
        }
        guard let data = try? Data(contentsOf: target) else {
            saveBlocked = true
            return (AdvisorSnapshot(), .unreadable)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(AdvisorSnapshot.self, from: data) {
            return (snapshot, nil)
        }
        let backup = directory.appending(path: "state.unreadable-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try FileManager.default.moveItem(at: target, to: backup)
            return (AdvisorSnapshot(), .quarantined(fileName: backup.lastPathComponent))
        } catch {
            saveBlocked = true
            return (AdvisorSnapshot(), .unreadable)
        }
    }

    static func save(_ snapshot: AdvisorSnapshot) throws {
        guard !saveBlocked else { throw SaveBlocked() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let target = url
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 清空整个缓存目录，包括改名保留的损坏文件。
    static func erase() {
        let target = directory
        try? FileManager.default.removeItem(at: target)
        if !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) { saveBlocked = false }
    }
}
