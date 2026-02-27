import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: SettingsTab = .environments

    enum SettingsTab: String, CaseIterable {
        case environments = "环境配置"
        case download = "下载"
        case credentials = "凭证说明"
        case about = "关于"

        var icon: String {
            switch self {
            case .environments: return "server.rack"
            case .download: return "arrow.down.circle"
            case .credentials: return "key"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            EnvironmentSettingsTab()
                .tabItem {
                    Label(SettingsTab.environments.rawValue, systemImage: SettingsTab.environments.icon)
                }
                .tag(SettingsTab.environments)

            DownloadSettingsTab()
                .tabItem {
                    Label(SettingsTab.download.rawValue, systemImage: SettingsTab.download.icon)
                }
                .tag(SettingsTab.download)

            CredentialsGuideTab()
                .tabItem {
                    Label(SettingsTab.credentials.rawValue, systemImage: SettingsTab.credentials.icon)
                }
                .tag(SettingsTab.credentials)

            AboutTab()
                .tabItem {
                    Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon)
                }
                .tag(SettingsTab.about)
        }
        .frame(width: 560, height: 420)
    }
}

// MARK: - 环境配置 Tab

struct EnvironmentSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            ForEach(S3Environment.allCases) { env in
                Section(env.displayName) {
                    EnvironmentConfigForm(
                        env: env,
                        config: Binding(
                            get: { appState.appSettings.environmentConfigs[env] ?? .default(for: env) },
                            set: { appState.appSettings.environmentConfigs[env] = $0 }
                        )
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct EnvironmentConfigForm: View {
    let env: S3Environment
    @Binding var config: EnvironmentConfig

    var body: some View {
        LabeledContent("Endpoint") {
            if env == .production {
                Text("AWS 标准 Endpoint（根据 Region 自动选定）")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("留空使用 AWS 标准（或填入 http://minio:9000）", text: $config.endpoint)
                        .textFieldStyle(.roundedBorder)
                    Text("留空 = AWS S3 标准 Endpoint；如需 MinIO/LocalStack 请填写自定义地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        LabeledContent("Region") {
            TextField("us-east-1", text: $config.region)
                .textFieldStyle(.roundedBorder)
        }

        LabeledContent("Profile 名称") {
            TextField("offline / production", text: $config.profile)
                .textFieldStyle(.roundedBorder)
            Text("对应 ~/.aws/credentials 中的 [\(config.profile)] 段")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if env == .offline {
            LabeledContent("Path-style URL") {
                Toggle("", isOn: $config.usePathStyle)
                Text("使用 MinIO / LocalStack 等自定义 Endpoint 时需开启；AWS S3 标准无需开启")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if env == .production {
            LabeledContent("上传限制") {
                Label("Production 环境永久禁止上传", systemImage: "lock.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }
}

// MARK: - 下载設置 Tab

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

// MARK: - 凭证说明 Tab

struct CredentialsGuideTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("凭证配置说明")
                    .font(.headline)

                GroupBox("方式一：~/.aws/credentials 文件（推荐）") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("路径：\(appState.credentialsManager.credentialsFilePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        codeBlock("""
[offline]
aws_access_key_id = YOUR_OFFLINE_AK
aws_secret_access_key = YOUR_OFFLINE_SK

[production]
aws_access_key_id = YOUR_PROD_AK
aws_secret_access_key = YOUR_PROD_SK
""")
                    }
                    .padding(4)
                }

                GroupBox("方式二：环境变量") {
                    codeBlock("""
export AWS_ACCESS_KEY_ID=YOUR_AK
export AWS_SECRET_ACCESS_KEY=YOUR_SK
export AWS_SESSION_TOKEN=YOUR_TOKEN  # 可选
""")
                    .padding(4)
                }

                GroupBox("读取优先级") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. 环境变量（优先级最高）")
                        Text("2. ~/.aws/credentials 中对应 profile")
                        Text("3. ~/.aws/config 中对应 profile")
                        Text("4. 读取失败则提示凭证错误")
                    }
                    .font(.caption)
                    .padding(4)
                }

                Button("在 Finder 中打开 .aws 目录") {
                    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aws")
                    NSWorkspace.shared.open(dir)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func codeBlock(_ content: String) -> some View {
        Text(content)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
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
