#!/bin/zsh
set -o pipefail

cd "$(dirname "$0")"
mkdir -p data

BIN="bin/miband-hr-mac"
if [[ ! -x "$BIN" ]]; then
  echo "未找到 $BIN，正在构建……"
  ./build.sh || exit 1
fi

EXTRA=()
if [[ "$1" == "all" ]]; then
  EXTRA=(--dump-all)
  shift
fi

LOG="data/diagnose-$(date '+%Y%m%d-%H%M%S').log"
echo "诊断模式：打印附近 BLE 广播的原始字节。"
echo "手环开启运动模式后，重点看 company=0x0157 的 payload 与 b3。"
echo "日志：$(pwd)/$LOG"
echo "退出：Ctrl-C"
echo

"$BIN" --mode dump "${EXTRA[@]}" "$@" 2>&1 | tee "$LOG"
