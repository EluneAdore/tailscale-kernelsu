#!/system/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODDIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# 1. 修复 Android DNS 解析 (/etc/resolv.conf)
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

# 2. 修复 Android 路由与 TUN 接口
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

get_daemon_pids() {
    pgrep -f "$DAEMON_BIN" 2>/dev/null || pgrep -f "tailscaled" 2>/dev/null
}

action_status() {
    pids=$(get_daemon_pids | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    running="false"
    if [ -n "$pids" ]; then
        running="true"
    fi

    # 主程序 PID 与 守护进程 PID 独立获取
    main_pid=$(echo "$pids" | awk '{print $1}')
    daemon_pid=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
    if [ -n "$daemon_pid" ] && ! kill -0 "$daemon_pid" 2>/dev/null; then
        daemon_pid=""
    fi
    if [ -z "$daemon_pid" ]; then
        daemon_pid=$(pgrep -f "$MODDIR/scripts/watchdog.sh" 2>/dev/null | head -n 1)
    fi

    if [ "$running" = "true" ] && [ -z "$daemon_pid" ] && [ ! -f "$DATA_DIR/manual_stopped" ]; then
        start_watchdog
        daemon_pid=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
    fi

    # 获取虚拟网卡 IP
    tun_ip=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    [ -z "$tun_ip" ] && tun_ip=""

    # 尝试获取 tailscale 状态
    ts_json="{}"
    if [ "$running" = "true" ] && [ -S "$SOCKET_FILE" ]; then
        ts_json=$(ts_cli status --json 2>/dev/null)
        if [ -z "$ts_json" ]; then
            ts_json="{}"
        fi
    fi

    proxy=$(get_config_val "proxy")
    login_server=$(get_config_val "login_server")

    # 组合输出状态 JSON
    cat <<EOF
{
  "running": $running,
  "main_pid": "${main_pid:-}",
  "daemon_pid": "${daemon_pid:-}",
  "pids": "$pids",
  "tun_name": "tailscale0",
  "tun_ip": "$tun_ip",
  "data_dir": "$DATA_DIR",
  "proxy": "${proxy:-}",
  "login_server": "${login_server:-}",
  "status_json": $ts_json
}
EOF
}

action_start() {
    rm -f "$DATA_DIR/manual_stopped" 2>/dev/null
    pids=$(get_daemon_pids)
    if [ -n "$pids" ]; then
        echo "tailscaled is already running (PID: $pids)"
        start_watchdog
        action_status
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

    # 启动主程序守护进程
    echo "[$(date '+%Y/%m/%d %H:%M:%S')] Starting tailscaled native daemon..." >> "$LOG_FILE"
    nohup "$DAEMON_BIN" \
        --state="$STATE_FILE" \
        --socket="$SOCKET_FILE" \
        --tun=tailscale0 \
        --port=41641 \
        --statedir="$DATA_DIR" >> "$LOG_FILE" 2>&1 &

    # 等待 socket 创建
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

    # 应用防火墙与路由规则
    if [ -f "$MODDIR/scripts/iptables.sh" ]; then
        sh "$MODDIR/scripts/iptables.sh" apply
    fi

    # 彻底杜绝 Android 上 atomicWriteFile /etc/resolv.conf 只读报错
    accept_dns_val=$(get_config_val "accept_dns")
    if [ "$accept_dns_val" != "true" ] && [ -S "$SOCKET_FILE" ]; then
        ts_cli set --accept-dns=false >/dev/null 2>&1 || true
    fi

    echo "tailscaled started successfully."
    action_status
}

action_stop() {
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
    echo "tailscaled stopped."
    action_status
}

action_restart() {
    action_stop >/dev/null 2>&1
    sleep 1
    action_start
}

action_login_key() {
    auth_key="$1"
    if [ -z "$auth_key" ]; then
        echo '{"success": false, "error": "Auth key is required"}'
        return 1
    fi

    server=$(get_config_val "login_server")
    server_opt=""
    if [ -n "$server" ]; then
        server_opt="--login-server=$server"
    fi

    res=$(ts_cli up --auth-key="$auth_key" $server_opt --accept-dns=false --reset 2>&1)
    code=$?
    if [ $code -eq 0 ]; then
        echo "{\"success\": true, \"output\": $(echo "$res" | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/.*/"&"/')}"
    else
        echo "{\"success\": false, \"code\": $code, \"output\": $(echo "$res" | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/.*/"&"/')}"
    fi
}

action_login_url() {
    server=$(get_config_val "login_server")
    server_opt=""
    if [ -n "$server" ]; then
        server_opt="--login-server=$server"
    fi

    # 1. 后台非阻塞触发登录，绝不阻塞当前 shell
    nohup "$CLI_BIN" --socket="$SOCKET_FILE" login $server_opt >/dev/null 2>&1 &

    # 2. 轮询等待 tailscaled 守护进程返回 AuthURL (最多等待 4 秒)
    login_url=""
    count=0
    while [ $count -lt 20 ]; do
        sleep 0.2
        count=$((count + 1))
        # 优先从 status --json 提取
        login_url=$(ts_cli status --json 2>/dev/null | grep -o '"AuthURL"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 | cut -d'"' -f4)
        if [ -n "$login_url" ]; then
            break
        fi
        # 兜底从日志中提取
        if [ -f "$LOG_FILE" ]; then
            login_url=$(grep -o 'AuthURL is https://[^ ]*' "$LOG_FILE" 2>/dev/null | tail -n 1 | awk '{print $3}')
            if [ -n "$login_url" ]; then
                break
            fi
        fi
    done

    # 3. 如果获取成功，自动调用系统浏览器打开
    if [ -n "$login_url" ]; then
        am start -a android.intent.action.VIEW -d "$login_url" >/dev/null 2>&1 &
    fi

    echo "{\"success\": true, \"login_url\": \"$login_url\"}"
}

action_open_url() {
    target_url="$1"
    if [ -n "$target_url" ]; then
        am start -a android.intent.action.VIEW -d "$target_url" >/dev/null 2>&1 &
    fi
    echo '{"success": true}'
}

action_logout() {
    out=$(ts_cli logout 2>&1)
    echo "{\"success\": true, \"output\": \"$out\"}"
}

action_set_hostname() {
    new_name="$1"
    if [ -z "$new_name" ]; then
        echo '{"success": false, "error": "Hostname is required"}'
        return 1
    fi
    set_config_val "hostname" "$new_name"
    out=$(ts_cli set --hostname="$new_name" 2>&1)
    echo "{\"success\": true, \"output\": \"$out\"}"
}

action_set_proxy() {
    proxy="$1"
    set_config_val "proxy" "$proxy"
    echo "{\"success\": true, \"proxy\": \"$proxy\"}"
}

action_set_server() {
    server="$1"
    set_config_val "login_server" "$server"
    echo "{\"success\": true, \"login_server\": \"$server\"}"
}

action_set_routes() {
    enable="$1"
    if [ "$enable" = "1" ] || [ "$enable" = "true" ]; then
        val="true"
    else
        val="false"
    fi
    out=$(ts_cli set --accept-routes="$val" 2>&1)
    echo "{\"success\": true, \"accept_routes\": $val, \"output\": \"$out\"}"
}

action_set_dns() {
    enable="$1"
    if [ "$enable" = "1" ] || [ "$enable" = "true" ]; then
        val="true"
    else
        val="false"
    fi
    out=$(ts_cli set --accept-dns="$val" 2>&1)
    echo "{\"success\": true, \"accept_dns\": $val, \"output\": \"$out\"}"
}

action_set_exit_node() {
    node="$1"
    allow_lan="$2"
    lan_opt=""
    if [ "$allow_lan" = "1" ] || [ "$allow_lan" = "true" ]; then
        lan_opt="--exit-node-allow-lan-access=true"
    else
        lan_opt="--exit-node-allow-lan-access=false"
    fi

    if [ -z "$node" ]; then
        out=$(ts_cli set --exit-node="" 2>&1)
    else
        out=$(ts_cli set --exit-node="$node" $lan_opt 2>&1)
    fi
    echo "{\"success\": true, \"output\": \"$out\"}"
}

action_adv_exit_node() {
    enable="$1"
    if [ "$enable" = "1" ] || [ "$enable" = "true" ]; then
        val="true"
    else
        val="false"
    fi
    out=$(ts_cli set --advertise-exit-node="$val" 2>&1)
    echo "{\"success\": true, \"advertise_exit_node\": $val, \"output\": \"$out\"}"
}

action_adv_routes() {
    routes="$1"
    out=$(ts_cli set --advertise-routes="$routes" 2>&1)
    echo "{\"success\": true, \"advertise_routes\": \"$routes\", \"output\": \"$out\"}"
}

action_detect_subnet() {
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
    echo "{\"subnet\": \"$wifi_sub\"}"
}

action_get_logs() {
    lines="${1:-60}"
    if [ -f "$LOG_FILE" ]; then
        tail -n "$lines" "$LOG_FILE"
    else
        echo "(暂无运行日志)"
    fi
}

action_clear_logs() {
    > "$LOG_FILE"
    echo '{"success": true}'
}

action_get_peers() {
    if [ -S "$SOCKET_FILE" ]; then
        ts_cli status --json 2>/dev/null
    else
        echo '{"error": "Tailscale daemon is not running"}'
    fi
}

action_ping_peer() {
    target="$1"
    if [ -z "$target" ]; then
        echo '{"success": false, "error": "Target IP or hostname is required"}'
        return 1
    fi

    # 1. 尝试使用 tailscale ping (可精确测出直连或 DERP 中继)
    out=$(ts_cli ping --c=1 --timeout=3s "$target" 2>&1)
    code=$?

    if [ $code -eq 0 ] && echo "$out" | grep -q "pong"; then
        latency=$(echo "$out" | grep -o 'in [0-9\.]\+[mµn]*s' | head -n 1 | sed 's/in //')
        is_derp=$(echo "$out" | grep -i 'DERP')
        derp_node=$(echo "$out" | grep -o 'DERP([a-zA-Z0-9_-]\+)' | head -n 1)
        conn_type="直连"
        if [ -n "$is_derp" ]; then
            conn_type="中继 (${derp_node:-DERP})"
        fi
        echo "{\"success\": true, \"latency\": \"$latency\", \"type\": \"$conn_type\", \"raw\": $(echo "$out" | tr '\n' ' ' | sed 's/"/\\"/g' | sed 's/.*/"&"/')}"
        return 0
    fi

    # 2. 兜底使用系统 ping / ping6
    if echo "$target" | grep -q ":"; then
        sys_ping=$(ping6 -c 1 -W 2 "$target" 2>&1 || ping -6 -c 1 -W 2 "$target" 2>&1)
    else
        sys_ping=$(ping -c 1 -W 2 "$target" 2>&1)
    fi

    lat=$(echo "$sys_ping" | grep -o 'time=[0-9\.]\+[ ]*ms' | head -n 1 | cut -d= -f2)
    if [ -n "$lat" ]; then
        echo "{\"success\": true, \"latency\": \"$lat\", \"type\": \"ICMP 直连\", \"raw\": \"$sys_ping\"}"
    else
        echo "{\"success\": false, \"latency\": \"超时\", \"type\": \"不可达\", \"error\": \"节点未响应或超时\"}"
    fi
}

action_check_update() {
    latest=""
    if which curl >/dev/null 2>&1; then
        latest=$(curl -sL --connect-timeout 5 https://pkgs.tailscale.com/stable/ | grep -o 'tailscale_[0-9\.]*_arm64\.tgz' | head -n 1 | sed 's/tailscale_//;s/_arm64.tgz//')
    fi
    current="1.102.4"
    echo "{\"current\": \"$current\", \"latest\": \"${latest:-$current}\"}"
}

CMD="$1"
shift 2>/dev/null

case "$CMD" in
    status)
        action_status
        ;;
    start|start_boot)
        action_start
        ;;
    stop)
        action_stop
        ;;
    restart)
        action_restart
        ;;
    login_key)
        action_login_key "$@"
        ;;
    login_url)
        action_login_url "$@"
        ;;
    open_url)
        action_open_url "$@"
        ;;
    logout)
        action_logout
        ;;
    set_hostname)
        action_set_hostname "$@"
        ;;
    set_proxy)
        action_set_proxy "$@"
        ;;
    set_server)
        action_set_server "$@"
        ;;
    set_routes)
        action_set_routes "$@"
        ;;
    set_dns)
        action_set_dns "$@"
        ;;
    set_exit_node)
        action_set_exit_node "$@"
        ;;
    adv_exit_node)
        action_adv_exit_node "$@"
        ;;
    adv_routes)
        action_adv_routes "$@"
        ;;
    detect_subnet)
        action_detect_subnet
        ;;
    get_peers)
        action_get_peers
        ;;
    ping_peer)
        action_ping_peer "$@"
        ;;
    get_logs)
        action_get_logs "$@"
        ;;
    clear_logs)
        action_clear_logs
        ;;
    check_update)
        action_check_update
        ;;
    *)
        echo "Usage: $0 {status|start|stop|restart|login_key|login_url|logout|set_hostname|set_proxy|set_server|set_routes|set_dns|set_exit_node|adv_exit_node|adv_routes|detect_subnet|get_peers|get_logs|clear_logs|check_update}"
        exit 1
        ;;
esac

exit 0
