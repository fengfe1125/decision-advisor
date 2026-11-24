import Foundation
import Observation

@MainActor
@Observable
final class EmbeddedBackendManager {
    static let shared = EmbeddedBackendManager()

    let port: Int = 18789
    var isRunning: Bool = false
    var isStarting: Bool = false
    var processPID: Int32? = nil
    var statusText: String = "未启动"
    var lastError: String? = nil

    var baseURL: String {
        "http://127.0.0.1:\(port)"
    }

    var localDataDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("DecisionAdvisor/local-data", isDirectory: true)
    }

    var runtimeDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("DecisionAdvisor/runtime", isDirectory: true)
    }

    var logFileURL: URL {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DecisionAdvisor", isDirectory: true)
        return logs.appendingPathComponent("embedded-backend.log")
    }

    private var process: Process?
    private var logHandle: FileHandle?

    private init() {}

    /// Locate the bundled Python backend inside Contents/Resources/backend (with workspace fallback for swift run)
    func resolveBackendSourceDir() -> URL? {
        let fm = FileManager.default
        if let resURL = Bundle.main.resourceURL {
            let bundled = resURL.appendingPathComponent("backend", isDirectory: true)
            if fm.fileExists(atPath: bundled.appendingPathComponent("app/main.py").path) {
                return bundled
            }
        }
        let workspaceFallback = URL(fileURLWithPath: "/Volumes/Developer/个人汇总/apps/decision-advisor", isDirectory: true)
        if fm.fileExists(atPath: workspaceFallback.appendingPathComponent("app/main.py").path) {
            return workspaceFallback
        }
        return nil
    }

    /// Seed ~/Library/Application Support/DecisionAdvisor/local-data once from existing local project files if present
    private func ensureLocalDataDirSeeded() throws -> URL {
        let fm = FileManager.default
        let dataDir = localDataDirectory
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let legacyBase = URL(fileURLWithPath: "/Volumes/Developer/个人汇总/apps/decision-advisor", isDirectory: true)
        let cfgDst = dataDir.appendingPathComponent("config.local.json")
        let cfgSrc = legacyBase.appendingPathComponent("config.local.json")
        if !fm.fileExists(atPath: cfgDst.path), fm.fileExists(atPath: cfgSrc.path) {
            try? fm.copyItem(at: cfgSrc, to: cfgDst)
        }

        let dbDst = dataDir.appendingPathComponent("advisor_state.db")
        let dbSrc = legacyBase.appendingPathComponent("advisor_state.db")
        if !fm.fileExists(atPath: dbDst.path), fm.fileExists(atPath: dbSrc.path) {
            try? fm.copyItem(at: dbSrc, to: dbDst)
        }

        let gitDst = dataDir.appendingPathComponent(".memory-git")
        let gitSrc = legacyBase.appendingPathComponent(".memory-git")
        if !fm.fileExists(atPath: gitDst.path), fm.fileExists(atPath: gitSrc.path) {
            try? fm.copyItem(at: gitSrc, to: gitDst)
        }

        return dataDir
    }

    func readEmbeddedAccessToken() -> String {
        let candidates = [
            localDataDirectory.appendingPathComponent("config.local.json"),
            URL(fileURLWithPath: "/Volumes/Developer/个人汇总/apps/decision-advisor/config.local.json"),
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tok = obj["access_token"] as? String {
                return tok
            }
        }
        return ""
    }

    private func findPythonExecutable(backendDir: URL) -> URL? {
        let fm = FileManager.default
        let candidates = [
            backendDir.appendingPathComponent(".venv/bin/python"),
            runtimeDirectory.appendingPathComponent(".venv/bin/python"),
            URL(fileURLWithPath: "/Volumes/Developer/个人汇总/apps/decision-advisor/.venv/bin/python"),
        ]
        for url in candidates {
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func provisionRuntimeWithUV(backendDir: URL) async throws -> URL {
        let fm = FileManager.default
        let uvPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv").path,
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        guard let uvPath = uvPaths.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw NSError(
                domain: "EmbeddedBackend",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "未找到内置 Python 运行环境或 uv，请重新运行 build_app.sh 构建或安装 uv。"]
            )
        }

        try fm.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        for file in ["pyproject.toml", "uv.lock"] {
            let src = backendDir.appendingPathComponent(file)
            let dst = runtimeDirectory.appendingPathComponent(file)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }

        statusText = "首次初始化内置运行环境…"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: uvPath)
            proc.arguments = ["sync", "--no-dev"]
            proc.currentDirectoryURL = runtimeDirectory
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: NSError(
                        domain: "EmbeddedBackend",
                        code: Int(p.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: "初始化内置 Python 环境失败 (exit \(p.terminationStatus))"]
                    ))
                }
            }
            do {
                try proc.run()
            } catch {
                cont.resume(throwing: error)
            }
        }

        let py = runtimeDirectory.appendingPathComponent(".venv/bin/python")
        guard fm.isExecutableFile(atPath: py.path) else {
            throw NSError(
                domain: "EmbeddedBackend",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "内置运行环境创建完成但未找到 Python 可执行文件"]
            )
        }
        return py
    }

    private static let loopbackSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 3
        return URLSession(configuration: cfg)
    }()

    private func probeHealthy() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/auth/status") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await Self.loopbackSession.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
        } catch {}
        return false
    }

    func startIfNeeded() async throws {
        if let proc = process, proc.isRunning, await probeHealthy() {
            isRunning = true
            processPID = proc.processIdentifier
            statusText = "运行中 (PID \(proc.processIdentifier))"
            lastError = nil
            return
        }

        if await probeHealthy() {
            isRunning = true
            statusText = "运行中 (复用本机内置端口)"
            lastError = nil
            return
        }

        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        lastError = nil
        statusText = "正在启动 App 内置引擎…"

        guard let backendDir = resolveBackendSourceDir() else {
            let msg = "未找到 App 内置后端资源目录"
            lastError = msg
            statusText = msg
            throw NSError(domain: "EmbeddedBackend", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let dataDir = try ensureLocalDataDirSeeded()
        let pythonURL: URL
        if let existingPy = findPythonExecutable(backendDir: backendDir) {
            pythonURL = existingPy
        } else {
            pythonURL = try await provisionRuntimeWithUV(backendDir: backendDir)
        }

        // Prepare log file
        let fm = FileManager.default
        try fm.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logFileURL)
        handle.seekToEndOfFile()
        self.logHandle = handle

        let proc = Process()
        proc.executableURL = pythonURL
        proc.arguments = [
            "-m", "uvicorn", "app.main:app",
            "--host", "127.0.0.1",
            "--port", String(port),
            "--log-level", "warning",
        ]
        proc.currentDirectoryURL = backendDir

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PYTHONPATH"] = backendDir.path
        env["ADVISOR_DEPLOYMENT_MODE"] = "embedded_local"
        env["ADVISOR_DATA_DIR"] = dataDir.path
        env["ADVISOR_PORT"] = String(port)
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        proc.standardOutput = handle
        proc.standardError = handle

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self else { return }
                if self.process === terminated {
                    self.isRunning = false
                    self.processPID = nil
                    self.process = nil
                    if terminated.terminationStatus != 0 && terminated.terminationReason == .exit {
                        self.statusText = "已退出 (code \(terminated.terminationStatus))"
                    } else {
                        self.statusText = "已停止"
                    }
                }
            }
        }

        try proc.run()
        self.process = proc
        self.processPID = proc.processIdentifier

        // Wait up to 12 seconds for uvicorn to accept HTTP requests
        for _ in 0..<80 {
            if !proc.isRunning {
                let msg = "内置引擎启动异常退出，请查看日志：\(logFileURL.path)"
                lastError = msg
                statusText = "启动失败"
                throw NSError(domain: "EmbeddedBackend", code: 4, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            if await probeHealthy() {
                isRunning = true
                statusText = "运行中 (PID \(proc.processIdentifier))"
                lastError = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        stopSync()
        let timeoutMsg = "内置引擎启动超时（12秒），请查看日志：\(logFileURL.path)"
        lastError = timeoutMsg
        statusText = "启动超时"
        throw NSError(domain: "EmbeddedBackend", code: 5, userInfo: [NSLocalizedDescriptionKey: timeoutMsg])
    }

    func restart() async throws {
        stopSync()
        try? await Task.sleep(for: .milliseconds(250))
        try await startIfNeeded()
    }

    func stopSync() {
        if let proc = process, proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        process = nil
        processPID = nil
        isRunning = false
        statusText = "已停止"
        try? logHandle?.close()
        logHandle = nil
    }
}
