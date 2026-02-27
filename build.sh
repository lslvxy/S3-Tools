#!/bin/bash
# =============================================================================
# S3Tools Build & Package Script
# 用法:
#   ./build.sh              # Debug 构建
#   ./build.sh run          # Debug 构建后直接启动
#   ./build.sh release      # Release 构建
#   ./build.sh package      # Release 构建 + 打包 .app + 生成 .dmg
#   ./build.sh clean        # 清理构建产物
# =============================================================================

set -euo pipefail

# ─── 配置 ────────────────────────────────────────────────────────────────────
APP_NAME="S3Tools"
SCHEME="S3Tools"
BUNDLE_ID="com.s3tools.app"
MIN_MACOS="14.0"
BUILD_DIR="$(pwd)/.build"
DIST_DIR="$(pwd)/dist"
ARCHIVE_PATH="$DIST_DIR/$APP_NAME.xcarchive"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
EXPORT_PLIST="$(pwd)/ExportOptions.plist"

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── 检查工具 ─────────────────────────────────────────────────────────────────
check_deps() {
    info "检查依赖工具..."

    if ! command -v xcodebuild &>/dev/null; then
        error "未找到 xcodebuild。请安装 Xcode Command Line Tools: xcode-select --install"
    fi

    # 用 || true 防止 head -1 截断管道时 pipefail 误报非零退出码
    local xcode_version
    xcode_version=$(xcodebuild -version 2>/dev/null | head -1 || true)
    info "  ${xcode_version:-xcodebuild (version unknown)}"

    if ! command -v swift &>/dev/null; then
        error "未找到 swift 命令行工具"
    fi

    local swift_version
    swift_version=$(swift --version 2>/dev/null | head -1 || true)
    info "  ${swift_version:-swift (version unknown)}"
}

# ─── 清理 ─────────────────────────────────────────────────────────────────────
clean() {
    info "清理构建产物..."
    rm -rf "$BUILD_DIR" "$DIST_DIR"
    success "清理完成"
}

# ─── 解析依赖 ─────────────────────────────────────────────────────────────────
resolve_deps() {
    info "解析 SPM 依赖（首次运行会下载 aws-sdk-swift，请耐心等待）..."
    swift package resolve
    success "依赖解析完成"
}

# ─── 直接运行（Debug 构建后启动）─────────────────────────────────────────────
run_app() {
    info "开始 Debug 构建并运行..."
    swift build 2>&1 | tee /tmp/s3tools-build.log | grep -E "error:|warning:|Build complete|Compiling" || true

    if grep -q "error:" /tmp/s3tools-build.log; then
        error "构建失败，无法运行，详细错误见 /tmp/s3tools-build.log"
    fi

    local BINARY="$BUILD_DIR/debug/$APP_NAME"
    [ -f "$BINARY" ] || error "未找到可执行文件: $BINARY"

    success "构建完成，正在启动 $APP_NAME..."
    echo ""
    open "$BINARY"
}

# ─── Debug 构建 ───────────────────────────────────────────────────────────────
build_debug() {
    info "开始 Debug 构建..."
    swift build 2>&1 | tee /tmp/s3tools-build.log | grep -E "error:|warning:|Build complete|Compiling" || true

    if grep -q "error:" /tmp/s3tools-build.log; then
        error "Debug 构建失败，详细错误见 /tmp/s3tools-build.log"
    fi
    success "Debug 构建完成 → $BUILD_DIR/debug/$APP_NAME"
}

# ─── Release 构建（使用 xcodebuild CLI）──────────────────────────────────────
build_release() {
    info "开始 Release 构建（xcodebuild）..."
    mkdir -p "$DIST_DIR"

    # 生成 ExportOptions.plist（无需 Apple 开发者账号签名时使用）
    generate_export_plist

    xcodebuild archive \
        -scheme "$SCHEME" \
        -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE_PATH" \
        -configuration Release \
        MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        2>&1 | tee /tmp/s3tools-archive.log | grep -E "error:|warning:|ARCHIVE SUCCEEDED|Build complete|Compiling" || true

    if ! xcodebuild -list -scheme "$SCHEME" &>/dev/null 2>&1 || [ ! -d "$ARCHIVE_PATH" ]; then
        warn "xcodebuild archive 失败，尝试 swift build --configuration release..."
        swift build --configuration release 2>&1 | tee /tmp/s3tools-build.log | grep -E "error:|Build complete|Compiling" || true
        if grep -q "error:" /tmp/s3tools-build.log 2>/dev/null; then
            error "Release 构建失败，详细错误见 /tmp/s3tools-build.log"
        fi
        # 手动组装 .app bundle
        assemble_app_bundle_from_swift_build
        return
    fi

    # 从 archive 导出 .app
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$DIST_DIR" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        2>&1 | grep -E "error:|EXPORT SUCCEEDED" || true

    if [ -d "$DIST_DIR/$APP_NAME.app" ]; then
        success "Release 构建完成 → $DIST_DIR/$APP_NAME.app"
    else
        warn "导出路径未找到 .app，尝试手动组装..."
        assemble_app_bundle_from_swift_build
    fi
}

