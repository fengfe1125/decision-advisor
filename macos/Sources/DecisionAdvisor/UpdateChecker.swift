import AppKit
import CryptoKit
import Foundation
import Observation

/// 基于公开镜像仓库 GitHub Releases 的应用内更新检查与一键安装。
///
/// 发版约定（见 agent.md「版本号规范」）：公开仓库 `fengfe1125/decision-advisor` 的 Release 标签为
/// `v<X.YY>`，附带资产 `DecisionAdvisor-v<X.YY>-macOS.zip`（由 `build_app.sh --package` 生成）。
@MainActor
@Observable
final class UpdateChecker {
    static let releasesAPI = URL(string: "https://api.github.com/repos/fengfe1125/decision-advisor/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/fengfe1125/decision-advisor/releases")!

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case installing
        case failed(String)
    }

    struct ReleaseInfo: Equatable {
        let version: String
        let title: String
        let notes: String
        let pageURL: URL
        let assetURL: URL?
        let assetSHA256: String?
    }

    private enum PrefKeys {
        static let autoCheck = "da.update.auto_check"
        static let lastCheck = "da.update.last_check"
        static let skippedVersion = "da.update.skipped_version"
    }

    var phase: Phase = .idle
    var latest: ReleaseInfo?
    var lastChecked: Date?
    var autoCheckEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCheckEnabled, forKey: PrefKeys.autoCheck) }
    }

    let currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.00"

    init() {
        let defaults = UserDefaults.standard
        autoCheckEnabled = defaults.object(forKey: PrefKeys.autoCheck) as? Bool ?? true
        let ts = defaults.double(forKey: PrefKeys.lastCheck)
        lastChecked = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    var hasUpdate: Bool {
        guard let latest else { return false }
        return Self.compare(latest.version, currentVersion) == .orderedDescending
    }

    // MARK: - Checking

    /// 启动时调用：开启自动检查且距上次检查超过 12 小时才发起请求，发现新版本时弹窗（已“跳过”的版本不打扰）。
    func checkOnLaunchIfNeeded() async {
        guard autoCheckEnabled else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < 12 * 3600 { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        phase = .checking
        do {
            let info = try await fetchLatestRelease()
            latest = info
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked!.timeIntervalSince1970, forKey: PrefKeys.lastCheck)

            if hasUpdate {
                phase = .available
                let skipped = UserDefaults.standard.string(forKey: PrefKeys.skippedVersion)
                if userInitiated || skipped != info.version {
                    presentUpdateAlert(info)
                }
            } else {
                phase = .upToDate
                if userInitiated {
                    presentInfoAlert(title: "已是最新版本", message: "当前版本 v\(currentVersion) 已是最新（最新发布 v\(info.version)）。")
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            if userInitiated {
                presentInfoAlert(title: "检查更新失败", message: error.localizedDescription)
            }
        }
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        var req = URLRequest(url: Self.releasesAPI, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("DecisionAdvisor-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UpdateError.message("无效的服务器响应") }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 { throw UpdateError.message("公开仓库暂无正式发布版本") }
            if http.statusCode == 403 { throw UpdateError.message("GitHub API 请求过于频繁，请稍后再试") }
            throw UpdateError.message("GitHub 返回 HTTP \(http.statusCode)")
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        let expectedName = "DecisionAdvisor-v\(version)-macOS.zip"
        let asset = release.assets.first(where: { $0.name == expectedName })
            ?? release.assets.first(where: { $0.name.hasSuffix("-macOS.zip") })
        let sha = asset?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }

        return ReleaseInfo(
            version: version,
            title: release.name?.isEmpty == false ? release.name! : "v\(version)",
            notes: release.body ?? "",
            pageURL: URL(string: release.htmlURL) ?? Self.releasesPage,
            assetURL: asset.flatMap { URL(string: $0.browserDownloadURL) },
            assetSHA256: sha
        )
    }

    // MARK: - Alerts

    private func presentUpdateAlert(_ info: ReleaseInfo) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "发现新版本 v\(info.version)"
        let notes = Self.plainNotes(info.notes)
        alert.informativeText = "当前版本 v\(currentVersion)。\n\n\(info.title)" + (notes.isEmpty ? "" : "\n\n\(notes)")
        if info.assetURL != nil {
            alert.addButton(withTitle: "下载并安装")
        } else {
            alert.addButton(withTitle: "打开发布页")
        }
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if info.assetURL != nil {
                Task { await downloadAndInstall() }
            } else {
                NSWorkspace.shared.open(info.pageURL)
            }
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(info.version, forKey: PrefKeys.skippedVersion)
        default:
            break
        }
    }

    private func presentInfoAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// 把 Markdown 发布说明压缩为适合弹窗的纯文本摘要。
    private static func plainNotes(_ markdown: String) -> String {
        let cleaned = markdown
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "### ", with: "")
            .replacingOccurrences(of: "## ", with: "")
        return cleaned.count > 600 ? String(cleaned.prefix(600)) + "…" : cleaned
    }

    // MARK: - Download & Install

    func downloadAndInstall() async {
        guard let info = latest, let assetURL = info.assetURL else {
            NSWorkspace.shared.open(latest?.pageURL ?? Self.releasesPage)
            return
        }
        guard !isBusy else { return }

        let currentApp = Bundle.main.bundleURL
        let parentDir = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            phase = .failed("无权写入 \(parentDir.path)")
            presentInfoAlert(title: "无法自动安装", message: "当前 App 所在目录不可写：\(parentDir.path)\n已为你打开发布页，请手动下载安装。")
            NSWorkspace.shared.open(info.pageURL)
            return
        }

        phase = .downloading
        do {
            let (tmpZip, resp) = try await URLSession.shared.download(from: assetURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.message("下载失败：HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }

            if let expected = info.assetSHA256?.lowercased() {
                let digest = SHA256.hash(data: try Data(contentsOf: tmpZip))
                let actual = digest.map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw UpdateError.message("安装包 SHA-256 校验失败") }
            }

            phase = .installing
            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DecisionAdvisorUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", tmpZip.path, workDir.path])
            try? FileManager.default.removeItem(at: tmpZip)

            guard let newApp = try FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError.message("安装包内未找到 .app")
            }
            let newBundle = Bundle(url: newApp)
            guard newBundle?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError.message("安装包的 Bundle ID 与当前 App 不一致，已中止")
            }
            let newVersion = newBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            guard Self.compare(newVersion, currentVersion) == .orderedDescending else {
                throw UpdateError.message("安装包版本 v\(newVersion) 不高于当前版本")
            }
            try Self.run("/usr/bin/xattr", ["-cr", newApp.path])

            try launchSwapScript(newApp: newApp, target: currentApp, workDir: workDir)
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
            presentInfoAlert(title: "更新失败", message: error.localizedDescription)
        }
    }

    /// 由独立 shell 进程在本 App 退出后完成替换并重新打开，避免运行中的二进制被覆盖。
    private func launchSwapScript(newApp: URL, target: URL, workDir: URL) throws {
        let script = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
        backup="$3.previous-$$"
        mv "$2" "$backup" || exit 1
        if /usr/bin/ditto "$1" "$2"; then
          rm -rf "$backup"
        else
          rm -rf "$2"; mv "$backup" "$2"
        fi
        rm -rf "$4"
        /usr/bin/open "$2"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-c", script, "swap", newApp.path, target.path,
                          target.deletingLastPathComponent().appendingPathComponent(".DecisionAdvisor").path,
                          workDir.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw UpdateError.message("\((tool as NSString).lastPathComponent) 执行失败（退出码 \(proc.terminationStatus)）")
        }
    }

    // MARK: - Version compare

    /// 按点分数字段比较（0.13 > 0.12，1.00 > 0.99）；非数字部分按 0 处理。
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

private enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
        case htmlURL = "html_url"
    }
}
