#!/bin/zsh
set -euo pipefail

# 用 SwiftPM 构建，不再手写 swiftc 命令行，也不再写死 SDK 版本
# （旧脚本钉死 MacOSX15.4.sdk，系统升级后就会失效）。

project_dir="${0:A:h}"
version="0.4.0"
# app 文件名固定不带版本号：路径变化也会让 TCC 把它当成新 app，
# 每升一版就要重新授权一次。版本只体现在 Info.plist 的版本字段里。
app_path="/Applications/悬停翻译.app"
contents_path="$app_path/Contents"

echo "▸ 跑自测"
swift run --package-path "$project_dir" HoverTranslateCoreTests

echo "▸ 构建 release"
swift build --package-path "$project_dir" -c release --product HoverTranslate

binary_source="$(swift build --package-path "$project_dir" -c release --show-bin-path)/HoverTranslate"

echo "▸ 打包 .app"
rm -rf "$app_path"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$project_dir/Info.plist" "$contents_path/Info.plist"
cp "$project_dir/PkgInfo" "$contents_path/PkgInfo"
cp "$project_dir/Resources/AppIcon.icns" "$contents_path/Resources/AppIcon.icns"
cp "$binary_source" "$contents_path/MacOS/HoverTranslate"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents_path/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$contents_path/Info.plist" 2>/dev/null || true

codesign --force --sign - "$app_path"

echo "$app_path"
echo
echo "⚠️  adhoc 签名，每次重新构建后「辅助功能」和「屏幕录制」授权都会失效。"
echo "   打开后若不翻译，去系统设置把这两项里的旧条目删掉再重新添加，然后重启 app。"
