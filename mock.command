#!/bin/zsh
set -o pipefail

cd "$(dirname "$0")"
mkdir -p data/mock

BIN="bin/miband-hr-mac"
if [[ ! -x "$BIN" ]]; then
  echo "未找到 $BIN，正在构建……"
  ./build.sh || exit 1
fi

PORT="${PORT:-3031}"
echo "模拟模式：不访问蓝牙，用生成的数据预览面板。"
echo "面板：http://127.0.0.1:${PORT}/"
echo "退出：Ctrl-C"
echo

"$BIN" --mode mock --port "$PORT" "$@"
