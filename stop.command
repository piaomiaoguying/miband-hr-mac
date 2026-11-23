#!/bin/zsh
set -e

cd "$(dirname "$0")"

PIDFILE="data/app.pid"

quit_float() {
  if pgrep -f "MibandFloat.app/Contents/MacOS/MibandFloat" >/dev/null 2>&1; then
    pkill -TERM -f "MibandFloat.app/Contents/MacOS/MibandFloat" 2>/dev/null || true
    for ((i = 0; i < 15; i++)); do
      if ! pgrep -f "MibandFloat.app/Contents/MacOS/MibandFloat" >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
    if pgrep -f "MibandFloat.app/Contents/MacOS/MibandFloat" >/dev/null 2>&1; then
      pkill -KILL -f "MibandFloat.app/Contents/MacOS/MibandFloat" 2>/dev/null || true
    fi
    echo "浮窗：已关闭"
  fi
}

PID=""
if [[ -f "$PIDFILE" ]]; then
  PID=$(cat "$PIDFILE")
fi

# PID 文件缺失或进程已退出时，按监听端口兜底查找。
if [[ -z "$PID" ]] || ! kill -0 "$PID" 2>/dev/null; then
  PID=$(lsof -tiTCP:3030 -sTCP:LISTEN 2>/dev/null | head -n 1)
fi

if [[ -z "$PID" ]]; then
  rm -f "$PIDFILE"
  echo "后台服务：未运行"
  quit_float
  sleep 1
  exit 0
fi

CMD=$(ps -p "$PID" -o command= 2>/dev/null || true)
if [[ "$CMD" != *miband-hr-mac* ]]; then
  echo "PID $PID 不是 miband-hr-mac，已取消：$CMD"
  sleep 1
  exit 1
fi

echo "正在停止（PID $PID）……"
kill "$PID" 2>/dev/null || true
for ((i = 0; i < 25; i++)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
if kill -0 "$PID" 2>/dev/null; then
  kill -9 "$PID" 2>/dev/null || true
fi
rm -f "$PIDFILE"
quit_float
echo "已停止。"
sleep 1
