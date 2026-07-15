#!/bin/bash
# voxai-mcp 分发构建：universal → 签名 → 打包 → 公证 → 校验
#
# 产物：dist/voxai-mcp-v<版本>-macos-universal.zip（公证过，可直接
# 挂 GitHub Release，brew formula 引用它）
#
# 前置（都已就位，换机器才需重做）：
#   - Developer ID Application 证书在钥匙串（TEAM_ID 见下）
#   - 公证凭据 profile（与直发版共用，同一 team）：
#     xcrun notarytool store-credentials voxsage-notary \
#       --apple-id <AppleID> --team-id YNMBJ5H736 --password <app专用密码>
#
# 为什么 zip 不是 dmg：这是命令行二进制不是 App，用户不 mount 它。
# 为什么 zip 不是 tar.gz：notarytool 只收 zip/pkg/dmg（07-14 踩实）。
# 公证记录绑定的是二进制自身的 hash，容器只是运输——所以公证什么格式
# 就分发什么格式，少一层转换。Apple 不给裸二进制盖章（stapler 只认
# app/dmg/pkg），校验靠 Gatekeeper 首次运行时在线查公证记录。
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "用法: ./release.sh <版本号>   例: ./release.sh 2.0.0"
    exit 1
fi

SIGN_ID="Developer ID Application"
NOTARY_PROFILE="voxsage-notary"
BIN=".build/apple/Products/Release/voxai-mcp"
STAGE="dist/stage"
ZIP="dist/voxai-mcp-macos-universal.zip"   # 资产名不带版本→latest/download URL 永久稳定

echo "▸ [1/5] universal 构建（arm64 + x86_64）"
swift build -c release --arch arm64 --arch x86_64
lipo -info "$BIN"

echo "▸ [2/5] Developer ID 签名（hardened runtime + 安全时间戳）"
# --options runtime 是公证的硬性前提；--timestamp 保证证书过期后签名仍有效
codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$BIN"
codesign --verify --strict --verbose=2 "$BIN"

echo "▸ [3/5] 打包 zip（ditto 是 Apple 认的归档方式，保签名元数据）"
rm -rf "$STAGE" && mkdir -p "$STAGE" "$(dirname "$ZIP")"
cp "$BIN" "$STAGE/voxai-mcp"
rm -f "$ZIP"
ditto -c -k "$STAGE/voxai-mcp" "$ZIP"
rm -rf "$STAGE"

echo "▸ [4/5] 公证（提交 Apple 并等待裁决）"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ [5/5] 校验：解出来的二进制能否过 Gatekeeper"
VERIFY_DIR=$(mktemp -d)
ditto -x -k "$ZIP" "$VERIFY_DIR"
# spctl 对命令行工具用 -a -t open --context 上下文（-t exec 只认 App bundle）
spctl -a -t open --context context:primary-signature -vv "$VERIFY_DIR/voxai-mcp" 2>&1 || true
codesign -dv --verbose=4 "$VERIFY_DIR/voxai-mcp" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp|flags"
rm -rf "$VERIFY_DIR"

echo ""
echo "✅ 产物: $ZIP"
echo "   sha256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo ""
echo "下一步（需 Rebecca 授权的对外动作）——发 Release，App 内提示语的 latest URL 即刻生效："
echo "  gh release create voxai-mcp-v${VERSION} $ZIP \\"
echo "    --title \"voxai-mcp v${VERSION}\" --notes \"VoxAI 伴生 MCP server(universal,已公证)\""
