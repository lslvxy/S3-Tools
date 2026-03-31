# S3 Tools

一个专为 macOS 设计的 S3 图形化客户端，基于 **SwiftUI + AWS SDK for Swift** 构建，支持多 Profile 切换、自动跨区域重定向、书签管理、分页、排序等生产级功能。

> **当前版本：1.0.1**

---

## 更新日志

### 1.0.1
- **书签时间变量**：路径中支持 `{Y}` `{M}` `{D}` `{YM}` `{YMD}` `{D1}` `{YMD1}` 占位符，点击书签时自动替换为当前日期
- **默认书签更新**：所有以日期结尾的内置路径已升级为 `{YMD1}` 变量，覆盖当旬文件（如今日 `2026033` 匹配 30~39 号）
- **下载目录结构**：下载文件按 `下载目录/bucket/S3 Key` 保存，保留完整目录层级，不再平铺到根目录
- **右键复制名称**：文件列表右键菜单新增「复制名称」（仅文件名），与「复制路径」（完整 Key）并列
- **下载取消按钮**：下载队列每个任务新增取消按钮，等待中和下载中均可取消；「清除完成」同时清除已取消任务
- **管理书签说明**：管理书签面板和添加书签弹框中新增时间变量速查表

### 1.0.0
- 初始版本发布

---

## 功能特性

| 功能 | 说明 |
|------|------|
| 多 Profile 切换 | 工具栏下拉菜单一键切换，读取 `~/.aws/s3tools`，切换时自动重连 |
| 生产环境保护 | Profile 名含 `prod / production / live` 等关键词时自动标记为生产，禁止上传，工具栏警告色显示 |
| 默认 Bucket | 每个 Profile 可配置 `default_bucket`，切换 Profile 时自动选中 |
| 自动跨区域重定向 | 探测 Bucket 真实 Region，自动用 Regional Client 重试（listObjects / download） |
| 浏览与导航 | 侧边栏 Bucket 列表（含搜索 + 当前 Bucket ★ 高亮）+ 文件列表进入目录 + 面包屑导航 |
| 路径输入与补全 | 输入前缀后 Tab 自动补全目录，防抖 + 本地缓存；支持文件名前缀补全（前缀含文件时自动填入完整路径） |
| 书签管理 | 内置 80+ 预定义路径，支持增删改排序，新书签置顶，持久化存储 |
| 前缀过滤 | 输入前缀后自动通过服务端 `ListObjectsV2 prefix` 过滤，400ms 防抖；导航时自动清除 |
| 文件列表排序 | 默认按修改时间降序，点击表头切换 名称 / 大小 / 时间 三列排序 |
| 分页加载 | 每页条目数可配置（默认 200），支持「加载更多」增量追加 |
| 缓存机制 | 首页结果缓存 5 分钟，命中缓存直接展示；工具栏刷新按钮可强制绕过缓存 |
| 多线程下载 | 并发数可配置（默认 4），实时进度条，支持**取消单个任务**，可清除已完成 / 已取消任务 |
| 正则批量下载 | 输入正则匹配文件名，预览命中数量后一键批量下载，确认后自动关闭弹框 |
| 右键菜单 | 复制名称 / 复制路径 / 下载选中（多选时批量） |
| 上传控制 | 生产环境永久禁止上传；非生产环境通过工具栏开关控制 |
| 操作日志 | 内存 + 文件双重记录，可按 DEBUG / INFO / WARNING / ERROR 级别过滤、清空 |
| 错误引导 | 弹窗显示原因 + 解决建议，支持直接打开日志文件 |
| 跟随系统主题 | 深色 / 浅色模式自动适配 |

---

## 系统要求

| 项目 | 要求 |
|------|------|
| macOS | 14 Sonoma 及以上（推荐 15+） |
| Swift | 5.9+ |
| Xcode | 15+（仅开发打包需要） |

---

## 快速开始

### 1. 配置 Profile 文件

S3 Tools 使用专属配置文件 **`~/.aws/s3tools`**（INI 格式），每个 section 对应一个 Profile：

```ini
[default]
region = ap-southeast-1          # 全局默认 Region，可被各 section 覆盖

[minio-dev]
aws_access_key_id     = minioadmin
aws_secret_access_key = minioadmin
endpoint              = http://minio.internal:9000
path_style            = true
region                = us-east-1
default_bucket        = my-dev-bucket   # 切换到该 Profile 时自动选中此 Bucket

[production]
aws_access_key_id     = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
region                = ap-southeast-1
is_production         = true            # 显式声明生产环境，禁止上传
default_bucket        = prod-data
```

**各字段说明：**

