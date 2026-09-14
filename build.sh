#!/usr/bin/env bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

OUTPUT_NAME="tailscale-native-v1.102.4.zip"
OUTPUT_PATH="$PROJECT_DIR/$OUTPUT_NAME"

echo "=========================================="
echo " Building Tailscale Native KernelSU Module"
echo "=========================================="

# 1. 检查官方 ARM64 静态二进制文件
if [ ! -f "system/bin/tailscale" ] || [ ! -f "system/bin/tailscaled" ]; then
    echo "- 正在拉取 Tailscale 官方静态 ARM64 二进制..."
    mkdir -p system/bin
    curl -sL "https://pkgs.tailscale.com/stable/tailscale_1.102.4_arm64.tgz" | \
        tar -xz -C system/bin/ --strip-components=1 tailscale_1.102.4_arm64/tailscale tailscale_1.102.4_arm64/tailscaled
fi

# 2. 检查权限
echo "- 设置文件权限..."
chmod 755 customize.sh service.sh uninstall.sh webui.sh 2>/dev/null || true
chmod 755 scripts/*.sh 2>/dev/null || true
chmod 755 system/bin/* 2>/dev/null || true

# 3. 打包 ZIP
echo "- 正在打包生成 $OUTPUT_NAME ..."
rm -f "$OUTPUT_PATH"

zip -r9 "$OUTPUT_PATH" \
    module.prop \
    customize.sh \
    service.sh \
    uninstall.sh \
    webui.sh \
    icon.png \
    system \
    scripts \
    webroot \
    -x "data/*" "*.git*" "*DS_Store*"

echo "=========================================="
echo " 打包完成!"
echo " 输出文件: $OUTPUT_PATH"
echo " 文件大小: $(du -h "$OUTPUT_PATH" | cut -f1)"
echo " SHA256: $(sha256sum "$OUTPUT_PATH" | awk '{print $1}')"
echo "=========================================="

