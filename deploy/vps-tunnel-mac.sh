#!/usr/bin/env zsh
set -euo pipefail

# 用途：保持 iCloud「决策」目录和本机服务留在你自己的 Mac，
#       同时通过 VPS 的公网 HTTPS（Caddy 反代 127.0.0.1:8789）安全暴露给：
#       1) 你在外的手机浏览器（提问 + 查看记忆）
#       2) 官方 ChatGPT 网页版 & iPhone ChatGPT App（使用你的 ChatGPT Plus/Pro 订阅额度！）
#
# 使用方式：
#   ./deploy/vps-tunnel-mac.sh
#   （默认连接 ~/.ssh/config 中的 murmur-new-vps，也可覆盖 VPS_HOST=root@其他IP）

VPS_HOST="${VPS_HOST:-murmur-new-vps}"

LOCAL_PORT="${ADVISOR_PORT:-8789}"
REMOTE_PORT="${VPS_REMOTE_PORT:-8789}"

echo "正在建立加密反向隧道：VPS 127.0.0.1:${REMOTE_PORT} -> 本机 Mac 127.0.0.1:${LOCAL_PORT}"
echo "提示：请先确保本机已运行 ./start.sh，且在网页「设置」中已设置访问密码和公网 HTTPS 域名。"
echo ""

exec ssh -N \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -R "127.0.0.1:${REMOTE_PORT}:127.0.0.1:${LOCAL_PORT}" \
  "$VPS_HOST"