| 字段 | 是否必填 | 说明 |
|------|---------|------|
| `aws_access_key_id` | ✓ | Access Key ID |
| `aws_secret_access_key` | ✓ | Secret Access Key |
| `aws_session_token` | | 临时凭证 STS Token |
| `region` | | 默认 `ap-southeast-1` |
| `endpoint` | | 自定义 Endpoint，AWS 标准留空 |
| `path_style` | | MinIO / LocalStack 设为 `true` |
| `is_production` | | `true` / `false`；省略时按 Profile 名称自动检测 |
| `default_bucket` | | 切换到该 Profile 时自动选中的 Bucket |

> **生产环境自动检测**：Profile 名称中含有 `prod`、`production`、`live`、`online`、`prd`（不区分大小写）时，自动视为生产环境。

---

### 2. 构建与运行

```bash
# 克隆项目
git clone <your-repo> && cd S3Tools

# Debug 构建后直接启动（推荐开发时使用）
./build.sh run

# 仅 Debug 构建
./build.sh

# Release 构建 → 生成 dist/S3Tools.app
./build.sh release

# Release 构建 + 打包 .dmg
./build.sh package

# 清理所有构建产物
./build.sh clean
```

> 首次运行会下载 `aws-sdk-swift` 依赖，约需数分钟，请耐心等待。

**绕过 Gatekeeper（未签名 app）：**

```bash
xattr -cr dist/S3Tools.app
open dist/S3Tools.app
```

---

## 界面说明

```
┌──────────────────────────────────────────────────────────────────────────┐
│  [minio-dev ▾]  ● 已连接          [↑ 上传]  [↺ 刷新]  [⚙ 设置]        │  ← 工具栏
├─────────────────┬────────────────────────────────────────────────────────┤
│  Buckets    [🔍]│  📁 路径输入框（Tab 补全）  [跳转] [🔖]  |  🔍 前缀过滤 [✕]  | [↓N] [⊙]  │
│  ─────────────  │  bucket-name / folder / subfolder /                    │  ← 面包屑
│  ★ my-bucket  ← │────────────────────────────────────────────────────────│
│  archive        │  图标  名称 ↑↓        大小 ↑↓   修改时间 ↑↓   操作    │  ← 表头
│  data           │  📁   2026/           —         2026-01-01    →        │
│                 │  📄   report_01.csv   128 KB    2026-01-15    ↓        │
│                 │  ...                                                    │
│                 │  [全选] [取消选]  第 1 页  共 N 个对象  [加载更多]     │  ← 分页栏
├─────────────────┴────────────────────────────────────────────────────────┤
│  ↓ 下载队列  ·  2 个下载中 · 1 个完成                     [清除完成] [∨] │  ← 可折叠
├──────────────────────────────────────────────────────────────────────────┤
│  📋 操作日志  [全部 ▾]  [打开日志文件]  [清空]                      [∨] │  ← 可折叠
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 使用手册

### 浏览文件

1. 启动后自动加载 `~/.aws/s3tools` 中所有 Profile，工具栏下拉菜单切换
2. 切换 Profile 后自动连接；若配置了 `default_bucket` 则自动进入对应 Bucket
3. 左侧 **Buckets** 栏显示所有 Bucket，当前选中的 Bucket 行前显示 ★；顶部搜索框可快速筛选
4. 文件列表单击进入目录，多选支持 ⇧ 连续选、⌘ 单选
5. 点击**表头**（名称 / 大小 / 修改时间）切换排序方向，默认修改时间降序
6. 面包屑可直接点击跳回任意层级

### 路径跳转

- **手动输入**：在路径框输入前缀，输入过程中自动补全**目录**（后缀 `/` 的条目）；  
  输入的前缀若匹配到文件名时，自动填入完整路径（QuickJump）；回车或点击「跳转」执行
- **书签**：点击路径框旁书签图标（🔖），选择任意预定义或自定义路径一键跳转
  - 「添加书签」将当前路径保存，弹出对话框可编辑名称和路径，新书签置顶
  - 「管理书签」可增删改排序，支持拖拽，一键「恢复默认」重载内置 80+ 路径

### 过滤文件

在**前缀过滤**框输入字符串，系统会以 `currentPrefix + 输入值` 作为 S3 `prefix` 参数重新请求，400ms 防抖。点击输入框右侧 ✕ 清除过滤，恢复原始分页浏览。导航（点击目录、面包屑、跳转）时自动清除过滤词。

### 下载文件

| 方式 | 操作 |
|------|------|
| 单文件 | 点击行末「↓」按钮 |
| 多文件 | 勾选后点击操作栏「↓ N」按钮 |
| 正则批量 | 点击「⊙」按钮，输入正则预览命中数，确认后批量加入队列，弹框自动关闭 |
| 右键菜单 | 选中后右键 → 「下载选中 (N 个)」 |
| 键盘 | 选中后按 ⌘D |

下载目录默认为 `~/Downloads`，可在**设置 → 下载**中修改。

每个任务在下载中或等待时可点击 ✕ 取消；已完成和已取消的任务均可通过「清除完成」批量移除。

### 右键菜单

在文件列表中右键单击（或选中多项后右键）：

| 菜单项 | 说明 |
|--------|------|
| 下载选中 (N 个) | 将选中文件加入下载队列 |
| 复制名称 | 仅复制文件名（不含路径），多选时每行一个 |
| 复制路径 | 复制完整 S3 Key，多选时每行一个 |

### 上传文件（非生产环境专用）

1. 确保当前 Profile 不是生产环境
2. 点击工具栏**上传开关**图标（橙色 `↑`）启用上传
3. 点击操作栏**上传图标**，选择文件，文件将上传至当前路径

> 生产环境永久禁止上传，开关不可见。

### 日志查看

- 日志面板可折叠，支持按 DEBUG / INFO / WARNING / ERROR 过滤
- 日志文件路径：`~/Library/Logs/S3Tools/s3tools-YYYY-MM-DD.log`
- 点击「打开日志文件」直接在 Finder 中定位

---

## 设置面板（⌘,）

| 标签页 | 内容 |
|--------|------|
| **Profiles** | 只读展示 `~/.aws/s3tools` 的解析结果，验证各字段是否正确读取，并附配置格式示例 |
| **下载** | 下载目录、最大并发数（1–16）、每页条目数 |
| **关于** | 版本信息 |

> Profile 配置仅通过编辑 `~/.aws/s3tools` 文件修改，无需重启，切换 Profile 时自动重新解析。

---

## 架构设计

### 整体架构

```
┌─────────────────────────────────────────────────────┐
│                     SwiftUI Views                    │
│  MainView → NavigationSplitView                     │
│    ├── BucketSidebarView                            │
│    ├── PathInputView  (路径 / 书签 / 过滤)           │
│    ├── FileListView   (Table + 排序 + 右键菜单)      │
│    ├── DownloadProgressView                         │
│    └── LogPanelView                                 │
└──────────────────┬──────────────────────────────────┘
                   │ @EnvironmentObject
