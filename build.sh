#!/bin/bash
set -e

# ---------- 参数 ----------

DEBUG_MODE=false
for arg in "$@"; do
    case "$arg" in
        -d|--debug) DEBUG_MODE=true ;;
    esac
done

# ---------- 路径 ----------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BarMusic"
APP="$SCRIPT_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BIN="$MACOS/$APP_NAME"
ICONSET_SRC="$SCRIPT_DIR/icon.iconset"
ICON_DST="$RESOURCES/AppIcon.icns"

# ---------- 编译目标 ----------

SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos13.0"

# ---------- 开始 ----------

if [ "$DEBUG_MODE" = true ]; then
    echo "[$APP_NAME] 开始构建 (DEBUG, arch: $ARCH)"
else
    echo "[$APP_NAME] 开始构建 (arch: $ARCH)"
fi

# 1. 检查编译环境
if ! command -v swiftc &>/dev/null; then
    echo "[错误] 找不到 swiftc，请安装 Command Line Tools："
    echo "       xcode-select --install"
    exit 1
fi

# 2. 清理并重建目录结构
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

# 3. 图标生成
if [ -d "$ICONSET_SRC" ]; then
    echo "[图标] 使用 icon.iconset 生成 AppIcon.icns..."
    iconutil -c icns "$ICONSET_SRC" -o "$ICON_DST"
    echo "[图标] 完成"
else
    echo "[警告] 未找到 icon.iconset，将使用系统空白图标"
fi

# 4. 收集源文件并编译
echo "[编译] 正在收集源文件..."
SWIFT_FILES=()
while IFS= read -r f; do
    SWIFT_FILES+=("$f")
done < <(find "$SCRIPT_DIR" -name "*.swift" ! -name "clip_icon.swift" ! -path "*/文档/*" | sort)

echo "[编译] 共 ${#SWIFT_FILES[@]} 个文件，目标 $TARGET"
swiftc \
    -O \
    -sdk "$SDK" \
    -target "$TARGET" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework iTunesLibrary \
    -framework CryptoKit \
    "${SWIFT_FILES[@]}" \
    -o "$BIN"

# 5. 生成 Info.plist
ICON_KEY=""
[ -f "$ICON_DST" ] && ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"

cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>                <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>         <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>          <string>com.linkapps.BarMusic</string>
  <key>CFBundleVersion</key>             <string>3</string>
  <key>CFBundleShortVersionString</key>  <string>2.1.1</string>
  <key>CFBundleExecutable</key>          <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>         <string>APPL</string>
  <key>NSPrincipalClass</key>            <string>NSApplication</string>
  <key>LSMinimumSystemVersion</key>      <string>13.0</string>
  <key>LSUIElement</key>                 <true/>
  <key>NSAppleMusicUsageDescription</key>
  <string>需要访问您的音乐库以读取和播放本地播放列表。</string>
  $ICON_KEY
</dict>
</plist>
PLIST

# ---------- 完成 ----------

echo ""
echo "[$APP_NAME 构建成功] $APP"
echo ""
echo "按 Enter 打开应用，按 ESC 取消..."

_open_app=false
while IFS= read -rsn1 key; do
    if [[ "$key" == "" ]]; then
        _open_app=true
        break
    elif [[ "$key" == $'\x1b' ]]; then
        break
    fi
done

if [ "$_open_app" = true ]; then
    open "$APP"
fi
