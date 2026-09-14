#!/system/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODDIR="$(cd "$SCRIPT_DIR/.." && pwd)"

mod_ver=$(grep "^version=" "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2 | sed 's/^v//')
CURRENT_VER="${mod_ver:-1.102.4}"
DATA_DIR="$MODDIR/data"
BIN_DIR="$MODDIR/system/bin"
BACKUP_DIR="$MODDIR/data/backup_bin"
LOG_FILE="$DATA_DIR/tailscaled.log"

log() {
    echo "[$(date '+%Y/%m/%d %H:%M:%S')] [Update] $1" >> "$LOG_FILE"
    echo "$1"
}

check_latest() {
    LATEST=$(curl -sL --connect-timeout 8 https://pkgs.tailscale.com/stable/ | grep -o 'tailscale_[0-9\.]*_arm64\.tgz' | head -n 1 | sed 's/tailscale_//;s/_arm64.tgz//')
    echo "$LATEST"
}

do_update() {
    latest=$(check_latest)
    if [ -z "$latest" ]; then
        log "无法检测到线上最新版本，请检查网络连接。"
        return 1
    fi

    if [ "$latest" = "$CURRENT_VER" ]; then
        log "当前已是最新版本 ($CURRENT_VER)，无需更新。"
        return 0
    fi

    log "发现新版本: v$latest (当前版本: v$CURRENT_VER)，正在准备更新..."
    
    TMP_TGZ="$DATA_DIR/tailscale_${latest}_arm64.tgz"
    TMP_DIR="$DATA_DIR/update_extract"
    mkdir -p "$TMP_DIR"
    mkdir -p "$BACKUP_DIR"

    URL="https://pkgs.tailscale.com/stable/tailscale_${latest}_arm64.tgz"
    log "下载新核心: $URL ..."
    curl -sL "$URL" -o "$TMP_TGZ"
    if [ $? -ne 0 ] || [ ! -f "$TMP_TGZ" ]; then
        log "下载失败！"
        rm -rf "$TMP_TGZ" "$TMP_DIR"
        return 1
    fi

    # 解压二进制
    tar -xzf "$TMP_TGZ" -C "$TMP_DIR"
    EXTRACTED_DIR=$(find "$TMP_DIR" -type d -name "tailscale_${latest}_arm64" | head -n 1)
    if [ -z "$EXTRACTED_DIR" ] || [ ! -f "$EXTRACTED_DIR/tailscaled" ]; then
        log "解压验证失败！"
        rm -rf "$TMP_TGZ" "$TMP_DIR"
        return 1
    fi

    # 备份旧版本
    log "备份当前核心文件..."
    cp -af "$BIN_DIR/tailscale" "$BACKUP_DIR/" 2>/dev/null
    cp -af "$BIN_DIR/tailscaled" "$BACKUP_DIR/" 2>/dev/null

    # 替换新版本
    log "安装新核心..."
    cp -af "$EXTRACTED_DIR/tailscale" "$BIN_DIR/"
    cp -af "$EXTRACTED_DIR/tailscaled" "$BIN_DIR/"
    chmod 755 "$BIN_DIR/tailscale" "$BIN_DIR/tailscaled"

    # 清理临时文件
    rm -rf "$TMP_TGZ" "$TMP_DIR"

    # 更新 module.prop 版本号
    sed -i "s/^version=.*/version=v$latest/" "$MODDIR/module.prop"

    log "内核更新完成！当前版本: v$latest。正在平滑重启服务..."
    if [ -f "$MODDIR/scripts/control.sh" ]; then
        sh "$MODDIR/scripts/control.sh" restart
    fi
}

ACTION="${1:-check}"
case "$ACTION" in
    check)
        check_latest
        ;;
    update)
        do_update
        ;;
    *)
        echo "Usage: $0 {check|update}"
        exit 1
        ;;
esac

exit 0