┌──────────────────▼──────────────────────────────────┐
│                    @MainActor AppState               │
│  • availableProfiles / selectedProfile              │
│  • connectionStatus / isUploadEnabled               │
│  • buckets / selectedBucket / currentPrefix         │
│  • objects / selectedObjects                        │
│  • filterPattern (→ scheduleFilterLoad 400ms)       │
│  • downloadTasks / downloadHandles                  │
│  • logEntries                                       │
│  • objectCache (5 min TTL, key = bucket\0prefix)    │
│  • appSettings (UserDefaults 持久化)                │
└──────────┬──────────────────┬────────────────────────┘
           │                  │
┌──────────▼──────┐  ┌────────▼───────────────┐
│   S3Service     │  │    DownloadManager      │
│ • listBuckets   │  │ • actor，信号量限流      │
│ • listObjects   │  │ • executeSingle()       │
│ • downloadObject│  │ • 每任务独立 Task，      │
│ • uploadObject  │  │   支持 cancel()         │
│ • region 重定向  │  └─────────────────────────┘
│   (自动探测 +   │
│    regionalCache)│  ┌────────────────────────┐
└─────────────────┘  │  PathCompletionService  │
                     │ • 前缀查询               │
                     │ • 本地缓存 + 防抖        │
                     └────────────────────────┘
