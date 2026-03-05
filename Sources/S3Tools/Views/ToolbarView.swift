import SwiftUI

struct ToolbarView: ToolbarContent {
    @EnvironmentObject var appState: AppState

    var body: some ToolbarContent {
        // 左侧：环境切换（menu 样式）
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 6) {
                Picker("环境", selection: Binding(
                    get: { appState.selectedProfile?.name },
                    set: { name in
                        if let name,
                           let profile = appState.availableProfiles.first(where: { $0.name == name }) {
                            Task { await appState.switchProfile(to: profile) }
                        }
                    }
                )) {
                    if appState.availableProfiles.isEmpty {
                        Text("无可用环境").tag(Optional<String>.none)
                    }
                    ForEach(appState.availableProfiles) { profile in
                        HStack(spacing: 4) {
                            Image(systemName: profile.isProduction ? "cloud" : "desktopcomputer")
                            Text(profile.name)
                        }
                        .tag(Optional(profile.name))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("切换环境")
                .disabled(appState.availableProfiles.isEmpty)

                statusDot
            }
        }

        // 右侧：上传开关（非生产环境专用）
        ToolbarItem(placement: .primaryAction) {
            if !(appState.selectedProfile?.isProduction ?? true) {
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
