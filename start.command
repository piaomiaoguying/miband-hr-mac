#!/bin/zsh
set -e

cd "$(dirname "$0")"
mkdir -p data

BIN="bin/miband-hr-mac"
PIDFILE="data/app.pid"
LOG="data/app.log"
PORT=3030
ARGS=("$@")

# 解析 --port，仅用于健康检查与打开面板；其他参数原样传给程序。
for ((i = 1; i <= ${#ARGS}; i++)); do
  if [[ "${ARGS[i]}" == "--port" && -n "${ARGS[i + 1]}" ]]; then
    PORT="${ARGS[i + 1]}"
  fi
done

open_panel() {
  if [[ -d "/Applications/Microsoft Edge.app" ]]; then
    open -a "Microsoft Edge" "$1"
  else
    open "$1"
  fi
}

if [[ ! -x "$BIN" ]]; then
  echo "未找到 $BIN，正在构建……"
  ./build.sh || exit 1
fi

if [[ -f "$PIDFILE" ]]; then
  PID=$(cat "$PIDFILE")
  CMD=$(ps -p "$PID" -o command= 2>/dev/null || true)
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null && [[ "$CMD" == *miband-hr-mac* ]]; then
    RUN_PORT=$(printf '%s\n' "$CMD" | sed -n 's/.*--port \([0-9][0-9]*\).*/\1/p' | head -n 1)
    PORT=${RUN_PORT:-$PORT}
    echo "已在运行（PID $PID）"
    if [[ -d "dist/MibandFloat.app" ]]; then
      open "dist/MibandFloat.app" --args --port "$PORT"
    else
      open_panel "http://127.0.0.1:$PORT/"
    fi
    sleep 1
    exit 0
  fi
  rm -f "$PIDFILE"
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "端口 $PORT 已被占用，未启动。可用 ./start.command --port 3031 换端口。"
  sleep 1
  exit 1
fi

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 启动 =====" >> "$LOG"
nohup "$BIN" --no-open "$@" >> "$LOG" 2>&1 &
PID=$!
echo "$PID" > "$PIDFILE"

READY=0
for ((i = 0; i < 50; i++)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.2
done

if [[ "$READY" != "1" ]]; then
  echo "启动失败，最近日志："
  tail -20 "$LOG"
  kill "$PID" 2>/dev/null || true
  rm -f "$PIDFILE"
  sleep 1
  exit 1
fi

if [[ -d "dist/MibandFloat.app" ]]; then
  open "dist/MibandFloat.app" --args --port "$PORT"
  echo "浮窗：已打开"
else
  echo "浮窗：未构建（可运行 ./build-float.sh），已改用网页面板"
  open_panel "http://127.0.0.1:$PORT/"
fi
echo "已启动（PID $PID）"
echo "面板：http://127.0.0.1:$PORT/"
echo "OBS ：http://127.0.0.1:$PORT/overlay"
echo "停止：双击 stop.command"
sleep 1