```

### 核心模块说明

#### AppState（`AppState.swift`）

全局状态中心，标注 `@MainActor` 确保 UI 更新在主线程执行。

- **Profile 切换** `switchProfile(to:)`：重置所有导航状态 + 清空对象缓存，重新初始化 `S3Service`；若 `defaultBucket` 非空且在 Bucket 列表中则自动选桶
- **对象缓存** `objectCache`：key = `"bucket\0prefix"`，TTL 5 分钟；`forceRefresh: true` 时绕过缓存
- **前缀过滤** `filterPattern`：写入时触发 `scheduleFilterLoad()`，400ms 防抖后以 `currentPrefix + filterPattern` 作为 S3 prefix 重新请求；导航时调用 `clearFilterSilently()` 静默重置
- **下载调度** `enqueueDownloads()` → 每个任务独立创建 `Task<Void,Never>` 存入 `downloadHandles`；`cancelDownload(id:)` 取消对应 Task 并立即更新状态为 `.cancelled`

#### S3Service（`Services/S3Service.swift`）

封装所有 AWS S3 API 调用。

- **跨区域重定向**：`listObjects` / `downloadObject` 失败时自动调用 `getBucketRegion()` 探测真实 Region，写入 `bucketRegionCache`，用对应 `regionalClient` 重试
- **Regional Client 池**：`regionalClients: [String: S3Client]`，避免重复初始化

#### DownloadManager（`Services/DownloadManager.swift`）

Swift `actor`，基于信号量（`CheckedContinuation` 等待队列）实现并发限流。

- `executeSingle(task:service:onTaskUpdated:)`：等待空闲槽 → 执行下载 → 释放槽
- 通过 Swift 结构化并发的 `Task.isCancelled` / `CancellationError` 实现中途取消，状态变为 `.cancelled`

#### AppSettings（`Config/AppSettings.swift`）

所有用户偏好通过 `@Published` 属性的 `didSet` 即时持久化到 `UserDefaults`。

| 键 | 类型 | 说明 |
|---|---|---|
| `pageSize` | Int | 每页条目数，默认 200 |
| `maxConcurrentDownloads` | Int | 最大并发下载数，默认 4 |
| `downloadDirectory` | String | 下载目标目录 |
| `bookmarks` | `[BookmarkEntry]` | 用户书签列表 |
| `logLevel` | LogLevel | 最低记录级别 |

#### CredentialsManager（`Config/CredentialsManager.swift`）

解析 `~/.aws/s3tools`（INI 格式），使用 `INIParser` 将每个 non-default section 转换为 `ProfileConfig`。`[default]` section 提供全局默认 Region。

### 目录结构

```
S3Tools/
├── build.sh                          # 构建脚本（debug / run / release / package / clean）
├── ExportOptions.plist               # xcodebuild 导出配置
├── Package.swift                     # SPM 依赖声明
└── Sources/S3Tools/
    ├── S3ToolsApp.swift              # @main 入口，Scene 配置，全局快捷键
    ├── AppState.swift                # 全局状态（@MainActor ObservableObject）
    ├── Config/
    │   ├── AppSettings.swift         # 用户偏好设置（UserDefaults 持久化）
    │   └── CredentialsManager.swift  # 解析 ~/.aws/s3tools
    ├── Models/
    │   ├── S3Environment.swift       # ProfileConfig 结构体（含生产判断逻辑）
    │   ├── S3Object.swift            # S3 对象模型，含排序辅助属性
    │   ├── BookmarkEntry.swift       # 用户书签模型，内含 80+ 预定义路径
    │   ├── DownloadTask.swift        # 下载任务状态机（pending/inProgress/completed/failed/cancelled）
    │   ├── LogEntry.swift            # 日志条目模型
    │   └── QuickJumpEntry.swift      # 预定义路径字典（供 BookmarkEntry.defaults 引用）
    ├── Services/
    │   ├── S3Service.swift           # S3 API 封装（含跨区域重定向、Regional Client 池）
    │   ├── DownloadManager.swift     # 并发下载调度（actor + 信号量 + 可取消 Task）
    │   └── PathCompletionService.swift # 路径前缀自动补全（防抖 + 缓存）
    ├── Views/
    │   ├── MainView.swift            # NavigationSplitView 根布局 + alert + 通知监听
    │   ├── ToolbarView.swift         # 工具栏（Profile 选择 / 状态点 / 上传开关 / 刷新 / 设置）
    │   ├── BucketSidebarView.swift   # Bucket 侧边栏（含搜索框、当前 Bucket ★ 高亮）
    │   ├── FileListView.swift        # 文件列表（Table + 可点击排序 + 右键菜单 + 分页栏）
    │   ├── PathInputView.swift       # 路径输入 / 书签菜单 / 前缀过滤 / 操作按钮 / 面包屑
    │   ├── DownloadProgressView.swift# 下载队列面板（可折叠，含取消按钮）
    │   ├── LogPanelView.swift        # 操作日志面板（可折叠，含过滤器）
    │   └── SettingsView.swift        # 设置面板（Profiles 预览 / 下载 / 关于）
    └── Utilities/
        ├── AppLogger.swift           # 日志记录器（内存 + 文件双写）
        └── INIParser.swift           # INI 格式解析工具
```

### 数据流

```
用户操作 (View)
    │
    ▼
AppState.loadObjects(bucket:prefix:forceRefresh:)
    │
    ├─ 命中缓存? ──Yes──► 直接展示 objects
    │
    └─ No
        │
        ▼
    S3Service.listObjects()
        │
        ├─ 成功 ──► 写入 objectCache ──► 更新 objects
        │
        └─ 失败 (region 错误)
            │
            ▼
        getBucketRegion(bucket) ──► 写入 bucketRegionCache
            │
            ▼
        regionalClient(for: region) ──► 重试 ──► 成功
