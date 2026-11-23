#!/bin/zsh
set -e

cd "$(dirname "$0")"

if ! command -v cargo >/dev/null 2>&1; then
  if [[ -f "$HOME/.cargo/env" ]]; then
    source "$HOME/.cargo/env"
  fi
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "未找到 Rust 工具链。"
  echo "先安装：curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
  echo "安装后重新运行本脚本。"
  exit 1
fi

# 国内网络访问 crates.io 较慢时，可先设置代理：
# export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890

cargo build --release
mkdir -p bin
rm -f bin/miband-hr-mac
cp target/release/miband-hr-mac bin/miband-hr-mac
chmod +x bin/miband-hr-mac
echo "已生成 bin/miband-hr-mac"
