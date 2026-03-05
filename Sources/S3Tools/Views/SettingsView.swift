import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: SettingsTab = .profiles

    enum SettingsTab: String, CaseIterable {
        case profiles = "环境 Profiles"
        case download = "下载"
        case about = "关于"

        var icon: String {
            switch self {
            case .profiles: return "server.rack"
            case .download: return "arrow.down.circle"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ProfilesTab()
                .tabItem { Label(SettingsTab.profiles.rawValue, systemImage: SettingsTab.profiles.icon) }
                .tag(SettingsTab.profiles)

            DownloadSettingsTab()
                .tabItem { Label(SettingsTab.download.rawValue, systemImage: SettingsTab.download.icon) }
                .tag(SettingsTab.download)

            AboutTab()
                .tabItem { Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon) }
                .tag(SettingsTab.about)
        }
        .frame(width: 580, height: 460)
    }
}

// MARK: - Profiles Tab（只读展示 ~/.aws/s3tools 解析结果）

struct ProfilesTab: View {
    @EnvironmentObject var appState: AppState
    @State private var profiles: [ProfileConfig] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                // ── 文件状态 ──────────────────────────────────────────────
                HStack(spacing: 8) {
                    let exists = appState.credentialsManager.configFileExists
                    Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(exists ? .green : .red)
                    Text(appState.credentialsManager.configFilePath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") {
                        profiles = appState.credentialsManager.loadProfiles()
                    }
                    .buttonStyle(.borderless)
                    Button("打开文件夹") {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: appState.credentialsManager.configFilePath)
                                .deletingLastPathComponent()
                        )
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 4)

                if profiles.isEmpty {
                    Text("~/.aws/s3tools 文件不存在或未配置任何 profile")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.horizontal, 4)
                } else {
                    // ── Profile 列表 ──────────────────────────────────────
                    Text("共 \(profiles.count) 个环境（全部来自 ~/.aws/s3tools，不可在此编辑）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    ForEach(profiles) { profile in
                        ProfileRow(profile: profile)
                    }
                }

                // ── 配置格式说明（始终展示）────────────────────────────────
                GroupBox("配置文件格式说明") {
                    VStack(alignment: .leading, spacing: 8) {
                        codeBlock("""
[default]
region = ap-southeast-1          # 全局默认 region（可省略）

[my-offline]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
endpoint = http://minio:9000     # MinIO/LocalStack 自定义地址；留空=AWS 标准
region = us-east-1               # 留空则继承 [default]
path_style = true                # MinIO 需要开启；AWS S3 无需

[company-prod]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
# region/endpoint 省略则使用 [default] 值

[staging-prod-fix]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
is_production = false            # 名字含 "prod" 但显式声明为非生产（允许上传）
""")
                        VStack(alignment: .leading, spacing: 4) {
                            Label("生产环境自动判断", systemImage: "info.circle")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Text("名称含 prod / production / live / online / prd → 自动标记为生产（禁止上传）")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("用 is_production = false 可强制覆盖自动判断结果")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }
            }
            .padding()
        }
        .onAppear {
            profiles = appState.credentialsManager.loadProfiles()
        }
    }

    @ViewBuilder
    private func codeBlock(_ content: String) -> some View {
        Text(content)
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct ProfileRow: View {
    let profile: ProfileConfig

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                // 标题行
                HStack {
                    Image(systemName: profile.isProduction ? "cloud.fill" : "desktopcomputer")
                        .foregroundStyle(profile.isProduction ? .orange : .green)
                    Text(profile.name)
                        .fontWeight(.semibold)
                    if profile.isProduction {
                        Label("生产", systemImage: "lock.fill")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .cornerRadius(4)
                    }
                    Spacer()
                }

                Divider()

                // 配置详情（只读）
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Region").foregroundStyle(.secondary).font(.caption)
                        Text(profile.region).font(.system(.caption, design: .monospaced))
                    }
                    if !profile.endpoint.isEmpty {
                        GridRow {
                            Text("Endpoint").foregroundStyle(.secondary).font(.caption)
                            Text(profile.endpoint).font(.system(.caption, design: .monospaced))
                        }
                    }
                    if profile.usePathStyle {
                        GridRow {
                            Text("Path-style").foregroundStyle(.secondary).font(.caption)
                            Text("已开启").font(.caption)
                        }
                    }
                    GridRow {
                        Text("Access Key").foregroundStyle(.secondary).font(.caption)
                        Text(maskedKey(profile.accessKeyId)).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .padding(4)
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let prefix = key.prefix(4)
        let suffix = key.suffix(4)
        return "\(prefix)••••••••\(suffix)"
    }
}

// MARK: - 下载设置 Tab

struct DownloadSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("下载行为") {
                LabeledContent("最大并发数") {
                    Stepper(
                        "\(appState.appSettings.maxConcurrentDownloads) 个",
                        value: $appState.appSettings.maxConcurrentDownloads,
                        in: 1...16
                    )
                }

                LabeledContent("下载目录") {
                    HStack {
                        Text(appState.appSettings.downloadDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Button("选择...") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.appSettings.downloadDirectory = url.path
                                appState.downloadDirectory = url
                            }
                        }
                    }
                }

                LabeledContent("校验 SHA256") {
                    Toggle("", isOn: $appState.appSettings.checksumEnabled)
                }
            }

            Section("分页") {
                LabeledContent("每页条数") {
                    Stepper(
                        "\(appState.appSettings.pageSize) 条",
                        value: $appState.appSettings.pageSize,
                        in: 50...1000,
                        step: 50
                    )
                }
            }

            Section("补全缓存") {
                LabeledContent("缓存有效期") {
                    Stepper(
                        "\(Int(appState.appSettings.completionCacheTTL)) 秒",
                        value: $appState.appSettings.completionCacheTTL,
                        in: 10...600,
                        step: 10
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 关于 Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("S3 Tools")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("版本 1.0.0")
                .foregroundStyle(.secondary)

            Text("一个支持 macOS 的 S3 图形化工具\n支持多环境、批量下载、路径自动补全")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Divider()

            VStack(spacing: 4) {
                Text("日志文件位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppLogger.shared.logFileLocation)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

