#!/bin/zsh
set -o pipefail

cd "$(dirname "$0")"
mkdir -p data

BIN="bin/miband-hr-mac"
if [[ ! -x "$BIN" ]]; then
  echo "未找到 $BIN，正在构建……"
  ./build.sh || exit 1
fi

echo "===== $(date '+%Y-%m-%d %H:%M:%S') =====" >> data/app.log
echo "面板：http://127.0.0.1:3030/"
echo "OBS ：http://127.0.0.1:3030/overlay"
echo "退出：Ctrl-C"
echo

"$BIN" "$@" 2>&1 | tee -a data/app.log

echo
echo "应用已退出。日志：$(pwd)/data/app.log"
