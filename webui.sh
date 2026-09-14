#!/system/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODDIR="$SCRIPT_DIR"

DATA_DIR="$MODDIR/data"
mkdir -p "$DATA_DIR"

SOCKET_FILE="$DATA_DIR/tailscaled.sock"
STATE_FILE="$DATA_DIR/tailscaled.state"
LOG_FILE="$DATA_DIR/tailscaled.log"
CONFIG_FILE="$DATA_DIR/config.json"

# 二进制文件定位
if [ -x "/system/bin/tailscaled" ]; then
    DAEMON_BIN="/system/bin/tailscaled"
elif [ -x "$MODDIR/system/bin/tailscaled" ]; then
    DAEMON_BIN="$MODDIR/system/bin/tailscaled"
else
    DAEMON_BIN="tailscaled"
fi

if [ -x "/system/bin/tailscale" ]; then
    CLI_BIN="/system/bin/tailscale"
elif [ -x "$MODDIR/system/bin/tailscale" ]; then
    CLI_BIN="$MODDIR/system/bin/tailscale"
else
    CLI_BIN="tailscale"
fi

ts_cli() {
    "$CLI_BIN" --socket="$SOCKET_FILE" "$@"
}

get_config_val() {
    key="$1"
    if [ -f "$CONFIG_FILE" ]; then
        grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CONFIG_FILE" 2>/dev/null | head -n 1 | cut -d'"' -f4
    fi
}

set_config_val() {
    key="$1"
    val="$2"
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "{}" > "$CONFIG_FILE"
    fi
    if which python3 >/dev/null 2>&1; then
        python3 -c "import json; p='$CONFIG_FILE'; d=json.load(open(p)) if open(p).read().strip() else {}; d['$key']='$val'; json.dump(d, open(p, 'w'), indent=2)" 2>/dev/null
    else
        grep -v "\"$key\"" "$CONFIG_FILE" 2>/dev/null | sed 's/}$//' > "$CONFIG_FILE.tmp"
        echo "  ,\"$key\": \"$val\"}" >> "$CONFIG_FILE.tmp"
        mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
}

setup_dns() {
    dns1=$(getprop net.dns1 2>/dev/null)
    dns2=$(getprop net.dns2 2>/dev/null)
    # 过滤掉无效或可能无响应的回环地址
    [ "$dns1" = "127.0.0.1" ] || [ "$dns1" = "::1" ] && dns1=""
    [ "$dns2" = "127.0.0.1" ] || [ "$dns2" = "::1" ] && dns2=""

    mkdir -p "$MODDIR/system/etc"
    cat <<EOF > "$MODDIR/system/etc/resolv.conf"
nameserver ${dns1:-223.5.5.5}
nameserver ${dns2:-119.29.29.29}
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    # 检查当前 /etc/resolv.conf 是否有效可用
    need_mount=0
    if [ ! -s /etc/resolv.conf ]; then
        need_mount=1
    elif grep -qE '^[[:space:]]*nameserver[[:space:]]+(127\.0\.0\.1|::1)' /etc/resolv.conf 2>/dev/null; then
        # 如果包含回环地址，检查是否有非回环的可用 nameserver
        has_real_ns=$(grep -E '^[[:space:]]*nameserver[[:space:]]+[0-9a-fA-F\.:]+' /etc/resolv.conf 2>/dev/null | grep -vE '(127\.0\.0\.1|::1)' | head -n 1)
        if [ -z "$has_real_ns" ]; then
            need_mount=1
        fi
    fi

    if [ "$need_mount" = "1" ]; then
        mount -o remount,rw /system 2>/dev/null || true
        if [ ! -e /system/etc/resolv.conf ]; then
            cp "$MODDIR/system/etc/resolv.conf" /system/etc/resolv.conf 2>/dev/null || true
        fi
        umount /etc/resolv.conf 2>/dev/null || true
        mount --bind "$MODDIR/system/etc/resolv.conf" /etc/resolv.conf 2>/dev/null || true
    fi
}

