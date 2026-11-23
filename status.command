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
CONTROL_PORT=$((PORT + 1))

WEB_JSON=$(curl -s --max-time 2 "http://127.0.0.1:$CONTROL_PORT/api/service" 2>/dev/null)
case "$WEB_JSON" in
  *'"web":true'*)  WEB_STATE=true ;;
  *'"web":false'*) WEB_STATE=false ;;
  *)               WEB_STATE=unknown ;;
esac
case "$WEB_STATE" in
  true)  WEB_LABEL="开启（http://127.0.0.1:$PORT/）" ;;
  false) WEB_LABEL="关闭" ;;
  *)     WEB_LABEL="未知" ;;
esac

echo "状态：运行中（PID $PID，控制端口 $CONTROL_PORT）"
echo "网页服务：$WEB_LABEL"
if pgrep -f "MibandFloat.app/Contents/MacOS/MibandFloat" >/dev/null 2>&1; then
  echo "浮窗：运行中"
else
  echo "浮窗：未运行"
fi
CONTROL_PORT="$CONTROL_PORT" python3 - <<'PY'
import json
import os
import urllib.request

port = os.environ.get("CONTROL_PORT", "3031")
try:
    # /api/events 是 SSE 长连接，只读第一帧后立刻断开。
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/events", timeout=2) as response:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if line.startswith("data:"):
                data = json.loads(line[5:].strip())
                break
        else:
            print("未收到状态数据")
            raise SystemExit(0)
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