```

---

## 键盘快捷键

| 快捷键 | 功能 |
|--------|------|
| ⌘R | 强制刷新（忽略缓存） |
| ⌘D | 下载选中文件 |
| ⌘, | 打开设置 |
| Return（路径框） | 跳转到当前路径 |
| Esc | 关闭弹窗 |

---

## 常见问题

| 现象 | 可能原因 | 解决方案 |
|------|----------|---------|
| 工具栏 Profile 列表为空 | `~/.aws/s3tools` 不存在或格式错误 | 参照上方格式创建文件，确保 `aws_access_key_id` 和 `aws_secret_access_key` 不为空 |
| 列出 Bucket 失败 / 认证错误 | AK/SK 错误或过期 | 更新 `~/.aws/s3tools`，工具栏重新切换 Profile |
| 打开 Bucket 报区域错误 | Bucket 所在 Region 与配置不符 | 应用会自动重定向；若仍失败请在 `~/.aws/s3tools` 中手动填写正确 `region` |
| 下载失败 UnknownAWSHTTPServiceError | 同上，download 用了错误 Region | 先成功打开一次该 Bucket（触发 Region 缓存），再下载 |
| 文件列表为空 | 前缀不匹配或目录为空 | 检查路径，清空过滤条件 |
| 上传按钮不显示 | 生产环境或未开启上传开关 | 切换到非生产 Profile，点击工具栏橙色上传图标开启 |
| 自动补全没有结果 | 网络慢或输入的前缀不存在 | 确认路径正确，等待防抖延迟（300ms） |
| App 无法打开（Gatekeeper 阻止） | 未签名 | `xattr -cr dist/S3Tools.app && open dist/S3Tools.app` |

---

## 日志文件

```
~/Library/Logs/S3Tools/s3tools-YYYY-MM-DD.log
```

日志格式：
```
[2026-01-15 14:30:01] [INFO]  [minio-dev] 列出对象 → s3://my-bucket/data/2026/ 共 128 个
[2026-01-15 14:30:05] [INFO]  [minio-dev] 下载完成 → data/2026/report.csv
[2026-01-15 14:31:00] [ERROR] [minio-dev] 列出对象失败: ...
```


---

## 功能特性

| 功能 | 说明 |
|------|------|
| 多环境切换 | Offline / Production 工具栏一键切换，切换时自动清空缓存 |
| 安全凭证管理 | 优先读取环境变量，其次 `~/.aws/credentials`，再次 `~/.aws/config` |
| 自动跨区域重定向 | 探测 bucket 真实 region，自动使用正确的 regional client 重试（listObjects / download） |
| 浏览与导航 | 侧边栏 bucket 列表（含搜索过滤）+ 文件列表双击进入目录 + 面包屑导航 |
| 路径输入与补全 | 历史输入同步、Tab 自动补全目录（仅显示文件夹），防抖 + 本地缓存 |
| 书签管理 | 内置 80+ 预定义路径，支持增删改排序，一键恢复默认，持久化存储 |
| 文件列表排序 | 默认按修改时间降序，点击表头切换 名称 / 大小 / 时间 三列排序 |
| 正则过滤（全量） | 输入正则后自动扫描当前 prefix 的全部分页数据再过滤，非仅当前页 |
| 分页加载 | 每页条目数可配置（默认 200），支持「加载更多」增量追加 |
| 缓存机制 | 首页结果缓存 5 分钟，命中缓存直接展示；工具栏刷新按钮可强制绕过缓存 |
| 多线程下载 | 并发数可配置（默认 4），实时进度条，可清除已完成任务 |
| 正则批量下载 | 输入正则匹配文件名，预览命中数量后一键批量下载 |
| 上传控制 | Production 永久禁止上传；Offline 通过工具栏开关控制 |
| 操作日志 | 内存 + 文件双重记录，可按 DEBUG / INFO / WARNING / ERROR 级别过滤、清空 |
| 错误引导 | 弹窗显示原因 + 解决建议，支持直接打开日志文件 |
| 跟随系统主题 | 深色 / 浅色模式自动适配 |

---

## 系统要求

| 项目 | 要求 |
|------|------|
| macOS | 14 Sonoma 及以上（推荐 15+） |
| Swift | 5.9+ |
| Xcode | 15+（仅开发打包需要） |

---

## 快速开始

### 1. 配置 AWS 凭证

**推荐：`~/.aws/credentials` 文件**

```ini
[offline]
aws_access_key_id     = YOUR_OFFLINE_AK
aws_secret_access_key = YOUR_OFFLINE_SK