ensure_tun_and_network() {
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

    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null
    echo 1 > /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null

    setup_dns

    if [ -f "$MODDIR/scripts/iptables.sh" ]; then
        sh "$MODDIR/scripts/iptables.sh" sync_routes
    fi
}

get_daemon_pids() {
    pgrep -f "$DAEMON_BIN" 2>/dev/null || pgrep -f "tailscaled" 2>/dev/null
}

get_device_model() {
    m=$(getprop ro.product.model 2>/dev/null)
    [ -z "$m" ] && m=$(getprop ro.product.marketname 2>/dev/null)
    [ -z "$m" ] && m=$(getprop ro.product.vendor.model 2>/dev/null)
    [ -z "$m" ] && m=$(getprop ro.product.odm.model 2>/dev/null)
    echo "$m"
}

get_cert_model() {
    c=$(getprop ro.product.name 2>/dev/null)
    [ -z "$c" ] && c=$(getprop ro.product.cert 2>/dev/null)
    [ -z "$c" ] && c=$(getprop ro.product.device 2>/dev/null)
    [ -z "$c" ] && c=$(getprop ro.build.product 2>/dev/null)
    echo "$c"
}

get_priority_hostname() {
    custom_name=$(get_config_val "hostname")
    if [ -n "$custom_name" ]; then
        echo "$custom_name"
        return
    fi
    m=$(get_device_model)
    if [ -n "$m" ]; then
        echo "$m"
        return
    fi
    c=$(get_cert_model)
    if [ -n "$c" ]; then
        echo "$c"
        return
    fi
    echo "android-device"
}

start_watchdog() {
    rm -f "$DATA_DIR/manual_stopped" 2>/dev/null
    w_pid=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
    if [ -n "$w_pid" ] && kill -0 "$w_pid" 2>/dev/null; then
        return 0
    fi
    w_pid=$(pgrep -f "$MODDIR/scripts/watchdog.sh" 2>/dev/null | head -n 1)
    if [ -n "$w_pid" ]; then
        echo "$w_pid" > "$DATA_DIR/daemon.pid"
        return 0
    fi
    if [ -f "$MODDIR/scripts/watchdog.sh" ]; then
        nohup sh "$MODDIR/scripts/watchdog.sh" >/dev/null 2>&1 &
        echo $! > "$DATA_DIR/daemon.pid"
    fi
}

stop_watchdog() {
    touch "$DATA_DIR/manual_stopped" 2>/dev/null
    w_pid=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
    if [ -n "$w_pid" ]; then
        kill -TERM "$w_pid" 2>/dev/null
        kill -9 "$w_pid" 2>/dev/null
    fi
    pkill -f "$MODDIR/scripts/watchdog.sh" 2>/dev/null || true
    rm -f "$DATA_DIR/daemon.pid" 2>/dev/null
}

