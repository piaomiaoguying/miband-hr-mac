#!/bin/zsh
set -e

cd "$(dirname "$0")"

PIDFILE="data/app.pid"
PID=""

if [[ -f "$PIDFILE" ]]; then
  PID=$(cat "$PIDFILE" 2>/dev/null)
fi

# PID 文件可能过期：优先校验进程真实存在，失效时按监听端口兜底查找。
if [[ -z "$PID" ]] || ! kill -0 "$PID" 2>/dev/null; then
  PID=$(lsof -tiTCP:3030 -sTCP:LISTEN 2>/dev/null | head -n 1)
fi

if [[ -z "$PID" ]]; then
  echo "状态：未运行"
  if pgrep -f "MibandFloat.app/Contents/MacOS/MibandFloat" >/dev/null 2>&1; then
    echo "浮窗：运行中（后台服务未运行）"
  fi
  sleep 1
  exit 0
fi

PORT=$(ps -p "$PID" -o command= 2>/dev/null | sed -n 's/.*--port \([0-9][0-9]*\).*/\1/p' | head -n 1)
PORT=${PORT:-3030}

echo "状态：运行中（PID $PID，端口 $PORT）"
if pgrep -f "MibandFloat.app/Contents/MacOS/MibandFloat" >/dev/null 2>&1; then
  echo "浮窗：运行中"
else
  echo "浮窗：未运行"
fi
PORT="$PORT" python3 - <<'PY'
import json
import os
import urllib.request

port = os.environ.get("PORT", "3030")
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/state", timeout=2) as response:
        data = json.load(response)
except Exception as error:
    print(f"无法读取 API：{error}")
    raise SystemExit(0)

age = data.get("last_valid_age_ms")
if age is None:
    age_text = "无数据"
elif age < 1500:
    age_text = "刚刚"
else:
    age_text = f"{round(age / 1000)} 秒前"

bpm = data.get("bpm")
print(f"设备：{data.get('device_name') or '--'}")
print(f"状态：{data.get('status_label') or '--'}")
print(f"心率：{bpm if bpm is not None else '--'} BPM（{age_text}）")
error = data.get("last_error")
if error:
    print(f"提示：{error}")
print(f"CSV ：{data.get('csv_path') or '--'}")
PY
sleep 1
