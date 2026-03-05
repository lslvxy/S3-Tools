import SwiftUI

struct BucketSidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText: String = ""

    private var filteredBuckets: [String] {
        searchText.isEmpty ? appState.buckets
            : appState.buckets.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Label("Buckets", systemImage: "externaldrive")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.isLoading && appState.selectedBucket == nil {
                    ProgressView().scaleEffect(0.5)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }

            // 搜索框（有 bucket 时才显示）
            if !appState.buckets.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("筛选 bucket", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
            }

            if appState.buckets.isEmpty && !appState.connectionStatus.isConnected {
                ContentUnavailableView(
                    "未连接",
                    systemImage: "wifi.slash",
                    description: Text("请选择环境并连接")
                )
            } else if appState.buckets.isEmpty && appState.connectionStatus.isConnected {
                ContentUnavailableView(
                    "无 Bucket",
                    systemImage: "externaldrive.badge.xmark"
                )
            } else if filteredBuckets.isEmpty {
                ContentUnavailableView(
                    "无匹配结果",
                    systemImage: "magnifyingglass",
                    description: Text("没有名称包含 \"\(searchText)\" 的 bucket")
                )
            } else {
                List(filteredBuckets, id: \.self, selection: Binding(
                    get: { appState.selectedBucket },
                    set: { bucket in
                        if let b = bucket {
                            appState.selectedBucket = b
                            appState.currentPrefix = ""
                            Task { await appState.loadObjects(bucket: b, prefix: "") }
                        }
                    }
                )) { bucket in
                    let isActive = bucket == appState.selectedBucket
                    HStack(spacing: 4) {
                        Label(bucket, systemImage: "cylinder")
                        if isActive {
                            Spacer()
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                    .contextMenu {
                        Button("复制名称") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bucket, forType: .string)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