cmd_status() {
    all_pids=$(get_daemon_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    m_pid=$(echo "$all_pids" | awk '{print $1}')
    
    # 独立获取看门狗守护进程 PID
    d_pid=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
    if [ -n "$d_pid" ] && ! kill -0 "$d_pid" 2>/dev/null; then
        d_pid=""
    fi
    if [ -z "$d_pid" ]; then
        d_pid=$(pgrep -f "$MODDIR/scripts/watchdog.sh" 2>/dev/null | head -n 1)
    fi

    running="false"
    if [ -n "$m_pid" ]; then
        running="true"
        if [ -z "$d_pid" ] && [ ! -f "$DATA_DIR/manual_stopped" ]; then
            start_watchdog
            d_pid=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
        fi
    fi

    # 获取 tailscale 状态
    ts_json="{}"
    if [ "$running" = "true" ] && [ -S "$SOCKET_FILE" ]; then
        ts_json=$(ts_cli status --json 2>/dev/null)
        if [ -z "$ts_json" ]; then
            ts_json="{}"
        fi
    fi

    accept_routes=$(get_config_val "accept_routes")
    accept_dns=$(get_config_val "accept_dns")
    exit_node_allow_lan=$(get_config_val "exit_node_allow_lan")
    adv_exit=$(get_config_val "advertise_exit_node")
    adv_routes_en=$(get_config_val "advertise_routes_enabled")
    adv_routes=$(get_config_val "advertise_routes")
    active_exit=$(get_config_val "exit_node")
    auth_url=""

    dev_model=$(get_device_model)
    cert_model=$(get_cert_model)
    custom_host=$(get_config_val "hostname")
    prio_host=$(get_priority_hostname)

    auto_update=$(get_config_val "auto_update")
    update_interval=$(get_config_val "update_interval")
    latest_ver=$(get_config_val "latest_version")
    core_ver=$(grep "^version=" "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
    [ -z "$core_ver" ] && core_ver="v1.102.4"

    cat <<EOF
{
  "running": $running,
  "main_pid": "${m_pid:-}",
  "daemon_pid": "${d_pid:-}",
  "pid": "${m_pid:-}",
  "version": "${core_ver}",
  "device_model": "${dev_model:-}",
  "cert_model": "${cert_model:-}",
  "custom_hostname": "${custom_host:-}",
  "priority_hostname": "${prio_host:-}",
  "accept_routes": "${accept_routes:-false}",
  "accept_dns": "${accept_dns:-false}",
  "exit_node_allow_lan": "${exit_node_allow_lan:-true}",
  "advertise_exit_node": "${adv_exit:-false}",
  "advertise_routes_enabled": "${adv_routes_en:-false}",
  "advertise_routes": "${adv_routes:-}",
  "exit_node": "${active_exit:-}",
  "auto_update": "${auto_update:-false}",
  "update_interval": "${update_interval:-86400}",
  "latest_version": "${latest_ver:-}",
  "auth_url": "$auth_url",
  "raw_status": $ts_json
}
EOF
}

cmd_start() {
    rm -f "$DATA_DIR/manual_stopped" 2>/dev/null
    pids=$(get_daemon_pids)
    if [ -n "$pids" ]; then
        start_watchdog
        cmd_status
        return 0
    fi

    ensure_tun_and_network

    # 代理环境变量设置
    proxy=$(get_config_val "proxy")
    if [ -n "$proxy" ]; then
        export HTTP_PROXY="$proxy"
        export HTTPS_PROXY="$proxy"
        export ALL_PROXY="$proxy"
        export http_proxy="$proxy"
        export https_proxy="$proxy"
        export all_proxy="$proxy"
        echo "[$(date '+%Y/%m/%d %H:%M:%S')] [Proxy] Configured outbound proxy: $proxy" >> "$LOG_FILE"
    fi

    # 网卡设备绑定控制 (默认关闭，避免阻断透明代理/Fake-IP及本机 127.0.0.1 代理端口)
    bind_device=$(get_config_val "bind_to_device")
    if [ "$bind_device" = "true" ]; then
        export TS_FORCE_LINUX_BIND_TO_DEVICE=true
        echo "[$(date '+%Y/%m/%d %H:%M:%S')] [Network] TS_FORCE_LINUX_BIND_TO_DEVICE enabled" >> "$LOG_FILE"
    else
        unset TS_FORCE_LINUX_BIND_TO_DEVICE
    fi

    echo "[$(date '+%Y/%m/%d %H:%M:%S')] Starting tailscaled native daemon..." >> "$LOG_FILE"
    nohup "$DAEMON_BIN" \
        --state="$STATE_FILE" \
        --socket="$SOCKET_FILE" \
        --tun=tailscale0 \
        --port=41641 \
        --statedir="$DATA_DIR" >> "$LOG_FILE" 2>&1 &

    count=0
    while [ $count -lt 30 ]; do
        if [ -S "$SOCKET_FILE" ]; then
            break
        fi
        sleep 0.1
        count=$((count + 1))
    done

    # 启动看门狗守护进程
    start_watchdog

    if [ -f "$MODDIR/scripts/iptables.sh" ]; then
        sh "$MODDIR/scripts/iptables.sh" apply
    fi

    # 自动按优先级配置主机名 (设备型号 -> 认证型号 -> 默认值)
    prio_name=$(get_priority_hostname)
    dns_safe_name=$(echo "$prio_name" | tr ' ' '-' | tr -cd 'a-zA-Z0-9-')
    if [ -n "$dns_safe_name" ] && [ -S "$SOCKET_FILE" ]; then
        curr_host=$(ts_cli status --json 2>/dev/null | grep -o '"HostName"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4)
        if [ "$curr_host" != "$dns_safe_name" ]; then
            ts_cli set --hostname="$dns_safe_name" >/dev/null 2>&1 || true
        fi
    fi

    # 彻底杜绝 Android 上 atomicWriteFile /etc/resolv.conf 只读报错
    # Android 系统 DNS 完全由 netd/系统分流管理，不支持也不需要改写只读分区上的 /etc/resolv.conf
    accept_dns_val=$(get_config_val "accept_dns")
    if [ "$accept_dns_val" != "true" ] && [ -S "$SOCKET_FILE" ]; then
        ts_cli set --accept-dns=false >/dev/null 2>&1 || true
    fi

    cmd_status
}

cmd_stop() {
    echo "[$(date '+%Y/%m/%d %H:%M:%S')] Stopping tailscaled..." >> "$LOG_FILE"
    
    stop_watchdog

    if [ -f "$MODDIR/scripts/iptables.sh" ]; then
        sh "$MODDIR/scripts/iptables.sh" clean
    fi

    pids=$(get_daemon_pids)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill -TERM "$pid" 2>/dev/null
        done
        sleep 1
        for pid in $pids; do
            kill -9 "$pid" 2>/dev/null
        done
    fi

    rm -f "$SOCKET_FILE" 2>/dev/null
    cmd_status
}

cmd_restart() {
    cmd_stop >/dev/null 2>&1
    sleep 1
    cmd_start
}

cmd_save_config() {
    routes="$1"
    dns="$2"
    set_config_val "accept_routes" "$routes"
    set_config_val "accept_dns" "$dns"

    ts_cli set --accept-routes="$routes" --accept-dns="$dns" 2>&1
    echo "OK"
}

cmd_set_exit_node_allow_lan() {
    enabled="$1"
    set_config_val "exit_node_allow_lan" "$enabled"

    active_node=$(get_config_val "exit_node")
    if [ -n "$active_node" ]; then
        ts_cli set --exit-node="$active_node" --exit-node-allow-lan-access="$enabled" 2>&1
    fi
    echo "OK"
}

cmd_set_exit_node() {
    node="$1"
    allow_lan="$2"
    set_config_val "exit_node" "$node"

    if [ -z "$node" ]; then
        ts_cli set --exit-node="" 2>&1
    else
        lan_opt=""
        if [ "$allow_lan" = "true" ]; then
            lan_opt="--exit-node-allow-lan-access=true"
        else
            lan_opt="--exit-node-allow-lan-access=false"
        fi
        ts_cli set --exit-node="$node" $lan_opt 2>&1
    fi
    echo "OK"
}

cmd_save_advertise() {
    exit_en="$1"
    routes_en="$2"
    routes_val="$3"

    set_config_val "advertise_exit_node" "$exit_en"
    set_config_val "advertise_routes_enabled" "$routes_en"
    set_config_val "advertise_routes" "$routes_val"

    adv_routes_param=""
    if [ "$routes_en" = "true" ] && [ -n "$routes_val" ]; then
        adv_routes_param="--advertise-routes=$routes_val"
    else
        adv_routes_param="--advertise-routes="
    fi

    ts_cli set --advertise-exit-node="$exit_en" $adv_routes_param 2>&1
    echo "OK"
}

cmd_detect_subnets() {
    wifi_sub=""
    wifi_ip=$(ip -4 -o addr show wlan0 2>/dev/null | awk '{print $4}')
    if [ -n "$wifi_ip" ]; then
        ip_addr=$(echo "$wifi_ip" | cut -d/ -f1)
        prefix=$(echo "$wifi_ip" | cut -d/ -f2)
        base_sub=$(echo "$ip_addr" | awk -F. '{print $1"."$2"."$3".0"}')
        wifi_sub="${base_sub}/${prefix}"
    fi

    if [ -z "$wifi_sub" ]; then
        def_if=$(ip route show 2>/dev/null | grep 'default via' | awk '{print $5}' | head -n 1)
        if [ -n "$def_if" ]; then
            dev_ip=$(ip -4 -o addr show "$def_if" 2>/dev/null | awk '{print $4}')
            if [ -n "$dev_ip" ]; then
                ip_addr=$(echo "$dev_ip" | cut -d/ -f1)
                prefix=$(echo "$dev_ip" | cut -d/ -f2)
                base_sub=$(echo "$ip_addr" | awk -F. '{print $1"."$2"."$3".0"}')
                wifi_sub="${base_sub}/${prefix}"
            fi
        fi
    fi

    if [ -z "$wifi_sub" ]; then
        wifi_sub="192.168.2.0/24"
    fi
    echo "{\"subnets\": \"$wifi_sub\"}"
}

cmd_login_key() {
    key="$1"
    if [ -z "$key" ]; then
        echo "Error: Key required"
        return 1
    fi
    server=$(get_config_val "login_server")
    server_opt=""
    if [ -n "$server" ]; then
        server_opt="--login-server=$server"
    fi
    ts_cli up --auth-key="$key" $server_opt --accept-dns=false --reset 2>&1
    echo "OK"
}

cmd_login_url() {
    server=$(get_config_val "login_server")
    server_opt=""
    if [ -n "$server" ]; then
        server_opt="--login-server=$server"
    fi
    nohup "$CLI_BIN" --socket="$SOCKET_FILE" login $server_opt >/dev/null 2>&1 &

    login_url=""
    count=0
    while [ $count -lt 25 ]; do
        sleep 0.2
        count=$((count + 1))
        login_url=$(ts_cli status --json 2>/dev/null | grep -o '"AuthURL"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4)
        if [ -n "$login_url" ]; then
            break
        fi
        if [ -f "$LOG_FILE" ]; then
            login_url=$(grep -o 'AuthURL is https://[^ ]*' "$LOG_FILE" 2>/dev/null | tail -n 1 | awk '{print $3}')
            if [ -n "$login_url" ]; then
                break
            fi
        fi
    done

    echo "{\"url\": \"$login_url\"}"
}

cmd_open_url() {
    url="$1"
    if [ -n "$url" ]; then
        am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1 &
    fi
    echo "OK"
}

cmd_sync_auth() {
    ts_cli up --accept-dns=false --reset 2>&1 &
    echo "OK"
}

cmd_logout() {
    ts_cli logout 2>&1
    echo "OK"
}

cmd_set_hostname() {
    name="$1"
    set_config_val "hostname" "$name"
    dns_safe_name=$(echo "$name" | tr ' ' '-' | tr -cd 'a-zA-Z0-9-')
    [ -z "$dns_safe_name" ] && dns_safe_name="$name"
    if [ -S "$SOCKET_FILE" ]; then
        ts_cli set --hostname="$dns_safe_name" >/dev/null 2>&1 || true
    fi
    echo "OK"
}

cmd_logs() {
    if [ -f "$LOG_FILE" ]; then
        tail -n 80 "$LOG_FILE"
    else
        echo "暂无运行日志"
    fi
}

cmd_clear_logs() {
    if [ -f "$LOG_FILE" ]; then
        : > "$LOG_FILE"
    fi
    echo "OK"
}

cmd_ping() {
    target="$1"
    if [ -z "$target" ]; then
        echo "未指定目标节点"
        return 0
    fi

    out=$(ts_cli ping --c=1 --timeout=3s "$target" 2>&1)
    if echo "$out" | grep -q "pong"; then
        echo "$out"
        return 0
    fi

    # 兜底 ICMP ping
    if echo "$target" | grep -q ":"; then
        icmp_out=$(ping6 -c 1 -W 2 "$target" 2>&1 || ping -6 -c 1 -W 2 "$target" 2>&1 || true)
    else
        icmp_out=$(ping -c 1 -W 2 "$target" 2>&1 || true)
    fi

    if echo "$icmp_out" | grep -q -E "rtt|round-trip"; then
        echo "$icmp_out"
    elif [ -n "$out" ]; then
        echo "$out"
    else
        echo "$icmp_out"
    fi
    return 0
}

cmd_check_update() {
    mod_ver=$(grep "^version=" "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)
    current="${mod_ver:-v1.102.4}"
    current_clean=$(echo "$current" | sed 's/^v//')
    latest=""
    if which curl >/dev/null 2>&1; then
        latest=$(curl -sL --connect-timeout 6 https://pkgs.tailscale.com/stable/ | grep -o 'tailscale_[0-9\.]*_arm64\.tgz' | head -n 1 | sed 's/tailscale_//;s/_arm64.tgz//')
    fi
    [ -z "$latest" ] && latest="$current_clean"
    set_config_val "latest_version" "v$latest"
    echo "{\"current\": \"$current_clean\", \"latest\": \"$latest\"}"
}

cmd_do_update() {
    if [ -f "$MODDIR/scripts/update.sh" ]; then
        sh "$MODDIR/scripts/update.sh" update 2>&1
    else
        echo "Error: update.sh not found"
    fi
}

cmd_set_auto_update() {
    en="$1"
    interval="$2"
    set_config_val "auto_update" "$en"
    [ -n "$interval" ] && set_config_val "update_interval" "$interval"
    echo "OK"
}

CMD="$1"
shift 2>/dev/null

case "$CMD" in
    status)
        cmd_status
        ;;
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_restart
        ;;
    save_config)
        cmd_save_config "$@"
        ;;
    set_exit_node_allow_lan)
        cmd_set_exit_node_allow_lan "$@"
        ;;
    set_exit_node)
        cmd_set_exit_node "$@"
        ;;
    save_advertise)
        cmd_save_advertise "$@"
        ;;
    detect_subnets)
        cmd_detect_subnets
        ;;
    login_key)
        cmd_login_key "$@"
        ;;
    login_url)
        cmd_login_url
        ;;
    open_url)
        cmd_open_url "$@"
        ;;
    sync_auth)
        cmd_sync_auth
        ;;
    logout)
        cmd_logout
        ;;
    set_hostname)
        cmd_set_hostname "$@"
        ;;
    logs)
        cmd_logs
        ;;
    clear_logs)
        cmd_clear_logs
        ;;
    ping)
        cmd_ping "$@"
        ;;
    check_update)
        cmd_check_update
        ;;
    do_update)
        cmd_do_update
        ;;
    set_auto_update)
        cmd_set_auto_update "$@"
        ;;
    *)
        echo "Usage: $0 {status|start|stop|restart|save_config|set_exit_node_allow_lan|set_exit_node|save_advertise|detect_subnets|login_key|login_url|open_url|sync_auth|logout|set_hostname|logs|clear_logs|ping|check_update|do_update|set_auto_update}"
        exit 1
        ;;
esac

exit 0

