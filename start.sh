#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

HOST="${ADVISOR_HOST:-0.0.0.0}"
PORT="${ADVISOR_PORT:-8789}"

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"

echo "============================================================"
echo "  个人成长决策顾问与记忆库 · 纯 API 调试后端（v$(grep -m1 "^APP_VERSION" "$SCRIPT_DIR/app/config.py" | cut -d\" -f2)）"
echo "============================================================"
echo "  说明：网页版已下线（已抽离至 demo-mvp/），正式使用请直接打开："
echo "    - macOS 原生 App：macos/dist/成长决策顾问.app（内置后端 + 直连 VPS）"
echo "    - VPS 24/7 远程后端：https://decision.sakuramu.edu.kg"
echo "  本机调试 API : http://127.0.0.1:${PORT}/api/health"
if [[ -n "$LAN_IP" ]]; then
  echo "  局域网 API   : http://${LAN_IP}:${PORT}/api/health"
fi
if [[ -n "$TAILSCALE_IP" ]]; then
  echo "  Tailscale API: http://${TAILSCALE_IP}:${PORT}/api/health"
fi
echo "============================================================"
echo ""

exec uv run uvicorn app.main:app --host "$HOST" --port "$PORT"
