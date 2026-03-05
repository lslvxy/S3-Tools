import SwiftUI

struct FileListView: View {
    @EnvironmentObject var appState: AppState
    // 默认按修改时间降序排列
    @State private var sortOrder: [KeyPathComparator<S3Object>] = [
        KeyPathComparator(\.sortableDate, order: .reverse)
    ]

    private var sortedObjects: [S3Object] {
        appState.objects.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.selectedBucket == nil {
                ContentUnavailableView(
                    "选择一个 Bucket",
                    systemImage: "cylinder",
                    description: Text("从左侧选择一个 Bucket 开始浏览")
                )
            } else if appState.isLoading && appState.objects.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("加载中...")
                    Spacer()
                }
            } else if appState.objects.isEmpty {
                ContentUnavailableView(
                    appState.filterPattern.isEmpty ? "此目录为空" : "无匹配文件",
                    systemImage: appState.filterPattern.isEmpty ? "folder" : "doc.text.magnifyingglass",
                    description: Text(appState.filterPattern.isEmpty ? "当前路径没有文件" : "没有匹配正则 \"\(appState.filterPattern)\" 的文件")
                )
            } else {
                ZStack {
                    Table(sortedObjects, selection: $appState.selectedObjects, sortOrder: $sortOrder) {
                        TableColumn("") { obj in
                            Image(systemName: obj.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(obj.isDirectory ? .yellow : .blue)
                                .frame(width: 16)
                        }
                        .width(20)

                        TableColumn("名称", value: \.sortableName) { obj in
                            Text(obj.displayName)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .help(obj.key)
                                // 不拦截点击事件，让 Table 处理单击选中；双击导航由 primaryAction 处理
                        }

                        TableColumn("大小", value: \.sortableSize) { obj in
                            Text(obj.formattedSize)
                                .foregroundStyle(.secondary)
                                .font(.body)
                        }
                        .width(80)

                        TableColumn("修改时间", value: \.sortableDate) { obj in
                            Text(obj.formattedDate)
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                        .width(140)

                        TableColumn("操作") { obj in
                            if !obj.isDirectory {
                                Button {
                                    Task { await appState.enqueueDownloads(objects: [obj]) }
                                } label: {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(.blue)
                                }
                                .buttonStyle(.borderless)
                                .help("下载 \(obj.displayName)")
                            } else {
                                Button {
                                    navigateInto(obj)
                                } label: {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("进入目录")
                            }
                        }
                        .width(50)
                    }
                    .contextMenu(forSelectionType: String.self) { keys in
                        if !keys.isEmpty {
                            Button("下载选中 (\(keys.count) 个)") {
                                let objs = appState.objects.filter { keys.contains($0.key) }
                                Task { await appState.enqueueDownloads(objects: objs) }
                            }
                            Divider()
                            Button("复制路径") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(keys.joined(separator: "\n"), forType: .string)
                            }
                        }
                    } primaryAction: { keys in
                        guard keys.count == 1, let key = keys.first else { return }
                        if let obj = appState.objects.first(where: { $0.key == key }), obj.isDirectory {
                            navigateInto(obj)
                        }
                    }
                    // 全局遮罩：加载中时覆盖列表
                    if appState.isLoading {
                        ZStack {
                            Color(nsColor: .windowBackgroundColor).opacity(0.55)
                            ProgressView("加载中...")
                                .padding(16)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .allowsHitTesting(false)
                    }
                } // end outer ZStack
            } // end else

            // 分页控件
            if appState.selectedBucket != nil && !appState.objects.isEmpty {
                paginationBar
            }
        }
    }

    private func navigateInto(_ obj: S3Object) {
        guard let bucket = appState.selectedBucket else { return }
        appState.clearFilterSilently()
        appState.currentPrefix = obj.key
        Task { await appState.loadObjects(bucket: bucket, prefix: obj.key) }
    }

    @ViewBuilder
    private var paginationBar: some View {
        HStack {
            // 总数信息
            if !appState.filterPattern.isEmpty {
                Text("前缀过滤: \(appState.objects.count) 个对象")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(appState.objects.count) 个对象")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if appState.isLoading {
                ProgressView().scaleEffect(0.6)
            }

            // 全选 / 取消选
            Button("全选") {
                appState.selectedObjects = Set(appState.objects.filter { !$0.isDirectory }.map { $0.key })
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Button("取消选") {
                appState.selectedObjects = []
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Divider().frame(height: 14)

            Text("第 \(appState.currentPage) 页")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.hasMorePages {
                Button("加载更多") {
                    Task { await appState.loadNextPage() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(appState.isLoading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}
