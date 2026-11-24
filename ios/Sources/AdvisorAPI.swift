import Foundation
import Security

struct AdvisorAPI {
    private static let session = URLSession(configuration: .ephemeral)
    var baseURL: URL
    var password: String

    struct APIError: LocalizedError {
        let errorDescription: String?
        var status: Int? = nil
    }

    /// `/api/chat/stream` 推送的一个事件。
    struct StreamEvent: Decodable, Sendable {
        let type: String
        let delta: String?
        let detail: String?
        let sessionId: String?
        let model: String?
        let providerName: String?
        let references: [MessageReference]?
    }
    private struct Failure: Decodable { let detail: String }

    struct Items<T: Decodable>: Decodable { let items: [T] }
    struct Verification: Decodable { let deploymentMode: String }
    struct AuthStatus: Decodable { let authRequired: Bool }
    struct SaveResult: Decodable { let ok: Bool; let written: [String]? }
    struct ChatReply: Decodable { let reply: String }
    struct ProposalList: Decodable { let proposals: [Proposal] }

    struct Session: Decodable, Identifiable {
        let id: String
        let title: String
        let mode: String?
        let updatedAt: String?
        let messages: [Message]?
    }

    struct Message: Codable, Identifiable {
        var id: Int? = nil
        let role: String
        let content: String
        var reasoning: String? = nil
        var model: String? = nil
        var providerName: String? = nil
        var references: [MessageReference]? = nil

        enum CodingKeys: String, CodingKey {
            case id, role, content, reasoning, model, providerName, references
        }
    }

    struct Memory: Decodable, Identifiable {
        let path: String
        let title: String
        let categoryLabel: String
        let snippet: String
        var id: String { path }
    }

    struct MemoryFile: Decodable {
        let path: String
        let title: String
        let body: String
        let raw: String
    }

    struct Proposal: Decodable, Identifiable {
        let id: String
        let action: String
        let path: String
        let title: String
        let summary: String
        let privacy: String
        let content: String
        let evidence: String
        let diff: String
        let level: Int

        var writeParameters: [String: String] {
            ["action": action, "path": path, "title": title, "privacy": privacy, "content": content]
        }
    }

    static func validateURL(_ value: String) throws -> URL {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed: Set<String> = ["https"]
        #if DEBUG
        // 仅调试版：允许连本机测试后端。
        if let host = URLComponents(string: text)?.host, ["127.0.0.1", "localhost"].contains(host) {
            allowed.insert("http")
        }
        #endif
        guard let parts = URLComponents(string: text),
              allowed.contains(parts.scheme?.lowercased() ?? ""), parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else {
            throw APIError(errorDescription: "请输入 VPS 的 HTTPS 地址。")
        }
        return url
    }

    func request<T: Decodable>(
        _ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw APIError(errorDescription: "服务器地址无效。")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = method
        request.setValue(password, forHTTPHeaderField: "X-Access-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(Failure.self, from: data).detail
            let status = (response as? HTTPURLResponse)?.statusCode
            throw APIError(errorDescription: detail ?? "服务器请求失败（\(status ?? 0)）。", status: status)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    /// 读取 SSE 流。按字节拆行，因为 `AsyncBytes.lines` 会吞掉分隔事件的空行。
    func stream(
        _ path: String, body: [String: Any], onEvent: @MainActor @Sendable (StreamEvent) -> Void
    ) async throws {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        try await stream(path, bodyData: bodyData, onEvent: onEvent)
    }

    func stream(
        _ path: String, bodyData: Data, onEvent: @MainActor @Sendable (StreamEvent) -> Void
    ) async throws {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue(password, forHTTPHeaderField: "X-Access-Token")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        let (bytes, response) = try await Self.session.bytes(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let status = (response as? HTTPURLResponse)?.statusCode
            let detail = try? JSONDecoder().decode(Failure.self, from: data).detail
            throw APIError(errorDescription: detail ?? "服务器请求失败（\(status ?? 0)）。", status: status)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var buffer: [UInt8] = []
        var dataLines: [String] = []
        func dispatch() async {
            defer { dataLines.removeAll() }
            guard !dataLines.isEmpty,
                  let event = try? decoder.decode(StreamEvent.self, from: Data(dataLines.joined(separator: "\n").utf8))
            else { return }
            await onEvent(event)
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard byte == 0x0A else { buffer.append(byte); continue }
            if buffer.last == 0x0D { buffer.removeLast() }
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            if line.isEmpty {
                await dispatch()
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        await dispatch()
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
enum AdvisorPassword {
    private static func account(_ server: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sakura.DecisionAdvisorMobile",
            kSecAttrAccount as String: server,
        ]
    }

    static func load(server: String) -> String {
        var query = account(server)
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &data) == errSecSuccess,
              let bytes = data as? Data else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func save(_ value: String, server: String) throws {
        let account = account(server)
        let bytes = Data(value.utf8)
        let status = SecItemUpdate(account as CFDictionary, [kSecValueData: bytes] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = account
            entry[kSecValueData as String] = bytes
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else {
                throw AdvisorAPI.APIError(errorDescription: "访问密码无法写入钥匙串。")
            }
        } else if status != errSecSuccess {
            throw AdvisorAPI.APIError(errorDescription: "访问密码无法更新。")
        }
    }

    static func remove(server: String) {
        SecItemDelete(account(server) as CFDictionary)
    }
}
