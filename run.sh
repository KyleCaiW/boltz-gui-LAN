#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BACKEND_DIR="$ROOT/backend"
FRONTEND_DIR="$ROOT/frontend"
LOG_DIR="$ROOT/logs"
PID_DIR="$LOG_DIR/pids"
BACKEND_LOG="$LOG_DIR/backend.log"
FRONTEND_LOG="$LOG_DIR/frontend.log"
BACKEND_PID="$PID_DIR/backend.pid"
FRONTEND_PID="$PID_DIR/frontend.pid"
BACKEND_PORT=6969
FRONTEND_PORT=6868

mkdir -p "$LOG_DIR" "$PID_DIR"

say() {
    printf '%s\n' "$*"
}

die() {
    say "错误: $*" >&2
    exit 1
}

read_pid() {
    if [ -f "$1" ]; then
        tr -d ' \r\n' < "$1"
    fi
}

is_alive() {
    [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null \
            | awk -v port=":$1" '$4 ~ port"$" { found = 1 } END { exit !found }'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null \
            | awk -v port=":$1" '$4 ~ port"$" { found = 1 } END { exit !found }'
    else
        return 1
    fi
}

lan_ip() {
    if command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

children_of() {
    ps -eo pid=,ppid= 2>/dev/null \
        | awk -v parent="$1" '$2 == parent { print $1 }'
}

collect_tree() {
    pid=$1
    outfile=$2

    for child in $(children_of "$pid"); do
        collect_tree "$child" "$outfile"
    done
    printf '%s\n' "$pid" >> "$outfile"
}

ensure_tools() {
    command -v uv >/dev/null 2>&1 || die "未找到 uv，请先安装 uv"
    command -v npm >/dev/null 2>&1 || die "未找到 npm，请先安装 Node.js"
    command -v curl >/dev/null 2>&1 || die "未找到 curl，无法检查服务状态"
}

ensure_deps() {
    if [ ! -x "$BACKEND_DIR/.venv/bin/python" ]; then
        say "后端依赖未安装，正在执行 uv sync ..."
        (cd "$BACKEND_DIR" && uv sync) || die "后端依赖安装失败"
    fi

    if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
        say "前端依赖未安装，正在执行 npm install ..."
        (cd "$FRONTEND_DIR" && npm install) || die "前端依赖安装失败"
    fi
}

install_all() {
    ensure_tools
    say "安装后端依赖..."
    (cd "$BACKEND_DIR" && uv sync) || die "后端依赖安装失败"
    say "安装前端依赖..."
    (cd "$FRONTEND_DIR" && npm install) || die "前端依赖安装失败"
    say "依赖安装完成"
}

spawn() {
    workdir=$1
    logfile=$2
    shift 2

    : > "$logfile"
    if command -v nohup >/dev/null 2>&1; then
        (cd "$workdir" && exec nohup "$@" </dev/null >>"$logfile" 2>&1) &
    else
        (cd "$workdir" && exec "$@" </dev/null >>"$logfile" 2>&1) &
    fi
    SPAWNED_PID=$!
}

wait_for_service() {
    name=$1
    url=$2
    pid=$3
    logfile=$4
    attempts=${5:-120}
    count=0

    while [ "$count" -lt "$attempts" ]; do
        if ! is_alive "$pid"; then
            say "$name 启动失败，最近日志：" >&2
            tail -n 40 "$logfile" >&2 2>/dev/null || true
            return 1
        fi
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
            return 0
        fi
        count=$((count + 1))
        sleep 1
    done

    say "$name 启动超时，最近日志：" >&2
    tail -n 40 "$logfile" >&2 2>/dev/null || true
    return 1
}

stop_service() {
    name=$1
    pidfile=$2
    pid=$(read_pid "$pidfile")

    if [ -z "$pid" ]; then
        say "$name 未运行"
        return 0
    fi

    if ! is_alive "$pid"; then
        rm -f "$pidfile"
        say "$name 未运行（已清理残留 PID 文件）"
        return 0
    fi

    say "停止 $name (PID $pid) ..."
    treefile="$PID_DIR/$name.tree.$$"
    : > "$treefile"
    collect_tree "$pid" "$treefile"

    while IFS= read -r child; do
        [ -n "$child" ] && kill "$child" 2>/dev/null || true
    done < "$treefile"

    sleep 1
    while IFS= read -r child; do
        if is_alive "$child"; then
            kill -9 "$child" 2>/dev/null || true
        fi
    done < "$treefile"

    rm -f "$treefile"

    if is_alive "$pid"; then
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$pidfile"
    if is_alive "$pid"; then
        say "警告: $name 可能仍在运行 (PID $pid)" >&2
    else
        say "$name 已停止"
    fi
}

start_backend() {
    pid=$(read_pid "$BACKEND_PID")
    if is_alive "$pid"; then
        say "后端已在运行 (PID $pid)"
        return 0
    fi
    rm -f "$BACKEND_PID"

    if port_in_use "$BACKEND_PORT"; then
        die "端口 $BACKEND_PORT 已被占用，请先停止占用该端口的程序"
    fi

    say "启动后端..."
    spawn "$BACKEND_DIR" "$BACKEND_LOG" uv run run_server.py
    printf '%s\n' "$SPAWNED_PID" > "$BACKEND_PID"

    if wait_for_service "后端" "http://127.0.0.1:$BACKEND_PORT/health" "$SPAWNED_PID" "$BACKEND_LOG"; then
        say "后端已启动 (PID $SPAWNED_PID)"
        return 0
    fi

    stop_service "后端" "$BACKEND_PID"
    return 1
}

start_frontend() {
    pid=$(read_pid "$FRONTEND_PID")
    if is_alive "$pid"; then
        say "前端已在运行 (PID $pid)"
        return 0
    fi
    rm -f "$FRONTEND_PID"

    if port_in_use "$FRONTEND_PORT"; then
        die "端口 $FRONTEND_PORT 已被占用，请先停止占用该端口的程序"
    fi

    say "启动前端..."
    spawn "$FRONTEND_DIR" "$FRONTEND_LOG" npm run dev
    printf '%s\n' "$SPAWNED_PID" > "$FRONTEND_PID"

    if wait_for_service "前端" "http://127.0.0.1:$FRONTEND_PORT/" "$SPAWNED_PID" "$FRONTEND_LOG"; then
        say "前端已启动 (PID $SPAWNED_PID)"
        return 0
    fi

    stop_service "前端" "$FRONTEND_PID"
    return 1
}

print_access() {
    ip=$(lan_ip)
    say ""
    say "本机访问:   http://localhost:$FRONTEND_PORT"
    if [ -n "$ip" ]; then
        say "局域网访问: http://$ip:$FRONTEND_PORT"
    fi
    say "后端 API:   http://localhost:$BACKEND_PORT"
    say "日志目录:   $LOG_DIR"
}

start_all() {
    ensure_tools
    ensure_deps
    start_backend || exit 1
    if ! start_frontend; then
        stop_service "后端" "$BACKEND_PID"
        exit 1
    fi
    print_access
}

stop_all() {
    stop_service "前端" "$FRONTEND_PID"
    stop_service "后端" "$BACKEND_PID"
}

status_all() {
    backend_pid=$(read_pid "$BACKEND_PID")
    frontend_pid=$(read_pid "$FRONTEND_PID")

    if is_alive "$backend_pid"; then
        say "后端: 运行中 (PID $backend_pid, 端口 $BACKEND_PORT)"
    else
        rm -f "$BACKEND_PID"
        say "后端: 未运行"
    fi

    if is_alive "$frontend_pid"; then
        say "前端: 运行中 (PID $frontend_pid, 端口 $FRONTEND_PORT)"
    else
        rm -f "$FRONTEND_PID"
        say "前端: 未运行"
    fi
}

usage() {
    cat <<EOF
用法: sh run.sh [命令]

  start     启动前后端（默认）
  stop      关闭前后端
  restart   重启前后端
  status    查看运行状态
  install   安装前后端依赖

日志目录: $LOG_DIR
EOF
}

command=${1:-start}
case "$command" in
    start)
        start_all
        ;;
    stop)
        stop_all
        ;;
    restart)
        stop_all
        sleep 1
        start_all
        ;;
    status)
        status_all
        ;;
    install)
        install_all
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
