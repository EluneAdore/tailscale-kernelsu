#!/system/bin/sh
MODDIR="${0%/*}"

# 等待系统启动完成
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# 等待网络就绪
sleep 3

# 确保内核 TUN 设备可用
if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net
    if [ -c /dev/tun ]; then
        ln -sf /dev/tun /dev/net/tun
    else
        mknod /dev/net/tun c 10 200 2>/dev/null
    fi
fi
chmod 0666 /dev/net/tun 2>/dev/null
chmod 0666 /dev/tun 2>/dev/null

# 开启内核 IP 转发支持 (Subnet Router 与 Exit Node 必需)
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null

# 检查自启配置并启动服务
# 如果用户没有显式禁用自启 (例如 disabled 文件存在)，则默认开机自启
if [ ! -f "$MODDIR/data/autostart_disabled" ]; then
    sh "$MODDIR/scripts/control.sh" start_boot >/dev/null 2>&1 &
fi

# 后台定时检测自动更新 (如果开启)
if [ -f "$MODDIR/scripts/update.sh" ]; then
    (
        while true; do
            cfg_file="$MODDIR/data/config.json"
            auto_up=""
            interval="86400"
            if [ -f "$cfg_file" ]; then
                auto_up=$(grep -o '"auto_update"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg_file" 2>/dev/null | head -n 1 | cut -d'"' -f4)
                cfg_int=$(grep -o '"update_interval"[[:space:]]*:[[:space:]]*"[^"]*"' "$cfg_file" 2>/dev/null | head -n 1 | cut -d'"' -f4)
                [ -n "$cfg_int" ] && interval="$cfg_int"
            fi
            sleep "$interval"
            if [ "$auto_up" = "true" ]; then
                sh "$MODDIR/scripts/update.sh" update >/dev/null 2>&1
            fi
        done
    ) &
fi

exit 0

