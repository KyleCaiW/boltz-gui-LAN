#!/usr/bin/env sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BOLTZ_CACHE=${BOLTZ_CACHE:-${ROOT%/*}/boltz-cache}
export BOLTZ_CACHE

# MSA server override (optional). Default: https://api.colabfold.com
# Uncomment and edit to use your own ColabFold-compatible server.
#   BOLTZ_MSA_SERVER_URL=https://msa.example.org
#   BOLTZ_MSA_PAIRING_STRATEGY=greedy
for _msa_var in BOLTZ_MSA_SERVER_URL BOLTZ_MSA_PAIRING_STRATEGY; do
    eval "_msa_val=\${$_msa_var:-}"
    if [ -n "$_msa_val" ]; then
        eval "export $_msa_var"
    fi
done

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

mkdir -p "$LOG_DIR" "$PID_DIR" "$BOLTZ_CACHE"

say() {
    printf '%s\n' "$*"
}

die() {
    say "Error: $*" >&2
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

service_alive() {
    is_alive "$1" || kill -0 -"$1" 2>/dev/null
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

ensure_tools() {
    command -v uv >/dev/null 2>&1 || die "uv not found; please install uv first"
    command -v npm >/dev/null 2>&1 || die "npm not found; please install Node.js first"
    command -v curl >/dev/null 2>&1 || die "curl not found; cannot check service status"
    command -v setsid >/dev/null 2>&1 || die "setsid not found; cannot manage service processes reliably"
}

ensure_deps() {
    if [ ! -x "$BACKEND_DIR/.venv/bin/python" ]; then
        say "Backend dependencies missing, running uv sync ..."
        (cd "$BACKEND_DIR" && uv sync) || die "Failed to install backend dependencies"
    fi

    if [ ! -d "$FRONTEND_DIR/node_modules" ]; then
        say "Frontend dependencies missing, running npm install ..."
        (cd "$FRONTEND_DIR" && npm install) || die "Failed to install frontend dependencies"
    fi
}

install_all() {
    ensure_tools
    say "Installing backend dependencies..."
    (cd "$BACKEND_DIR" && uv sync) || die "Failed to install backend dependencies"
    say "Installing frontend dependencies..."
    (cd "$FRONTEND_DIR" && npm install) || die "Failed to install frontend dependencies"
    say "Dependencies installed"
}

spawn() {
    workdir=$1
    logfile=$2
    shift 2

    : > "$logfile"
    (cd "$workdir" && exec setsid "$@" </dev/null >>"$logfile" 2>&1) &
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
            say "$name failed to start. Recent log:" >&2
            tail -n 40 "$logfile" >&2 2>/dev/null || true
            return 1
        fi
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
            return 0
        fi
        count=$((count + 1))
        sleep 1
    done

    say "$name start timed out. Recent log:" >&2
    tail -n 40 "$logfile" >&2 2>/dev/null || true
    return 1
}

stop_service() {
    name=$1
    pidfile=$2
    service_pid=$(read_pid "$pidfile")

    if [ -z "$service_pid" ]; then
        say "$name is not running"
        return 0
    fi

    if ! is_alive "$service_pid"; then
        rm -f "$pidfile"
        say "$name is not running (removed stale PID file)"
        return 0
    fi

    say "Stopping $name (PID $service_pid) ..."
    kill -TERM -"$service_pid" 2>/dev/null || kill -TERM "$service_pid" 2>/dev/null || true

    count=0
    while service_alive "$service_pid" && [ "$count" -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done

    if service_alive "$service_pid"; then
        kill -KILL -"$service_pid" 2>/dev/null || kill -KILL "$service_pid" 2>/dev/null || true
        sleep 1
    fi

    rm -f "$pidfile"
    if service_alive "$service_pid"; then
        say "Error: $name could not be stopped (PID $service_pid)" >&2
        return 1
    else
        say "$name stopped"
        return 0
    fi
}

start_backend() {
    pid=$(read_pid "$BACKEND_PID")
    if is_alive "$pid"; then
        say "Backend already running (PID $pid)"
        return 0
    fi
    rm -f "$BACKEND_PID"

    if port_in_use "$BACKEND_PORT"; then
        die "Port $BACKEND_PORT is already in use; stop the process using it first"
    fi

    say "Starting backend..."
    spawn "$BACKEND_DIR" "$BACKEND_LOG" uv run run_server.py
    printf '%s\n' "$SPAWNED_PID" > "$BACKEND_PID"

    if wait_for_service "Backend" "http://127.0.0.1:$BACKEND_PORT/health" "$SPAWNED_PID" "$BACKEND_LOG"; then
        say "Backend started (PID $SPAWNED_PID)"
        return 0
    fi

    stop_service "Backend" "$BACKEND_PID"
    return 1
}

start_frontend() {
    pid=$(read_pid "$FRONTEND_PID")
    if is_alive "$pid"; then
        say "Frontend already running (PID $pid)"
        return 0
    fi
    rm -f "$FRONTEND_PID"

    if port_in_use "$FRONTEND_PORT"; then
        die "Port $FRONTEND_PORT is already in use; stop the process using it first"
    fi

    say "Starting frontend..."
    spawn "$FRONTEND_DIR" "$FRONTEND_LOG" npm run dev
    printf '%s\n' "$SPAWNED_PID" > "$FRONTEND_PID"

    if wait_for_service "Frontend" "http://127.0.0.1:$FRONTEND_PORT/" "$SPAWNED_PID" "$FRONTEND_LOG"; then
        say "Frontend started (PID $SPAWNED_PID)"
        return 0
    fi

    stop_service "Frontend" "$FRONTEND_PID"
    return 1
}

print_access() {
    ip=$(lan_ip)
    say ""
    say "Local:      http://localhost:$FRONTEND_PORT"
    if [ -n "$ip" ]; then
        say "LAN:        http://$ip:$FRONTEND_PORT"
    fi
    say "Backend:    http://localhost:$BACKEND_PORT"
    say "MSA server: ${BOLTZ_MSA_SERVER_URL:-https://api.colabfold.com (default)}"
    say "Boltz cache: $BOLTZ_CACHE"
    say "Log dir:    $LOG_DIR"
}

start_all() {
    ensure_tools
    ensure_deps
    start_backend || exit 1
    if ! start_frontend; then
        stop_service "Backend" "$BACKEND_PID"
        exit 1
    fi
    print_access
}

stop_all() {
    stop_ok=0
    stop_service "Frontend" "$FRONTEND_PID" || stop_ok=1
    stop_service "Backend" "$BACKEND_PID" || stop_ok=1
    return "$stop_ok"
}

status_all() {
    backend_pid=$(read_pid "$BACKEND_PID")
    frontend_pid=$(read_pid "$FRONTEND_PID")

    if is_alive "$backend_pid"; then
        say "Backend:  running (PID $backend_pid, port $BACKEND_PORT)"
    else
        rm -f "$BACKEND_PID"
        say "Backend:  not running"
    fi

    if is_alive "$frontend_pid"; then
        say "Frontend: running (PID $frontend_pid, port $FRONTEND_PORT)"
    else
        rm -f "$FRONTEND_PID"
        say "Frontend: not running"
    fi

    say "MSA server: ${BOLTZ_MSA_SERVER_URL:-https://api.colabfold.com (default)}"
}

usage() {
    cat <<EOF
Usage: sh run.sh [command]

  start     start backend and frontend (default)
  stop      stop backend and frontend
  restart   restart backend and frontend
  status    show service status
  install   install backend and frontend dependencies

Log dir: $LOG_DIR
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
        if ! stop_all; then
            die "Services did not stop cleanly; restart cancelled"
        fi
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
