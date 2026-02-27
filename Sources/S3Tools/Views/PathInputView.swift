import SwiftUI

struct PathInputView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var completion = PathCompletionService()
    @State private var pathInput: String = ""
    @State private var regexInput: String = ""
    @State private var showRegexDownload = false
    @FocusState private var pathFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // 面包屑或路径输入
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    ZStack(alignment: .topLeading) {
                        TextField(
                            "路径 (e.g. data/2026/)",
                            text: $pathInput,
                            onCommit: navigateToPath
                        )
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .focused($pathFocused)
                        .onChange(of: pathInput) { _, newVal in
                            guard let bucket = appState.selectedBucket else { return }
                            completion.requestCompletions(
                                input: newVal,
                                bucket: bucket,
                                service: appState.s3Service
                            )
                        }

                        // 自动补全下拉
                        if !completion.suggestions.isEmpty && pathFocused {
                            VStack(alignment: .leading, spacing: 0) {
                                Spacer().frame(height: 24)
                                completionList
                            }
                            .zIndex(100)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(pathFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )

                // Go 按钮
                Button("跳转", action: navigateToPath)
                    .keyboardShortcut(.return)
                    .disabled(appState.selectedBucket == nil)

                // 快速跳转菜单
                Menu {
                    ForEach(QuickJumpEntry.all) { entry in
                        Button {
                            jumpTo(entry: entry)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(entry.id)
                                Text(entry.directoryPrefix)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    Label("快速跳转", systemImage: "bookmark")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(appState.selectedBucket == nil)
                .help("从预定义路径快速跳转")

                Divider().frame(height: 22)

                // 过滤框
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("正则过滤 (e.g. .*\\.log$)", text: $appState.filterPattern)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 200)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

                Spacer()

                // 批量下载按钮
                let selectedCount = appState.selectedObjects.count
                Button {
                    Task { await appState.downloadSelected() }
                } label: {
                    Label(
                        selectedCount > 0 ? "下载选中 (\(selectedCount))" : "下载选中",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(selectedCount == 0)
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                // 正则下载
                Button {
                    showRegexDownload = true
                } label: {
                    Label("正则下载", systemImage: "arrow.down.circle.dotted")
                }
                .disabled(appState.selectedBucket == nil)

                // 上传按钮（仅 offline + 开关打开）
                if appState.currentEnvironment == .offline && appState.isUploadEnabled {
                    uploadButton
                }
            }

            // 当前路径面包屑
            if !appState.currentPrefix.isEmpty {
                breadcrumbView
            }
        }
        .sheet(isPresented: $showRegexDownload) {
            RegexDownloadSheet()
        }
        .onAppear {
            pathInput = appState.currentPrefix
        }
        // 当外部（FileListView 导航、侧边栏选 bucket）改变前缀时，同步到输入框
        .onChange(of: appState.currentPrefix) { _, newVal in
            pathInput = newVal
        }
        .onChange(of: appState.selectedBucket) { _, _ in
            pathInput = appState.currentPrefix
        }
    }

    private func navigateToPath() {
        guard let bucket = appState.selectedBucket else { return }
        appState.currentPrefix = pathInput
        completion.suggestions = []
        Task { await appState.loadObjects(bucket: bucket, prefix: pathInput) }
    }

    private func jumpTo(entry: QuickJumpEntry) {
        guard let bucket = appState.selectedBucket else { return }
        let prefix = entry.directoryPrefix
        pathInput = prefix
        appState.currentPrefix = prefix
        completion.suggestions = []
        Task { await appState.loadObjects(bucket: bucket, prefix: prefix) }
    }

    @ViewBuilder
    private var completionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(completion.suggestions.prefix(10), id: \.self) { suggestion in
                Button {
                    pathInput = suggestion
                    completion.suggestions = []
                } label: {
                    HStack {
                        Image(systemName: suggestion.hasSuffix("/") ? "folder" : "doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(suggestion)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color(nsColor: .controlBackgroundColor))
                if suggestion != completion.suggestions.prefix(10).last {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .offset(y: 2)
    }

    @ViewBuilder
    private var breadcrumbView: some View {
        HStack(spacing: 4) {
            let parts = appState.currentPrefix
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)

            Button(appState.selectedBucket ?? "") {
                appState.currentPrefix = ""
                pathInput = ""
                Task {
                    if let b = appState.selectedBucket {
                        await appState.loadObjects(bucket: b, prefix: "")
                    }
                }
            }
            .buttonStyle(.link)
            .font(.caption)

            ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                if !part.isEmpty {
                    Text("/").font(.caption).foregroundStyle(.secondary)
                    let prefix = parts[0...idx].joined(separator: "/") + "/"
                    Button(part) {
                        appState.currentPrefix = prefix
                        pathInput = prefix
                        Task {
                            if let b = appState.selectedBucket {
                                await appState.loadObjects(bucket: b, prefix: prefix)
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var uploadButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.begin { response in
                guard response == .OK else { return }
                let files = panel.urls
                Task {
                    for file in files {
                        let key = (appState.currentPrefix) + file.lastPathComponent
                        guard let bucket = appState.selectedBucket else { return }
                        do {
                            try await appState.s3Service?.uploadObject(
                                bucket: bucket,
                                key: key,
                                fileURL: file
                            ) { _ in }
                            appState.appLogger.log(action: "上传", detail: "s3://\(bucket)/\(key)", level: .info)
                        } catch {
                            appState.showAppError(AppError.from(error))
                        }
                    }
                    if let b = appState.selectedBucket {
                        await appState.loadObjects(bucket: b, prefix: appState.currentPrefix)
                    }
                }
            }
        } label: {
            Label("上传", systemImage: "arrow.up.circle")
                .foregroundStyle(.orange)
        }
        .help("上传文件到当前路径（Offline 专用）")
    }
}

// MARK: - 正则下载弹窗

struct RegexDownloadSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var pattern: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("正则表达式批量下载")
                .font(.headline)

            Text("输入正则表达式，匹配当前目录中的文件名，然后批量下载。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("正则表达式 (e.g. .*2025.*\\.log$)", text: $pattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: 320)

            if !pattern.isEmpty {
                let count = matchCount
                Text("匹配到 \(count) 个文件")
                    .foregroundStyle(count > 0 ? .primary : .secondary)
            }

            HStack(spacing: 12) {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.escape)

                Button("开始下载") {
                    Task {
                        await appState.downloadWithRegex(pattern: pattern)
                        dismiss()
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(pattern.isEmpty || matchCount == 0)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private var matchCount: Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return 0 }
        return appState.objects.filter { obj in
            let name = obj.displayName
            return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }.count
    }
}
