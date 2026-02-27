import SwiftUI

struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // 主区域：左侧 Bucket 树 + 右侧文件区
        NavigationSplitView {
            BucketSidebarView()
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
        } detail: {
            VStack(spacing: 0) {
                // 路径 + 过滤栏
                PathInputView()
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .bottom) { Divider() }

                // 文件列表
                FileListView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)

                // 下载进度
                if !appState.downloadTasks.filter({ $0.status != .completed }).isEmpty {
                    DownloadProgressView()
                        .overlay(alignment: .top) { Divider() }
                }

                // 日志面板
                LogPanelView()
                    .overlay(alignment: .top) { Divider() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(
            appState.currentError?.title ?? "错误",
            isPresented: $appState.showError,
            presenting: appState.currentError
        ) { _ in
            Button("确定") { appState.showError = false }
            Button("查看日志") {
                appState.showError = false
                // 打开 Finder 显示日志文件
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: AppLogger.shared.logFileLocation)
                ])
            }
        } message: { error in
            VStack(alignment: .leading, spacing: 4) {
                Text(error.message)
                Divider()
                Text("建议：\(error.suggestion)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .toolbar {
            ToolbarView()
        }
        .task {
            // 自动连接到上次使用的环境
            await appState.switchEnvironment(to: appState.appSettings.lastEnvironment)
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshRequested)) { _ in
            Task {
                if let bucket = appState.selectedBucket {
                    await appState.loadObjects(bucket: bucket, prefix: appState.currentPrefix, forceRefresh: true)
                } else {
                    await appState.loadBuckets()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadSelectedRequested)) { _ in
            Task { await appState.downloadSelected() }
        }
    }
}
