import SwiftUI

struct LogPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded: Bool = true
    @State private var filterLevel: LogLevel? = nil

    private var displayedEntries: [LogEntry] {
        if let level = filterLevel {
            return appState.logEntries.filter { $0.level == level }
        }
        return appState.logEntries
    }

    private var panelHeight: CGFloat { isExpanded ? 160 : 30 }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack(spacing: 8) {
                Label("操作日志", systemImage: "doc.text")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                // 级别过滤
                Picker("", selection: $filterLevel) {
                    Text("全部").tag(Optional<LogLevel>.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(Optional(level))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .font(.caption)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: AppLogger.shared.logFileLocation)
                    ])
                } label: {
                    Text("打开日志文件")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button {
                    appState.logEntries.removeAll()
                } label: {
                    Text("清空")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(displayedEntries) { entry in
                                LogEntryRow(entry: entry)
                                    .id(entry.id)
                                Divider().opacity(0.3)
                            }
                        }
                    }
                    .onChange(of: appState.logEntries.count) { _, _ in
                        if let first = displayedEntries.first {
                            withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            }
        }
        .frame(height: panelHeight)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
        .onReceive(NotificationCenter.default.publisher(for: .newLogEntry)) { notification in
            if let entry = notification.object as? LogEntry {
                appState.addLogEntry(entry)
            }
        }
        .onAppear {
            AppLogger.shared.configure(
                environment: appState.currentEnvironment.displayName
            ) { entry in
                appState.addLogEntry(entry)
            }
        }
        .onChange(of: appState.currentEnvironment) { _, newEnv in
            AppLogger.shared.configure(environment: newEnv.displayName) { entry in
                appState.addLogEntry(entry)
            }
        }
    }
}

struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(entry.formattedTimestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            levelBadge

            Text("[\(entry.environment)]")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(entry.action)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .frame(width: 80, alignment: .leading)

            Text(entry.detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.level == .error ? .red : .primary)
                .lineLimit(1)
                .help(entry.detail)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(entry.level == .error ? Color.red.opacity(0.05) : Color.clear)
        .contextMenu {
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.logLine, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var levelBadge: some View {
        Text(entry.level.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(levelColor.opacity(0.15))
            .foregroundStyle(levelColor)
            .cornerRadius(3)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .debug: return .gray
        }
    }
}

extension Notification.Name {
    static let newLogEntry = Notification.Name("newLogEntry")
}
