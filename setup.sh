#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== CampusVPN 项目设置 ==="

if ! command -v xcodegen &>/dev/null; then
    echo "XcodeGen 未安装，正在通过 Homebrew 安装..."
    if command -v brew &>/dev/null; then
        brew install xcodegen
    else
        echo "请先安装 Homebrew (https://brew.sh) 或手动安装 XcodeGen"
        exit 1
    fi
fi

echo "正在生成 Xcode 项目..."
xcodegen generate

echo "=== 项目生成完成 ==="
echo ""
echo "使用方式："
echo "  1. 打开 CampusVPN.xcodeproj"
echo "  2. 选择 CampusVPN target"
echo "  3. 按 Cmd+R 运行"
echo ""
echo "或命令行构建："
echo "  xcodebuild -project CampusVPN.xcodeproj -scheme CampusVPN -configuration Release build"
