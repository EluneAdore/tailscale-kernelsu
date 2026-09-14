#!/system/bin/sh
MODDIR="${0%/*}"

# 停止 tailscale 服务与进程
if [ -f "$MODDIR/scripts/control.sh" ]; then
    sh "$MODDIR/scripts/control.sh" stop
fi

killall tailscaled 2>/dev/null
killall tailscale 2>/dev/null

# 清理防火墙规则
if [ -f "$MODDIR/scripts/iptables.sh" ]; then
    sh "$MODDIR/scripts/iptables.sh" clean
fi

# 清理 TUN 策略路由规则
ip rule del lookup main pref 10000 2>/dev/null
ip rule del lookup main pref 10001 2>/dev/null

exit 0