[production]
aws_access_key_id     = YOUR_PROD_AK
aws_secret_access_key = YOUR_PROD_SK
```

**备选：环境变量**

```bash
export AWS_ACCESS_KEY_ID=YOUR_AK
export AWS_SECRET_ACCESS_KEY=YOUR_SK
export AWS_SESSION_TOKEN=YOUR_TOKEN   # 临时凭证时填写
```

凭证读取优先级：**环境变量 › `~/.aws/credentials` › `~/.aws/config`**

> 凭证轮换后只需更新文件或环境变量，在工具栏重新切换一次环境即可刷新，无需重启。

---

### 2. 配置 Endpoint（Offline / 自建 S3 环境）

打开 **设置（⌘,）→ 环境配置**，按需填写：

| 字段 | 说明 | 示例 |
|------|------|------|
| Endpoint | 自定义 endpoint，AWS 标准环境留空 | `http://minio.internal:9000` |
| Region | 所在区域，留空默认 `us-east-1` | `ap-southeast-1` |
| Profile | `~/.aws/credentials` 中的 section 名称 | `offline` / `production` |
| Path Style | MinIO / LocalStack 必须开启 | ✓ |

---

### 3. 构建与运行

```bash
# 克隆项目
git clone <your-repo> && cd S3Tools

# Debug 构建后直接启动（推荐开发时使用）
./build.sh run

# 仅 Debug 构建
./build.sh

# Release 构建 → 生成 dist/S3Tools.app
./build.sh release

# Release 构建 + 打包 .dmg
./build.sh package

# 清理所有构建产物
./build.sh clean
```

> 首次运行会下载 `aws-sdk-swift` 依赖，约需数分钟，请耐心等待。

**绕过 Gatekeeper（未签名 app）：**

```bash
xattr -cr dist/S3Tools.app
open dist/S3Tools.app
```

---

## 界面说明

```
┌──────────────────────────────────────────────────────────────────────────┐
│  [offline ▾]  ● 已连接          [↑ upload]  [↺ 刷新]  [⚙ 设置]         │  ← 工具栏
├─────────────────┬────────────────────────────────────────────────────────┤
│  Buckets    [🔍]│  📁 路径输入框（Tab 补全）  [跳转]  [🔖]  |  🔍 正则过滤  [✕]  |  [↓N]  [⊙]  │  ← 操作栏
│  ─────────────  │  bucket-name / folder / subfolder /                    │  ← 面包屑
│  my-bucket   ← │────────────────────────────────────────────────────────│
│  archive        │  图标  名称 ↑↓        大小 ↑↓   修改时间 ↑↓   操作    │  ← 表头（可点击排序）
│  data           │  📁   2026/           —         2026-01-01    →        │
│                 │  📄   report_01.csv   128 KB    2026-01-15    ↓        │
│                 │  ...                                                    │
│                 │  [全选] [取消选]  第 1 页  共 N 个对象  [加载更多]     │  ← 分页栏
├─────────────────┴────────────────────────────────────────────────────────┤
│  ↓ 下载队列  ·  2 个下载中 · 1 个完成                     [清除完成] [∨] │  ← 可折叠
├──────────────────────────────────────────────────────────────────────────┤
│  📋 操作日志  [全部 ▾]  [打开日志文件]  [清空]                      [∨] │  ← 可折叠
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 使用手册

### 浏览文件

1. 启动后自动连接到上次使用的环境（首次为 Offline）
2. 左侧 **Buckets** 栏显示所有 bucket，点击 bucket 进入；顶部搜索框可快速筛选
3. 文件列表双击目录进入，单击文件/目录行可**多选**（⇧ 连续选，⌘ 单选）
4. 点击**表头**（名称 / 大小 / 修改时间）切换排序方向，默认修改时间降序
5. 面包屑可直接点击跳回任意层级

### 路径跳转

- **手动输入**：在路径框输入前缀，输入过程中自动补全**目录**（后缀 `/` 的条目），回车或点击「跳转」
- **书签**：点击路径框旁书签图标（🔖），选择任意预定义或自定义路径一键跳转
  - 「添加书签」将当前路径保存；「管理书签」可增删改排序

### 过滤文件

在**正则过滤**框输入正则表达式（如 `.*2025.*\.log$`），系统会：
1. 自动扫描当前 prefix 的**全部分页**数据（不仅当前页）
2. 对所有结果执行正则匹配并实时展示
3. 点击输入框右侧 ✕ 清除过滤，恢复分页浏览

> 过滤期间状态栏显示「全量扫描中...」，扫描完成后显示命中数量。

### 下载文件

| 方式 | 操作 |
|------|------|
| 单文件 | 点击行末「↓」按钮 |
| 多文件 | 勾选后点击操作栏「↓ N」按钮 |
| 正则批量 | 点击「⊙」按钮，输入正则预览命中数，确认后批量加入队列 |
| 键盘 | 选中后按 ⌘D |

下载目录默认为 `~/Downloads`，可在**设置 → 下载目录**中修改。

### 上传文件（Offline 专用）

1. 确保当前环境为 **Offline**
2. 点击工具栏**上传开关**图标（橙色 `↑`）启用上传
3. 点击操作栏**上传图标**，选择文件，文件将上传至当前路径

> Production 环境永久禁止上传，开关不可见。

### 书签管理

- **快速添加**：进入目标目录后，点击 🔖 → 「添加书签: xxx」
- **手动添加**：🔖 → 「管理书签...」→ 底部「添加书签」，填写名称和路径
- **编辑**：管理书签窗口中直接修改名称和路径字段
- **拖拽排序**：在管理书签列表中拖动调整顺序
- **恢复默认**：管理书签窗口右下角「恢复默认」，重载内置 80+ 预定义路径

### 日志查看

- 日志面板可折叠，支持按 DEBUG / INFO / WARNING / ERROR 过滤
- 日志文件路径：`~/Library/Logs/S3Tools/s3tools-YYYY-MM-DD.log`
- 点击「打开日志文件」直接在 Finder 中定位

---

## 架构设计

### 整体架构

```
┌─────────────────────────────────────────────────────┐
│                     SwiftUI Views                    │
│  MainView → NavigationSplitView                     │
│    ├── BucketSidebarView                            │
│    ├── PathInputView  (路径 / 书签 / 过滤)           │
│    ├── FileListView   (Table + 排序)                 │
│    ├── DownloadProgressView                         │
│    └── LogPanelView                                 │
└──────────────────┬──────────────────────────────────┘
                   │ @EnvironmentObject
