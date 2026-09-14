#!/system/bin/sh
SKIPUNZIP=0

ui_print "****************************************"
ui_print "*        Tailscale Native for KernelSU *"
ui_print "*    原生内核模式 · 无需占用 Android VPN *"
ui_print "****************************************"

# 1. 架构检测
ui_print "- 正在检测系统架构..."
if [ "$ARCH" != "arm64" ]; then
    abort "! 错误: 本模块仅支持 ARM64 (aarch64) 设备，当前检测为: $ARCH"
fi
ui_print "- 设备架构: $ARCH (支持)"

# 2. 迁移/保留更新前配置与状态文件
OLD_DATA_DIR="/data/adb/modules/tailscale_native/data"
if [ -d "$OLD_DATA_DIR" ]; then
    ui_print "- 发现已有运行数据与状态，正在迁移保留..."
    mkdir -p "$MODPATH/data"
    [ -f "$OLD_DATA_DIR/tailscaled.state" ] && cp -af "$OLD_DATA_DIR/tailscaled.state" "$MODPATH/data/"
    if [ -f "$OLD_DATA_DIR/config.json" ]; then
        cp -af "$OLD_DATA_DIR/config.json" "$MODPATH/data/"
        sed -i 's/"accept_dns"[[:space:]]*:[[:space:]]*"true"/"accept_dns": "false"/g' "$MODPATH/data/config.json" 2>/dev/null || true
    fi
fi

# 3. 创建必要的数据目录
mkdir -p "$MODPATH/data"
mkdir -p "$MODPATH/system/bin"
mkdir -p "$MODPATH/scripts"
mkdir -p "$MODPATH/webroot"

# 4. 设置执行权限
ui_print "- 设置文件执行权限..."
set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/webui.sh" 0 0 0755

ui_print "****************************************"
ui_print "* 安装完成!"
ui_print "* 重启后在 KernelSU 管理器中打开本模块 WebUI"
ui_print "* 即可进行一键认证、路由配置与 Exit Node 管理"
ui_print "****************************************"

