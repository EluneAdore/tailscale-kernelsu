#!/system/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODDIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$MODDIR/data"
mkdir -p "$DATA_DIR"

PID_FILE="$DATA_DIR/daemon.pid"
STOP_FILE="$DATA_DIR/manual_stopped"
LOG_FILE="$DATA_DIR/tailscaled.log"

# 记录当前看门狗守护进程 PID
echo $$ > "$PID_FILE"

cleanup() {
    rm -f "$PID_FILE" 2>/dev/null
    exit 0
}
trap cleanup INT TERM EXIT

while true; do
    # 如果用户主动停止了服务，看门狗退出
    if [ -f "$STOP_FILE" ]; then
        cleanup
    fi

    # 检测 tailscaled 主进程是否存活
    ts_pids=$(pgrep -f "tailscaled" 2>/dev/null)
    if [ -z "$ts_pids" ]; then
        echo "[$(date '+%Y/%m/%d %H:%M:%S')] [Watchdog] tailscaled core process exited, restarting..." >> "$LOG_FILE"
        sh "$MODDIR/scripts/control.sh" start >/dev/null 2>&1
    fi

    sleep 5
done

