import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            EmbeddedBackendManager.shared.stopSync()
        }
    }
}

@main
struct DecisionAdvisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("成长决策顾问") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 620)
                .background(WindowConfigurator())
                .task {
                    await appState.bootstrap()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建对话") {
                    appState.selectedSection = .chat
                    appState.startNewChat()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .sidebar) {
                Button("切换侧边栏") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        appState.isSidebarVisible.toggle()
                    }
                }
                .keyboardShortcut("\\", modifiers: .command)

                Divider()

                Button("顾问对话") { appState.selectSection(.chat) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("记忆库") { appState.selectSection(.memories) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("速记收件箱") { appState.selectSection(.inbox) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("模型与设置") { appState.selectSection(.settings) }
                    .keyboardShortcut("4", modifiers: .command)
            }

            CommandMenu("记忆库") {
                Button("刷新状态与记忆") {
                    Task {
                        await appState.bootstrap()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button("切换到远程 VPS 后端") {
                    Task { await appState.switchBackendMode(.remoteVPS) }
                }
                .disabled(appState.backendMode == .remoteVPS)

                Button("切换到 App 内置本地后端") {
                    Task { await appState.switchBackendMode(.embeddedLocal) }
                }
                .disabled(appState.backendMode == .embeddedLocal)

                Divider()

                Button("在访达中打开本机 iCloud 记忆目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: appState.localICloudVaultPath))
                }
            }
        }
    }
}