┌──────────────────▼──────────────────────────────────┐
│                    @MainActor AppState               │
│  • currentEnvironment / connectionStatus            │
│  • buckets / selectedBucket / currentPrefix         │
│  • objects / filteredObjects / selectedObjects      │
│  • downloadTasks / logEntries                       │
│  • objectCache (5 min TTL, key = bucket\0prefix)    │
│  • appSettings (UserDefaults 持久化)                │
└──────────┬──────────────────┬────────────────────────┘
           │                  │
┌──────────▼──────┐  ┌────────▼───────────┐
│   S3Service     │  │  DownloadManager   │
│ • listBuckets   │  │ • 并发队列          │
│ • listObjects   │  │ • 进度回调          │
│ • downloadObject│  └────────────────────┘
│ • uploadObject  │
│ • region 重定向  │  ┌────────────────────┐
│   (自动探测 +   │  │ PathCompletionSvc  │
│    regionalCache)│  │ • 前缀查询          │
└─────────────────┘  │ • 本地缓存 + 防抖   │
                     └────────────────────┘
```

### 核心模块说明

#### AppState（`AppState.swift`）

全局状态中心，标注 `@MainActor` 确保 UI 更新在主线程执行。

- **环境切换** `switchEnvironment(to:)`：重置所有导航状态 + 清空对象缓存，重新初始化 `S3Service`
- **对象缓存** `objectCache`：key = `"bucket\0prefix"`，TTL 5 分钟；`forceRefresh: true` 时绕过缓存
- **全量过滤** `loadAllObjectsForFilter()`：正则非空时循环拉取所有分页，完成后执行过滤
- **下载调度** `enqueueDownloads()` → `DownloadManager.startDownloads()`

#### S3Service（`Services/S3Service.swift`）

封装所有 AWS S3 API 调用。

- **跨区域重定向**：`listObjects` / `downloadObject` 失败时自动调用 `getBucketRegion()` 探测真实 region，写入 `bucketRegionCache`，用对应 `regionalClient` 重试
- **Regional Client 池**：`regionalClients: [String: S3Client]`，避免重复初始化
- **Completion 专用接口** `listForCompletion()`：只返回目录前缀（`commonPrefixes`），不含文件

#### AppSettings（`Config/AppSettings.swift`）

所有用户偏好通过 `@Published` 属性的 `didSet` 即时持久化到 `UserDefaults`。

| 键 | 类型 | 说明 |
|---|---|---|
| `pageSize` | Int | 每页条目数，默认 200 |
| `maxConcurrentDownloads` | Int | 最大并发下载数，默认 4 |
| `downloadDirectory` | String | 下载目标目录 |
| `environmentConfigs` | `[S3Environment: EnvironmentConfig]` | 各环境 endpoint/region/profile |
| `bookmarks` | `[BookmarkEntry]` | 用户书签列表 |
| `logLevel` | LogLevel | 最低记录级别 |

#### 凭证管理（`Config/CredentialsManager.swift`）

按优先级查找凭证：环境变量 → `~/.aws/credentials` → `~/.aws/config`，使用 `INIParser` 解析 INI 格式文件，支持 `[default]` 回退。

### 目录结构

```
S3Tools/
├── build.sh                          # 构建脚本（debug / run / release / package / clean）
├── ExportOptions.plist               # xcodebuild 导出配置
├── Package.swift                     # SPM 依赖声明
└── Sources/S3Tools/
    ├── S3ToolsApp.swift              # @main 入口，Scene 配置，全局快捷键
    ├── AppState.swift                # 全局状态（@MainActor ObservableObject）
    ├── Config/
    │   ├── AppSettings.swift         # 用户偏好设置（UserDefaults 持久化）
    │   └── CredentialsManager.swift  # 凭证加载（环境变量 / credentials / config）
    ├── Models/
    │   ├── S3Environment.swift       # 环境枚举 + EnvironmentConfig
    │   ├── S3Object.swift            # S3 对象模型，含排序辅助属性
    │   ├── BookmarkEntry.swift       # 用户书签模型，内含 80+ 预定义路径
    │   ├── DownloadTask.swift        # 下载任务状态机
    │   ├── LogEntry.swift            # 日志条目模型
    │   └── QuickJumpEntry.swift      # 预定义路径字典（供 BookmarkEntry.defaults 引用）
    ├── Services/
    │   ├── S3Service.swift           # S3 API 封装（含跨区域重定向、regional client 池）
    │   ├── DownloadManager.swift     # 并发下载调度器
    │   └── PathCompletionService.swift # 路径前缀自动补全（防抖 + 缓存）
    ├── Views/
    │   ├── MainView.swift            # NavigationSplitView 根布局 + alert + 通知监听
    │   ├── ToolbarView.swift         # 工具栏（环境选择 / 状态点 / 上传开关 / 刷新 / 设置）
    │   ├── BucketSidebarView.swift   # Bucket 侧边栏（含搜索框）
    │   ├── FileListView.swift        # 文件列表（Table + 可点击排序 + 分页栏）
    │   ├── PathInputView.swift       # 路径输入 / 书签菜单 / 正则过滤 / 操作按钮 / 面包屑
    │   ├── DownloadProgressView.swift# 下载队列面板（可折叠）
    │   ├── LogPanelView.swift        # 操作日志面板（可折叠，含过滤器）
    │   └── SettingsView.swift        # 设置面板（分页/下载/环境配置/日志）
    └── Utilities/
        ├── AppLogger.swift           # 日志记录器（内存 + 文件双写）
        └── INIParser.swift           # INI 格式解析工具
