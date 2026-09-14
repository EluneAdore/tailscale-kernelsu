#!/system/bin/sh
ACTION="${1:-apply}"

clean_rules() {
    # 清除旧的 iptables 规则
    iptables -D FORWARD -i tailscale0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -o tailscale0 -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -i tailscale0 -j ACCEPT 2>/dev/null
    ip6tables -D FORWARD -o tailscale0 -j ACCEPT 2>/dev/null

    iptables -t nat -D POSTROUTING -o tailscale0 -j MASQUERADE 2>/dev/null
    iptables -t nat -D POSTROUTING -o wlan+ -j MASQUERADE 2>/dev/null
    iptables -t nat -D POSTROUTING -o rmnet+ -j MASQUERADE 2>/dev/null
    iptables -t nat -D POSTROUTING -o ccmni+ -j MASQUERADE 2>/dev/null

    # 清除策略路由规则
    ip rule del to 100.64.0.0/10 lookup main pref 9990 2>/dev/null
    ip rule del lookup main pref 9991 2>/dev/null
    ip rule del lookup main pref 9992 2>/dev/null
    ip rule del lookup 1000 pref 9995 2>/dev/null
    ip rule del pref 9995 2>/dev/null
    ip6rule del to fd7a:115c:a1e0::/48 lookup main pref 9990 2>/dev/null
}

sync_android_routes() {
    # 查找 Android 当前活动的默认网关与网络接口 (wlan0 或 rmnet+)
    DEF_ROUTE=$(ip route show table 0 2>/dev/null | grep -E 'default via [0-9\.]+' | head -n 1)
    DEF_GW=$(echo "$DEF_ROUTE" | awk '{print $3}')
    DEF_DEV=$(echo "$DEF_ROUTE" | awk '{print $5}')
    DEF_TABLE=$(echo "$DEF_ROUTE" | grep -o 'table [0-9a-zA-Z_]*' | awk '{print $2}')

    if [ -z "$DEF_DEV" ]; then
        # 尝试查找已连接的 WiFi 或蜂窝网卡
        DEF_DEV=$(ip -4 -o addr show | grep -E 'wlan|rmnet|ccmni' | head -n 1 | awk '{print $2}')
    fi

    # 1. 将默认网关同步到 table main 中，避免 root 进程触发 Android rule 32000 (unreachable)
    if [ -n "$DEF_GW" ] && [ -n "$DEF_DEV" ]; then
        ip route replace default via "$DEF_GW" dev "$DEF_DEV" table main 2>/dev/null
    elif [ -n "$DEF_DEV" ]; then
        ip route replace default dev "$DEF_DEV" table main 2>/dev/null
    fi

    # 2. 如果 Android 使用特定数字路由表 (如 table 1021)，添加优先查找该表的策略规则
    if [ -n "$DEF_TABLE" ] && [ "$DEF_TABLE" != "main" ]; then
        ip rule del pref 9995 2>/dev/null
        ip rule add from all lookup "$DEF_TABLE" pref 9995 2>/dev/null
    fi

    # 3. 保证 table main 在 netd 限制之前被查询
    ip rule del lookup main pref 9991 2>/dev/null
    ip rule add from all lookup main pref 9991 2>/dev/null

    # 4. Tailnet 内网虚拟网段策略规则
    ip rule del to 100.64.0.0/10 lookup main pref 9990 2>/dev/null
    ip rule add to 100.64.0.0/10 lookup main pref 9990 2>/dev/null
    ip6rule del to fd7a:115c:a1e0::/48 lookup main pref 9990 2>/dev/null
    ip6rule add to fd7a:115c:a1e0::/48 lookup main pref 9990 2>/dev/null
}

apply_rules() {
    clean_rules

    # 1. 允许 TUN 接口流量转发
    iptables -I FORWARD 1 -i tailscale0 -j ACCEPT 2>/dev/null
    iptables -I FORWARD 1 -o tailscale0 -j ACCEPT 2>/dev/null
    ip6tables -I FORWARD 1 -i tailscale0 -j ACCEPT 2>/dev/null
    ip6tables -I FORWARD 1 -o tailscale0 -j ACCEPT 2>/dev/null

    # 2. NAT 伪装规则 (支持本机广播出口 Exit Node 与子网路由转发)
    iptables -t nat -I POSTROUTING 1 -o tailscale0 -j MASQUERADE 2>/dev/null
    iptables -t nat -I POSTROUTING 1 -o wlan+ -j MASQUERADE 2>/dev/null
    iptables -t nat -I POSTROUTING 1 -o rmnet+ -j MASQUERADE 2>/dev/null
    iptables -t nat -I POSTROUTING 1 -o ccmni+ -j MASQUERADE 2>/dev/null

    # 3. 修复 Android 默认路由与策略规则
    sync_android_routes
}

case "$ACTION" in
    apply)
        apply_rules
        ;;
    sync_routes)
        sync_android_routes
        ;;
    clean)
        clean_rules
        ;;
    *)
        echo "Usage: $0 {apply|sync_routes|clean}"
        exit 1
        ;;
esac

exit 0
