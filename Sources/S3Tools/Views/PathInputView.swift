import SwiftUI

struct PathInputView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var completion = PathCompletionService()
    @State private var pathInput: String = ""
    @State private var regexInput: String = ""
    @State private var showRegexDownload = false
    @State private var showBookmarkManager = false
    @FocusState private var pathFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                // ── 路径输入（弹性填充剩余空间）────────────────────────────
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
                .frame(minWidth: 100, maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(pathFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .layoutPriority(1)   // 优先占满剩余宽度

                // Go 按钮
                Button(action: navigateToPath) {
                    Image(systemName: "arrow.right.circle")
                }
                .keyboardShortcut(.return)
                .disabled(appState.selectedBucket == nil)
                .help("跳转")

                // 书签菜单（图标 + 短标题）
                Menu {
                    let currentDir = appState.currentPrefix
                    Button {
                        addBookmark(path: currentDir)
                    } label: {
                        Label(
                            currentDir.isEmpty ? "添加书签（请先进入目录）" : "添加书签: \(currentDir)",
                            systemImage: "bookmark.badge.plus"
                        )
                    }
                    .disabled(currentDir.isEmpty || appState.selectedBucket == nil)

                    Button {
                        showBookmarkManager = true
                    } label: {
                        Label("管理书签...", systemImage: "list.bullet")
                    }

                    if !appState.appSettings.bookmarks.isEmpty {
                        Divider()
                        ForEach(appState.appSettings.bookmarks) { entry in
                            Button {
                                jumpTo(path: entry.directoryPrefix)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(entry.name)
                                    Text(entry.directoryPrefix)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "bookmark")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(appState.selectedBucket == nil)
                .help("书签")

                Divider().frame(height: 22)

                // ── 过滤框（固定宽度）────────────────────────────────────
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("过滤", text: $appState.filterPattern)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 90)
                    if !appState.filterPattern.isEmpty {
                        Button {
                            appState.filterPattern = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
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
                        .stroke(!appState.filterPattern.isEmpty ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1)
                )

                Divider().frame(height: 22)

                // ── 右侧操作按钮（图标为主，保持紧凑）────────────────────
                let selectedCount = appState.selectedObjects.count

                // 下载选中
                Button {
                    Task { await appState.downloadSelected() }
                } label: {
                    if selectedCount > 0 {
                        Label("\(selectedCount)", systemImage: "arrow.down.circle")
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .disabled(selectedCount == 0)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .help(selectedCount > 0 ? "下载选中 (\(selectedCount) 个)" : "下载选中")
                .fixedSize()

                // 正则下载
                Button {
                    showRegexDownload = true
                } label: {
                    Image(systemName: "arrow.down.circle.dotted")
                }
                .buttonStyle(.bordered)
                .disabled(appState.selectedBucket == nil)
                .help("正则表达式批量下载")
                .fixedSize()

                // 上传按钮（仅 offline + 开关打开）
                if appState.currentEnvironment == .offline && appState.isUploadEnabled {
                    uploadButton
                }
            }
            .padding(.horizontal, 4)

            // 当前路径面包屑
            if !appState.currentPrefix.isEmpty {
                breadcrumbView
            }
        }
        .sheet(isPresented: $showRegexDownload) {
            RegexDownloadSheet()
        }
        .sheet(isPresented: $showBookmarkManager) {
            BookmarkManagerSheet()
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

    private func jumpTo(path: String) {
        guard let bucket = appState.selectedBucket else { return }
        pathInput = path
        appState.currentPrefix = path
        completion.suggestions = []
        Task { await appState.loadObjects(bucket: bucket, prefix: path) }
    }

    private func addBookmark(path: String) {
        guard !path.isEmpty else { return }
        // 不重复添加
        guard !appState.appSettings.bookmarks.contains(where: { $0.path == path }) else { return }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        appState.appSettings.bookmarks.append(BookmarkEntry(name: name, path: path))
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
        .buttonStyle(.bordered)
        .help("上传文件到当前路径（Offline 专用）")
    }
}

// MARK: - 书签管理弹窗

struct BookmarkManagerSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var editingName: [UUID: String] = [:]
    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newPath = ""

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("管理书签")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if appState.appSettings.bookmarks.isEmpty {
                ContentUnavailableView(
                    "暂无书签",
                    systemImage: "bookmark.slash",
                    description: Text("点击下方按钮添加常用路径")
                )
            } else {
                List {
                    ForEach($appState.appSettings.bookmarks) { $bookmark in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("名称", text: $bookmark.name)
                                    .textFieldStyle(.plain)
                                    .font(.body.weight(.medium))
                                TextField("路径", text: $bookmark.path)
                                    .textFieldStyle(.plain)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                appState.appSettings.bookmarks.removeAll { $0.id == bookmark.id }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in
                        appState.appSettings.bookmarks.move(fromOffsets: from, toOffset: to)
                    }
                }
            }

            Divider()

            // 底部工具栏
            HStack {
                Button {
                    showAddSheet = true
                } label: {
                    Label("添加书签", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("恢复默认") {
                    appState.appSettings.bookmarks = BookmarkEntry.defaults
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 500, height: 460)
        .sheet(isPresented: $showAddSheet) {
            VStack(spacing: 16) {
                Text("添加书签")
                    .font(.headline)
                LabeledContent("名称") {
                    TextField("例: Markoff Done", text: $newName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("路径") {
                    TextField("例: FromAntFinancial/SOV/Markoff/done/", text: $newPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Button("取消") { showAddSheet = false }
                        .keyboardShortcut(.escape)
                    Spacer()
                    Button("添加") {
                        let name = newName.isEmpty ? (newPath.split(separator: "/").last.map(String.init) ?? newPath) : newName
                        appState.appSettings.bookmarks.append(BookmarkEntry(name: name, path: newPath))
                        newName = ""
                        newPath = ""
                        showAddSheet = false
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(newPath.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 400)
        }
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