```

### 数据流

```
用户操作 (View)
    │
    ▼
AppState.loadObjects(bucket:prefix:forceRefresh:)
    │
    ├─ 命中缓存? ──Yes──► 直接展示 filteredObjects
    │
    └─ No
        │
        ▼
    S3Service.listObjects()
        │
        ├─ 成功 ──► 写入 objectCache ──► applyFilter()
        │
        └─ 失败 (region 错误)
            │
            ▼
        getBucketRegion(bucket) ──► 写入 bucketRegionCache
            │
            ▼
        regionalClient(for: region) ──► 重试 ──► 成功
```

---

## 键盘快捷键

| 快捷键 | 功能 |
|--------|------|
| ⌘R | 强制刷新（忽略缓存） |
| ⌘D | 下载选中文件 |
| ⌘, | 打开设置 |
| Return（路径框） | 跳转到当前路径 |
| Esc | 关闭弹窗 |

---

## 常见问题

| 现象 | 可能原因 | 解决方案 |
|------|----------|---------|
| 列出 bucket 失败 / 认证错误 | AK/SK 错误或过期 | 更新 `~/.aws/credentials`，工具栏重新切换环境 |
| 打开 bucket 报 UnknownAWSHTTPServiceError | Bucket 所在 region 与配置不符 | 应用会自动重定向，若仍失败请在设置中手动填写正确 region |
| 下载失败 UnknownAWSHTTPServiceError | 同上，download 使用了错误 region | 先成功打开一次该 bucket（触发 region 缓存），再下载 |
| 文件列表为空 | Prefix 不匹配或目录真的为空 | 检查路径，清空过滤条件 |
| 上传按钮不显示 | 非 Offline 环境或未开启上传开关 | 切换到 Offline，点击工具栏橙色上传图标开启 |
| 自动补全没有结果 | 网络慢或输入的 prefix 不存在 | 确认路径正确，等待防抖延迟（300ms） |
| App 无法打开（Gatekeeper 阻止） | 未签名 | `xattr -cr dist/S3Tools.app && open dist/S3Tools.app` |

---

## 日志文件

```
~/Library/Logs/S3Tools/s3tools-YYYY-MM-DD.log
```

日志格式：
```
[2026-01-15 14:30:01] [INFO]  [Production] 列出对象 → s3://my-bucket/data/2026/ 共 128 个
[2026-01-15 14:30:05] [INFO]  [Production] 下载完成 → data/2026/report.csv
[2026-01-15 14:31:00] [ERROR] [Production] 列出对象失败: ...
```
