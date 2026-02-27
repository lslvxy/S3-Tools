# S3 Tools

一个专为 macOS 设计的 S3 图形化操作工具，基于 SwiftUI + AWS SDK for Swift 开发。

---

## 功能特性

| 功能 | 说明 |
|------|------|
| 多环境支持 | Offline / Production 一键切换 |
| 安全凭证管理 | 支持环境变量、`~/.aws/credentials`，无需修改代码 |
| 浏览 & 下载 | 文件列表、单文件下载、批量下载 |
| 正则过滤 | 实时正则过滤文件名，正则批量下载 |
| 路径补全 | 输入 prefix 自动补全，带缓存和防抖 |
| 多线程下载 | 最多 16 个并发任务，实时进度显示 |
| 上传控制 | Production 永久禁止上传；Offline 通过开关控制 |
| 分页加载 | 每页 200 条（可调），支持加载更多 |
| 操作日志 | 内存 + 文件双重记录，可按级别过滤 |
| 错误引导 | 详细错误说明 + 解决建议 |
| 深色模式 | 跟随系统设置自动切换 |

---

## 系统要求

- macOS 14 Sonoma 及以上
- Xcode 15+ （开发时）
- Swift 5.9+

---

## 快速开始

### 1. 配置 AWS 凭证

**推荐方式：`~/.aws/credentials` 文件**

```ini
[offline]
aws_access_key_id = YOUR_OFFLINE_AK
aws_secret_access_key = YOUR_OFFLINE_SK

[production]
aws_access_key_id = YOUR_PROD_AK
aws_secret_access_key = YOUR_PROD_SK
```

**备选方式：环境变量**

```bash
export AWS_ACCESS_KEY_ID=YOUR_AK
export AWS_SECRET_ACCESS_KEY=YOUR_SK
export AWS_SESSION_TOKEN=YOUR_TOKEN  # 使用临时凭证时需要
```

凭证读取优先级：**环境变量 > ~/.aws/credentials > ~/.aws/config**

> 凭证轮换后只需更新配置文件或环境变量，无需重启应用（重新连接环境即可刷新）。

---

### 2. 配置 Endpoint（Offline 环境）

打开 App → 设置（⌘,）→ **环境配置**，填写 Offline Endpoint，例如：

```
http://localhost:9000       # MinIO 本地
http://your-minio.internal  # 内网 MinIO
```

> Production 环境使用 AWS 标准 Endpoint，无需手动配置。

---

### 3. 构建 & 运行

```bash
# 克隆项目
git clone <your-repo>
cd S3Tools

# 拉取依赖 & 构建
swift build

# 或在 Xcode 中打开
open Package.swift
```

---

### 4. 打包为 .app

```bash
# 使用 Xcode 打包
xcodebuild archive \
  -scheme S3Tools \
  -archivePath ./build/S3Tools.xcarchive

# 导出 .app
xcodebuild -exportArchive \
  -archivePath ./build/S3Tools.xcarchive \
  -exportPath ./build/S3Tools.app \
  -exportOptionsPlist ExportOptions.plist
```

打包完成后可使用 `create-dmg` 工具生成 `.dmg` 安装包：

```bash
brew install create-dmg
create-dmg \
  --volname "S3 Tools" \
  --window-size 600 400 \
  --icon-size 100 \
  --app-drop-link 450 180 \
  "S3Tools.dmg" \
  "./build/S3Tools.app"
```

---

## 界面说明

```
┌─────────────────────────────────────────────────────────────┐
│  S3Tools  [环境: offline | production]  [● 已连接]  [⚙️]   │
├──────────────┬──────────────────────────────────────────────┤
│  Buckets     │  路径输入框（Tab 自动补全）  正则过滤框        │
│  ──────────  │  [下载选中(N)]  [正则下载]  [上传↑ offline]  │
│  my-bucket   ├──────────────────────────────────────────────┤
│  archive     │  文件列表（Table，可多选，双击进入目录）       │
│  data        │  ...                                         │
│              │  [全选] [取消选]  第1页  [加载更多]          │
├──────────────┴──────────────────────────────────────────────┤
│  下载队列：progress bars                                     │
├─────────────────────────────────────────────────────────────┤
│  操作日志（可折叠）                                          │
└─────────────────────────────────────────────────────────────┘
```

---

## 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| 认证失败 | AK/SK 过期或错误 | 更新 `~/.aws/credentials` 并重新切换环境 |
| 无法连接 | Endpoint 不可达 / VPN 未连接 | 检查设置中的 Endpoint 配置 |
| 403 权限不足 | IAM 策略限制 | 检查 AK 对应的 S3 权限 |
| 上传按钮不显示 | Production 环境或未开启上传开关 | 切换到 Offline 并在工具栏开启上传 |
| 文件列表为空 | Prefix 不匹配或真的为空 | 检查路径，或清空过滤条件 |

---

## 日志文件位置

```
~/Library/Logs/S3Tools/s3tools-YYYY-MM-DD.log
```

---

## 项目结构

```
S3Tools/
├── Package.swift
└── Sources/S3Tools/
    ├── S3ToolsApp.swift         # 入口
    ├── AppState.swift           # 全局状态
    ├── Config/
    │   ├── CredentialsManager.swift
    │   └── AppSettings.swift
    ├── Models/
    │   ├── S3Environment.swift
    │   ├── S3Object.swift
    │   ├── DownloadTask.swift
    │   └── LogEntry.swift
    ├── Services/
    │   ├── S3Service.swift
    │   ├── DownloadManager.swift
    │   └── PathCompletionService.swift
    ├── Views/
    │   ├── MainView.swift
    │   ├── ToolbarView.swift
    │   ├── BucketSidebarView.swift
    │   ├── FileListView.swift
    │   ├── PathInputView.swift
    │   ├── DownloadProgressView.swift
    │   ├── LogPanelView.swift
    │   └── SettingsView.swift
    └── Utilities/
        ├── AppLogger.swift
        └── INIParser.swift
```
