import SwiftUI
import AppKit

@main
struct S3ToolsApp: App {
    @StateObject private var appState = AppState()

    init() {
        // 从 bundle 中加载 .icns 并设置 Dock 图标
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("操作") {
                Button("刷新") {
                    NotificationCenter.default.post(name: .refreshRequested, object: nil)
                }
                .keyboardShortcut("r")

                Divider()

                Button("下载选中文件") {
                    NotificationCenter.default.post(name: .downloadSelectedRequested, object: nil)
                }
                .keyboardShortcut("d")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

extension Notification.Name {
    static let refreshRequested = Notification.Name("refreshRequested")
    static let downloadSelectedRequested = Notification.Name("downloadSelectedRequested")
}
