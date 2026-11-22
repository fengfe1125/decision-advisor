import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case httpError(Int, String)
    case decodeError(String)
    case offline(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的服务地址"
        case .httpError(let code, let detail): return "HTTP \(code): \(detail)"
        case .decodeError(let msg): return "数据解析失败: \(msg)"
        case .offline(let msg): return "无法连接后端服务: \(msg)"
        }
    }
}

final class APIClient: Sendable {
    let baseURL: String
    let accessToken: String

    static let defaultRemoteURL = "https://decision.sakuramu.edu.kg"

    private static let loopbackSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 180
        return URLSession(configuration: cfg)
    }()

    private var session: URLSession {
        Self.session(for: baseURL)
    }

    private static func session(for urlString: String) -> URLSession {
        if let host = URL(string: urlString)?.host?.lowercased(),
           host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return loopbackSession
        }
        return URLSession.shared
    }

    init(baseURL: String, accessToken: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readSeedAccessToken() -> String {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DecisionAdvisor/local-data/config.local.json")
        let candidates: [URL] = [
            appSupport,
            URL(fileURLWithPath: "/Volumes/Developer/个人汇总/decision-advisor/config.local.json"),
        ].compactMap { $0 }

        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = obj["access_token"] as? String,
               !token.isEmpty {
                return token
            }
        }
        return ""
    }

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !accessToken.isEmpty {
            req.setValue(accessToken, forHTTPHeaderField: "X-Access-Token")
        }
        req.httpBody = body
        return req
    }

    private func perform<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let req = try makeRequest(path, method: method, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.offline("响应异常")
        }
        if http.statusCode >= 400 {
            let detail: String
            if let errObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = errObj["detail"] as? String {
                detail = d
            } else {
                detail = String(data: data, encoding: .utf8) ?? "请求失败"
            }
            throw APIError.httpError(http.statusCode, detail)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodeError(error.localizedDescription)
        }
    }

    // MARK: - Endpoints

    func verifyAuth() async throws -> AuthVerifyResponse {
        try await perform("/api/auth/verify", method: "POST")
    }

    func fetchHealth() async throws -> HealthResponse {
        try await perform("/api/health")
    }

    func fetchConfig() async throws -> PublicConfigDTO {
        try await perform("/api/config")
    }

    func saveConfig(_ payload: [String: Any]) async throws -> PublicConfigDTO {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await perform("/api/config", method: "PUT", body: data)
    }

    func testProvider(providerId: String) async throws -> TestProviderResponse {
        let data = try JSONSerialization.data(withJSONObject: ["provider_id": providerId])
        return try await perform("/api/config/test", method: "POST", body: data)
    }

    // MARK: - Sign in with ChatGPT OAuth

    func fetchChatGPTOAuthStatus(state: String? = nil) async throws -> ChatGPTOAuthStatusDTO {
        if let st = state, !st.isEmpty {
            var comps = URLComponents()
            comps.queryItems = [URLQueryItem(name: "state", value: st)]
            return try await perform("/api/chatgpt-oauth/status?\(comps.percentEncodedQuery ?? "")")
        }
        return try await perform("/api/chatgpt-oauth/status")
    }

    func startChatGPTOAuth(forceRegister: Bool = false, redirectPort: Int? = nil) async throws -> ChatGPTOAuthStartResponse {
        var obj: [String: Any] = ["force_register": forceRegister]
        if let port = redirectPort {
            obj["redirect_port"] = port
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try await perform("/api/chatgpt-oauth/start", method: "POST", body: data)
    }

    func completeChatGPTOAuthCallback(callbackUrl: String) async throws -> ChatGPTOAuthCompleteResponse {
        let data = try JSONSerialization.data(withJSONObject: ["callback_url": callbackUrl])
        return try await perform("/api/chatgpt-oauth/complete-callback", method: "POST", body: data)
    }

    func refreshChatGPTModels() async throws -> ChatGPTOAuthRefreshModelsResponse {
        try await perform("/api/chatgpt-oauth/models/refresh", method: "POST")
    }

    func logoutChatGPTOAuth(resetClient: Bool = false) async throws -> ChatGPTOAuthLogoutResponse {
        let data = try JSONSerialization.data(withJSONObject: ["reset_client": resetClient])
        return try await perform("/api/chatgpt-oauth/logout", method: "POST", body: data)
    }

    func rebuildIndex() async throws -> RebuildIndexResponse {
        try await perform("/api/index/rebuild", method: "POST")
    }

    func fetchGitHistory() async throws -> GitHistoryResponse {
        try await perform("/api/git/history?limit=25")
    }

    func fetchSessions() async throws -> SessionsListResponse {
        try await perform("/api/sessions?limit=60")
    }

    func fetchSession(id: String) async throws -> SessionDetailResponse {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await perform("/api/sessions/\(encoded)")
    }

    func deleteSession(id: String) async throws {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        struct OkResp: Decodable { let ok: Bool }
        let _: OkResp = try await perform("/api/sessions/\(encoded)", method: "DELETE")
    }

    func fetchMemories(category: String = "all", query: String = "", emotion: String = "", minImportance: Int = 1) async throws -> MemoriesListResponse {
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "emotion", value: emotion),
            URLQueryItem(name: "min_importance", value: String(minImportance)),
        ]
        return try await perform("/api/memories?\(comps.percentEncodedQuery ?? "")")
    }

    func semanticSearch(query: String, asOf: String = "") async throws -> MemoriesListResponse {
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "as_of", value: asOf),
            URLQueryItem(name: "top_k", value: "12"),
        ]
        return try await perform("/api/memories/search?\(comps.percentEncodedQuery ?? "")")
    }

    func fetchTimeline() async throws -> TimelineResponse {
        try await perform("/api/memories/timeline")
    }

    func fetchGraph() async throws -> GraphResponse {
        try await perform("/api/memories/graph")
    }

    func fetchMemoryFile(path: String) async throws -> MemoryDetail {
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        return try await perform("/api/memories/file?\(comps.percentEncodedQuery ?? "")")
    }

    func saveMemoryFile(path: String, content: String) async throws {
        struct SaveResp: Decodable { let ok: Bool }
        let data = try JSONSerialization.data(withJSONObject: ["path": path, "content": content])
        let _: SaveResp = try await perform("/api/memories/file", method: "PUT", body: data)
    }

    func deleteMemoryFile(path: String) async throws {
        struct DelResp: Decodable { let ok: Bool }
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        let _: DelResp = try await perform("/api/memories/file?\(comps.percentEncodedQuery ?? "")", method: "DELETE")
    }

    func downloadVaultArchive() async throws -> Data {
        let req = try makeRequest("/api/vault/export", method: "GET")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.offline("响应异常")
        }
        if http.statusCode >= 400 {
            let detail = String(data: data, encoding: .utf8) ?? "导出失败"
            throw APIError.httpError(http.statusCode, detail)
        }
        return data
    }

    func addInbox(text: String, mood: String) async throws {
        struct InboxResp: Decodable { let ok: Bool }
        let data = try JSONSerialization.data(withJSONObject: ["text": text, "mood": mood])
        let _: InboxResp = try await perform("/api/inbox", method: "POST", body: data)
    }

    func extractProposals(sessionId: String?, messages: [ChatMessageItem], providerId: String?, allowSensitive: Bool) async throws -> ExtractProposalsResponse {
        var obj: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "allow_sensitive": allowSensitive,
        ]
        if let sid = sessionId { obj["session_id"] = sid }
        if let pid = providerId { obj["provider_id"] = pid }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try await perform("/api/proposals/extract", method: "POST", body: data)
    }

    func commitProposals(sessionId: String?, proposals: [MemoryProposal]) async throws -> CommitProposalsResponse {
        var obj: [String: Any] = [
            "items": proposals.map {
                [
                    "action": $0.action,
                    "path": $0.path,
                    "title": $0.title,
                    "privacy": $0.privacy,
                    "content": $0.content,
                ]
            }
        ]
        if let sid = sessionId { obj["session_id"] = sid }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try await perform("/api/proposals/commit", method: "POST", body: data)
    }

    // MARK: - SSE Streaming Chat

    func streamChat(
        sessionId: String?,
        messages: [ChatMessageItem],
        mode: ChatMode,
        providerId: String?,
        allowSensitive: Bool,
        asOf: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        var obj: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "mode": mode.rawValue,
            "allow_sensitive": allowSensitive,
        ]
        if let sid = sessionId { obj["session_id"] = sid }
        if let pid = providerId { obj["provider_id"] = pid }
        if let d = asOf, !d.isEmpty { obj["as_of"] = d }

        let bodyData = try? JSONSerialization.data(withJSONObject: obj)
        let clientBase = self.baseURL
        let token = self.accessToken

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(clientBase)/api/chat/stream") else {
                        throw APIError.invalidURL
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 180
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !token.isEmpty {
                        req.setValue(token, forHTTPHeaderField: "X-Access-Token")
                    }
                    req.httpBody = bodyData

                    let streamSession = Self.session(for: clientBase)
                    let (bytes, response) = try await streamSession.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.offline("响应异常")
                    }
                    if http.statusCode >= 400 {
                        var errBuf = ""
                        for try await line in bytes.lines { errBuf += line }
                        throw APIError.httpError(http.statusCode, errBuf)
                    }

                    for try await rawLine in bytes.lines {
                        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard line.hasPrefix("data:") else { continue }
                        let payloadStr = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard !payloadStr.isEmpty, let jsonData = payloadStr.data(using: .utf8) else { continue }
                        guard let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let type = dict["type"] as? String else { continue }

                        switch type {
                        case "meta":
                            let sid = dict["session_id"] as? String ?? ""
                            let pname = dict["provider_name"] as? String ?? ""
                            let model = dict["model"] as? String ?? ""
                            var refs: [MemoryReference] = []
                            if let rawRefs = dict["references"],
                               let refData = try? JSONSerialization.data(withJSONObject: rawRefs),
                               let decoded = try? JSONDecoder().decode([MemoryReference].self, from: refData) {
                                refs = decoded
                            }
                            continuation.yield(.meta(sessionId: sid, providerName: pname, model: model, references: refs))
                        case "reasoning":
                            if let delta = dict["delta"] as? String {
                                continuation.yield(.reasoning(delta))
                            }
                        case "text":
                            if let delta = dict["delta"] as? String {
                                continuation.yield(.text(delta))
                            }
                        case "error":
                            let detail = dict["detail"] as? String ?? "未知错误"
                            continuation.yield(.error(detail))
                        case "done":
                            let sid = dict["session_id"] as? String ?? ""
                            continuation.yield(.done(sid))
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
