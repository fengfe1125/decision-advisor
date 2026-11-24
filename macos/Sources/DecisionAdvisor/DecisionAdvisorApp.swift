import AppKit
import SwiftUI

@main
struct DecisionAdvisorApp: App {
    @State private var appState = AppState()
    @State private var updater = UpdateChecker()

    var body: some Scene {
        WindowGroup("成长决策顾问") {
            ContentView()
                .environment(appState)
                .environment(updater)
                .frame(minWidth: 900, minHeight: 620)
                .background(WindowConfigurator())
                .task {
                    await appState.bootstrap()
                    await updater.checkOnLaunchIfNeeded()
                }
        }
        .defaultSize(width: 1320, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(updater.isBusy)
            }

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

                Button("备份云端记忆回本机 iCloud") {
                    Task { await appState.backupRemoteVaultToLocalICloud() }
                }
                .disabled(appState.isBackingUpVault || !appState.isOnline)

                Button("在访达中打开本机 iCloud 备份目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: appState.localICloudVaultPath))
                }
            }
        }
    }
}
