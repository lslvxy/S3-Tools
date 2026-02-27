import SwiftUI

struct ToolbarView: ToolbarContent {
    @EnvironmentObject var appState: AppState

    var body: some ToolbarContent {
        // 左侧：环境切换（menu 样式，避免 macOS 26 pill 形 segmented control）
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Picker("环境", selection: Binding(
                    get: { appState.currentEnvironment },
                    set: { newEnv in
                        Task { await appState.switchEnvironment(to: newEnv) }
                    }
                )) {
                    ForEach(S3Environment.allCases) { env in
                        Text(env.displayName).tag(env)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("切换环境")

                statusDot
            }
        }

        // 右侧：上传开关（Offline 专用）
        ToolbarItem(placement: .primaryAction) {
            if appState.currentEnvironment == .offline {
                Toggle(isOn: $appState.isUploadEnabled) {
                    Label(
                        appState.isUploadEnabled ? "上传已开" : "允许上传",
                        systemImage: appState.isUploadEnabled ? "arrow.up.circle.fill" : "arrow.up.circle"
                    )
                }
                .toggleStyle(.button)
                .tint(.orange)
                .help(appState.isUploadEnabled ? "上传已启用（点击关闭）" : "允许上传（点击启用，谨慎操作）")
            }
        }

        // 右侧：强制刷新（忽略缓存）
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task {
                    if let bucket = appState.selectedBucket {
                        await appState.loadObjects(bucket: bucket, prefix: appState.currentPrefix, forceRefresh: true)
                    } else {
                        await appState.loadBuckets()
                    }
                }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(appState.isLoading)
            .help("强制刷新，忽略缓存 (⌘R)")
        }

        // 右侧：设置
        ToolbarItem(placement: .primaryAction) {
            SettingsLink {
                Label("设置", systemImage: "gear")
            }
            .help("设置")
        }
    }

    /// 仅显示连接状态小圆点 + 文字，不使用自定义圆角背景
    @ViewBuilder
    private var statusDot: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(appState.connectionStatus.displayText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }
}
