import Foundation
import Network

/// Ephemeral 127.0.0.1 HTTP loopback server that catches OpenAI Sign in with ChatGPT
/// callbacks when the backend runs remotely (e.g., on VPS), then forwards the callback URL
/// to the backend's `/api/chatgpt-oauth/complete-callback` endpoint.
final class LocalOAuthCallbackCatcher: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.sakura.decision-advisor.oauth-loopback")
    private let lock = NSLock()
    private var handled = false
    private var assignedPort: UInt16 = 0

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !fired else { return false }
            fired = true
            return true
        }
    }

    func start(
        onCallback: @escaping @Sendable (String) async -> (success: Bool, title: String, message: String)
    ) async throws -> Int {
        stop()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host.ipv4(.loopback),
            port: .any
        )

        let listener = try NWListener(using: params)
        self.listener = listener

        let port: Int = try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let actualPort = listener.port?.rawValue ?? 0
                    self?.assignedPort = actualPort
                    if once.claim() {
                        if actualPort > 0 {
                            cont.resume(returning: Int(actualPort))
                        } else {
                            cont.resume(throwing: NSError(
                                domain: "LocalOAuthCallbackCatcher",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "无法分配本机回调端口"]
                            ))
                        }
                    }
                case .failed(let err):
                    if once.claim() {
                        cont.resume(throwing: err)
                    }
                case .cancelled:
                    if once.claim() {
                        cont.resume(throwing: NSError(
                            domain: "LocalOAuthCallbackCatcher",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "本机回调监听已取消"]
                        ))
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn, onCallback: onCallback)
            }
            listener.start(queue: self.queue)
        }

        return port
    }

    func stop() {
        lock.lock()
        let current = listener
        listener = nil
        handled = false
        assignedPort = 0
        lock.unlock()
        current?.cancel()
    }

    private func handleConnection(
        _ conn: NWConnection,
        onCallback: @escaping @Sendable (String) async -> (success: Bool, title: String, message: String)
    ) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let raw = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }

            let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            let targetPath = parts.count >= 2 ? String(parts[1]) : "/"

            guard targetPath.hasPrefix("/auth/callback") else {
                self.sendHTTP(
                    conn,
                    status: "404 Not Found",
                    html: "<h3>Not Found</h3>",
                    closeListenerAfter: false
                )
                return
            }

            self.lock.lock()
            let alreadyHandled = self.handled
            self.handled = true
            let port = self.assignedPort
            self.lock.unlock()

            if alreadyHandled {
                let html = Self.renderHTML(
                    success: true,
                    title: "已完成授权处理",
                    message: "现在可以关闭此页面并返回「成长决策顾问」。"
                )
                self.sendHTTP(conn, status: "200 OK", html: html, closeListenerAfter: false)
                return
            }

            let fullCallbackURL = "http://127.0.0.1:\(port)\(targetPath)"
            Task {
                let result = await onCallback(fullCallbackURL)
                let html = Self.renderHTML(
                    success: result.success,
                    title: result.title,
                    message: result.message
                )
                let status = result.success ? "200 OK" : "400 Bad Request"
                self.sendHTTP(conn, status: status, html: html, closeListenerAfter: true)
            }
        }
    }

    private func sendHTTP(_ conn: NWConnection, status: String, html: String, closeListenerAfter: Bool) {
        let bodyData = Data(html.utf8)
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var payload = Data(header.utf8)
        payload.append(bodyData)

        conn.send(content: payload, completion: .contentProcessed { [weak self] _ in
            conn.cancel()
            if closeListenerAfter, let strongSelf = self {
                strongSelf.queue.asyncAfter(deadline: .now() + 0.5) {
                    strongSelf.stop()
                }
            }
        })
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func renderHTML(success: Bool, title: String, message: String) -> String {
        let badgeBg = success ? "#e6f0ec" : "#fee2e2"
        let badgeFg = success ? "#2c5e4f" : "#b91c1c"
        let icon = success ? "✅" : "⚠️"
        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width,initial-scale=1" />
          <title>\(escapeHTML(title)) · 成长决策顾问</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; background:#f6f4ef; color:#1f2421; display:grid; place-items:center; min-height:100vh; margin:0; padding:20px; }
            .card { background:#fff; border:1px solid #e3ded3; border-radius:18px; padding:28px 30px; max-width:460px; width:100%; box-shadow:0 6px 24px rgba(24,24,20,0.07); }
            .badge { display:inline-flex; align-items:center; gap:6px; padding:5px 12px; border-radius:999px; font-size:13px; font-weight:600; background:\(badgeBg); color:\(badgeFg); margin-bottom:14px; }
            h1 { margin:0 0 8px; font-size:21px; }
            p { margin:0 0 14px; color:#6c6a64; font-size:14px; line-height:1.65; }
            .hint { font-size:12.5px; color:#6c6a64; text-align:center; margin-top:10px; }
          </style>
        </head>
        <body>
          <div class="card">
            <div class="badge">\(icon) 成长决策顾问 · Sign in with ChatGPT</div>
            <h1>\(escapeHTML(title))</h1>
            <p>\(escapeHTML(message))</p>
            <div class="hint">现在可以关闭此浏览器标签页，回到「成长决策顾问」App 继续使用。</div>
          </div>
        </body>
        </html>
        """
    }
}
