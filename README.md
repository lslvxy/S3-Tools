# S3 Rust

一个跨平台的 S3 图形化工具，用 **Rust + Tauri v2** 构建。功能对标原 Swift 版
(S3Tools)，支持多环境、跨区域重定向、批量下载、路径自动补全、书签与日志。

## 功能

- **多环境 (Profile)**：读取 `~/.aws/s3tools`，支持无限个环境，每个环境可独立配置
  region、endpoint、path-style、default_bucket。
- **跨区域重定向**：桶位于非默认 region 时自动探测并切换客户端（支持路径重定向，
  含上传场景）。
- **浏览 / 搜索**：目录式浏览、前缀过滤（400ms 防抖）、面包屑导航、排序、分页加载。
- **批量下载**：并发下载（Semaphore 限流）、可取消、实时进度、完成后在 Finder 中显示。
- **正则下载**：按正则匹配当前目录下的文件名并批量下载。
- **上传**：多文件上传；生产环境自动禁用。
- **书签**：默认书签来自本地文件 `src-tauri/resources/default_bookmarks.json`（含日期变量
  `{YMD}`、`{YM}`、`{D}` 等），该文件已加入 `.gitignore`、仅在本地打包时随应用捆绑，
  缺失时默认书签为空；支持自定义、拖拽排序、一键重置为默认。
- **路径自动补全**：前缀感知的 Bucket/Key 补全，带 TTL 缓存。
- **日志**：内存（最新 1000 条）+ 文件落盘，可按级别筛选。
- **生产保护**：名称含 `prod` / `production` / `live` / `online` / `prd` 自动标记为
  生产环境并禁止上传（可用 `is_production = false` 强制覆盖）。

## 目录结构

```
S3Rust/
├── .gitignore                 # 忽略 resources/default_bookmarks.json
├── src/                    # 前端（vanilla JS，零构建）
│   ├── index.html
│   ├── styles.css
│   └── main.js
└── src-tauri/              # 后端（Rust）
    ├── Cargo.toml
    ├── tauri.conf.json
    ├── capabilities/default.json
    ├── resources/
    │   └── default_bookmarks.json   # 本地默认书签（git 忽略，打包时捆绑）
    └── src/
        ├── main.rs         # 入口
        ├── lib.rs          # Builder 装配、插件、命令注册
        ├── commands.rs     # 全部 Tauri 命令与 AppState
        ├── config.rs       # INI 解析、Profile、生产判定、默认书签
        ├── s3.rs           # S3Service（list/upload/download/head、region 重定向）
        ├── download.rs     # DownloadManager（并发、取消、进度事件）
        ├── settings.rs     # 设置持久化与书签版本迁移
        └── logger.rs       # 日志（内存 + 文件）
```

## 配置文件 `~/.aws/s3tools`

INI 格式，与 AWS CLI 风格一致：

```ini
[default]
region = ap-southeast-1          ; 全局默认 region（可省略）

[my-offline]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
endpoint = http://minio:9000     ; MinIO/LocalStack 自定义地址；留空=AWS 标准
region = us-east-1               ; 留空则继承 [default]
path_style = true                ; MinIO 需要开启；AWS S3 无需
default_bucket = my-data-bucket  ; 启动自动连接的 Bucket（可省略）
```

`[default]` 段的 `region` 作为未指定 region 的环境的兜底值。

生产环境自动判断：Profile 名称含 `prod` / `production` / `live` / `online` / `prd`
即标记为生产。可用 `is_production = false` 强制覆盖为非生产。

## 构建

前置：Rust (cargo) 1.97+、macOS（需 Command Line Tools 或 Xcode）。

```bash
# 开发运行（debug，含实时前端资源）
cd src-tauri
cargo run

# 发布打包（.app + .dmg）
cargo tauri build
```

> 前端无构建步骤：`tauri.conf.json` 设置 `app.withGlobalTauri = true`，
> `build.frontendDist = "../src"`，运行时直接内嵌静态资源，无需 npm。

## 常见问题

- **AWS SDK 重定向错误**：若桶的 region 与默认不一致，工具会自动探测并重试，无需
  手动配置。
- **生产环境上传按钮置灰**：确认 Profile 名称不含生产关键词，或在配置中显式设置
  `is_production = false`。
- **日志位置**：`~/Library/Application Support/com.s3rust.app/logs/`。

## 原 Swift 版

修复跨区域上传错误后的 Swift 版源码见同级目录 `S3Tools`
（`Sources/S3Tools/Services/S3Service.swift`）。