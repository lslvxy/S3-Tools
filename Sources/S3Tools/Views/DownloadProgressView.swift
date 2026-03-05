import SwiftUI

struct DownloadProgressView: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded: Bool = true

    private var activeTasks: [DownloadTask] {
        appState.downloadTasks.filter {
            if case .completed = $0.status { return false }
            if case .cancelled = $0.status { return false }
            return true
        }
    }

    private var summaryText: String {
        let inProgress = appState.downloadTasks.filter {
            if case .inProgress = $0.status { return true }
            return false
        }.count
        let failed = appState.downloadTasks.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        let completed = appState.downloadTasks.filter { $0.status == .completed }.count
        var parts: [String] = []
        if inProgress > 0 { parts.append("\(inProgress) 个下载中") }
        if failed > 0 { parts.append("\(failed) 个失败") }
        if completed > 0 { parts.append("\(completed) 个完成") }
        return parts.joined(separator: " · ")
    }

    private var panelHeight: CGFloat { isExpanded ? 150 : 34 }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Label("下载队列", systemImage: "arrow.down.circle")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    appState.downloadTasks.removeAll {
                        $0.status == .completed || $0.status == .cancelled
                    }
                } label: {
                    Text("清除完成")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!appState.downloadTasks.contains {
                    $0.status == .completed || $0.status == .cancelled
                })

                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            if isExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.downloadTasks) { task in
                            DownloadTaskRow(task: task) {
                                appState.cancelDownload(id: task.id)
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(height: panelHeight)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

struct DownloadTaskRow: View {
    let task: DownloadTask
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 状态图标
            statusIcon
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.fileName)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                if case .inProgress(let p) = task.status {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                }
            }

            Spacer()

            // 速度 + 大小
            VStack(alignment: .trailing, spacing: 2) {
                Text(task.status.displayText)
                    .font(.caption)
                    .foregroundStyle(statusColor)

                if !task.speedText.isEmpty {
                    Text(task.speedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(ByteCountFormatter.string(fromByteCount: task.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // 取消按钮（等待中 / 下载中）
            switch task.status {
            case .pending, .inProgress:
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("取消下载")
            default:
                EmptyView()
            }

            // 打开文件按钮（完成后）
            if task.status == .completed, let url = task.localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .inProgress:
            ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