# ─── 手动组装 .app bundle（swift build 产物）─────────────────────────────────
assemble_app_bundle_from_swift_build() {
    info "手动组装 .app bundle..."

    local BINARY="$BUILD_DIR/release/$APP_NAME"
    if [ ! -f "$BINARY" ]; then
        swift build --configuration release 2>&1 | grep -E "error:|Build complete" || true
    fi

    [ -f "$BINARY" ] || error "未找到可执行文件: $BINARY"

    local BUNDLE="$DIST_DIR/$APP_NAME.app"
    mkdir -p "$BUNDLE/Contents/MacOS"
    mkdir -p "$BUNDLE/Contents/Resources"

    cp "$BINARY" "$BUNDLE/Contents/MacOS/$APP_NAME"

    # 生成 Info.plist
    generate_info_plist "$BUNDLE/Contents/Info.plist"

    # 可选：复制图标（如果存在）
    if [ -f "Sources/S3Tools/Resources/AppIcon.icns" ]; then
        cp "Sources/S3Tools/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/"
    fi

    # 代码签名（本地，不需要开发者账号）
    codesign --force --deep --sign "-" "$BUNDLE" 2>/dev/null || warn "本地签名失败（可跳过）"

    success ".app bundle 已组装 → $BUNDLE"
}

# ─── 生成 Info.plist ──────────────────────────────────────────────────────────
generate_info_plist() {
    local plist_path="$1"
    local version="1.0.0"
    local build_num
    build_num="$(date +%Y%m%d%H%M)"

    cat > "$plist_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${build_num}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
EOF
    info "  生成 Info.plist (version=$version, build=$build_num)"
}

# ─── 生成 ExportOptions.plist ─────────────────────────────────────────────────
generate_export_plist() {
    cat > "$EXPORT_PLIST" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
}

# ─── 打包 .dmg ────────────────────────────────────────────────────────────────
create_dmg() {
    info "打包 .dmg..."

    [ -d "$APP_PATH" ] || error "未找到 .app: $APP_PATH，请先执行构建"

    # 优先使用 create-dmg
    if command -v create-dmg &>/dev/null; then
        info "  使用 create-dmg 工具..."
        rm -f "$DMG_PATH"
        create-dmg \
            --volname "$APP_NAME" \
            --window-size 600 400 \
            --icon-size 100 \
            --icon "$APP_NAME.app" 150 180 \
            --app-drop-link 450 180 \
            --no-internet-enable \
            "$DMG_PATH" \
            "$APP_PATH" 2>&1 | grep -v "^$" || true
    else
        # 回退：使用系统 hdiutil
        warn "  未找到 create-dmg，使用 hdiutil 创建简单 DMG"
        warn "  安装 create-dmg 获得更好效果: brew install create-dmg"
        create_dmg_hdiutil
    fi

    if [ -f "$DMG_PATH" ]; then
        local dmg_size
        dmg_size=$(du -sh "$DMG_PATH" | cut -f1)
        success "DMG 打包完成 → $DMG_PATH ($dmg_size)"
    else
        error "DMG 生成失败"
    fi
}

create_dmg_hdiutil() {
    local STAGING_DIR="/tmp/s3tools-dmg-staging"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    cp -R "$APP_PATH" "$STAGING_DIR/"
    # 添加 Applications 软链接（方便拖拽安装）
    ln -s /Applications "$STAGING_DIR/Applications"

    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$STAGING_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH" 2>&1 | grep -E "created|error" || true

    rm -rf "$STAGING_DIR"
}

# ─── 打印输出摘要 ─────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  S3Tools 构建完成${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    [ -d "$APP_PATH" ] && echo -e "  .app  → ${CYAN}$APP_PATH${NC}"
    [ -f "$DMG_PATH" ] && echo -e "  .dmg  → ${CYAN}$DMG_PATH${NC}"
    echo ""
    info "运行方式:"
    echo "    open $APP_PATH"
    [ -f "$DMG_PATH" ] && echo "    open $DMG_PATH   # 安装包"
    echo ""
    echo -e "  绕过 Gatekeeper（未签名 app）:"
    echo "    xattr -cr $APP_PATH"
    echo "    open $APP_PATH"
    echo ""
}

# ─── 主流程 ───────────────────────────────────────────────────────────────────
main() {
    local mode="${1:-debug}"

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  S3Tools Builder  [mode: $mode]${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════${NC}"
    echo ""

    case "$mode" in
        clean)
            clean
            ;;
        debug)
            check_deps
            resolve_deps
            build_debug
            ;;
        run)
            check_deps
            resolve_deps
            run_app
            ;;
        release)
            check_deps
            resolve_deps
            build_release
            print_summary
            ;;
        package)
            check_deps
            resolve_deps
            build_release
            create_dmg
            print_summary
            ;;
        *)
            echo "用法: $0 [debug|run|release|package|clean]"
            echo ""
            echo "  debug    - Debug 模式构建（默认）"
            echo "  run      - Debug 构建后直接启动应用"
            echo "  release  - Release 模式构建，生成 .app"
            echo "  package  - Release 构建 + 打包 .dmg"
            echo "  clean    - 清理所有构建产物"
            exit 1
            ;;
    esac
}

main "$@"
