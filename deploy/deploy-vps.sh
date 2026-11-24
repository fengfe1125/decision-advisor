#!/usr/bin/env zsh
set -euo pipefail

# One-click deploy of the pure API + Remote MCP backend onto murmur-new-vps.
# Usage:
#   ./deploy/deploy-vps.sh [--sync-vault]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VPS_HOST="${VPS_HOST:-murmur-new-vps}"
REMOTE_DIR="/opt/decision-advisor"
LOCAL_VAULT="${DECISION_VAULT_PATH:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/决策}"
SYNC_VAULT=false

for arg in "$@"; do
  if [[ "$arg" == "--sync-vault" ]]; then
    SYNC_VAULT=true
  fi
done

echo "=== 0. Preflight: deploy only merged, clean main ==="
REPO_ROOT="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel)"
DEPLOY_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
DEPLOY_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [[ "${ALLOW_UNMERGED_DEPLOY:-0}" != "1" ]]; then
  if [[ "$DEPLOY_BRANCH" != "main" ]]; then
    echo "error: 只能从 main 部署（当前 $DEPLOY_BRANCH）。临时绕过：ALLOW_UNMERGED_DEPLOY=1" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- "$PROJECT_DIR")" ]]; then
    echo "error: $PROJECT_DIR 有未提交改动，先提交并合并后再部署。" >&2
    exit 1
  fi
  git -C "$REPO_ROOT" fetch --quiet origin main
  if [[ "$DEPLOY_COMMIT" != "$(git -C "$REPO_ROOT" rev-parse origin/main)" ]]; then
    echo "error: 本地 main 与 origin/main 不一致，先 git pull --ff-only origin main。" >&2
    exit 1
  fi
fi
echo "Deploying ${DEPLOY_BRANCH}@${DEPLOY_COMMIT:0:7}"

echo "=== 1. Ensuring swap & directories on ${VPS_HOST} ==="
ssh "$VPS_HOST" 'bash -s' <<'EOF'
set -euo pipefail
mkdir -p /opt/decision-advisor/data/vault /opt/decision-advisor/data/fastembed_cache

# Add 2G swapfile if no swap exists (protects 2GB RAM VPS during local BGE ONNX inference)
if ! swapon --show | grep -q '/'; then
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=20 >/dev/null || true
fi

# Snapshot the SQLite state DB before touching code; keep the newest 5 snapshots.
BACKUP_ROOT=/opt/decision-advisor/backups
if [[ -f /opt/decision-advisor/data/advisor_state.db ]]; then
  SNAP="$BACKUP_ROOT/pre-deploy-$(date -u +%Y%m%d-%H%M%S)"
  mkdir -p "$SNAP"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 /opt/decision-advisor/data/advisor_state.db ".backup '$SNAP/advisor_state.db'"
  else
    cp -p /opt/decision-advisor/data/advisor_state.db "$SNAP/advisor_state.db"
  fi
  ls -1dt "$BACKUP_ROOT"/pre-deploy-* 2>/dev/null | tail -n +6 | xargs -r rm -rf
fi

if ! command -v git >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq git sqlite3
fi

if ! command -v uv >/dev/null 2>&1 && [[ ! -x /root/.local/bin/uv ]]; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
EOF

echo "=== 2. Syncing pure API backend code to ${VPS_HOST}:${REMOTE_DIR} ==="
rsync -az --delete \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude '.DS_Store' \
  "$PROJECT_DIR/app/" "${VPS_HOST}:${REMOTE_DIR}/app/"

scp -q \
  "$PROJECT_DIR/pyproject.toml" \
  "$PROJECT_DIR/uv.lock" \
  "$PROJECT_DIR/config.example.json" \
  "${VPS_HOST}:${REMOTE_DIR}/"

scp -q \
  "$PROJECT_DIR/deploy/decision-advisor.service" \
  "${VPS_HOST}:/etc/systemd/system/decision-advisor.service"

if [[ "$SYNC_VAULT" == "true" ]]; then
  echo "=== 3. Syncing local iCloud vault & config to VPS data directory ==="
  if [[ -d "$LOCAL_VAULT" ]]; then
    rsync -az --exclude '.DS_Store' --exclude '.git' \
      "$LOCAL_VAULT/" "${VPS_HOST}:${REMOTE_DIR}/data/vault/"
  fi
  if [[ -f "$PROJECT_DIR/config.local.json" ]]; then
    python3 - "$PROJECT_DIR/config.local.json" <<'PYEOF' | ssh "$VPS_HOST" "cat > ${REMOTE_DIR}/data/config.local.json && chmod 600 ${REMOTE_DIR}/data/config.local.json"
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
cfg["vault_path"] = "/opt/decision-advisor/data/vault"
if not cfg.get("public_base_url"):
    cfg["public_base_url"] = "https://decision.sakuramu.edu.kg"
print(json.dumps(cfg, ensure_ascii=False, indent=2))
PYEOF
  fi
fi

echo "=== 4. Installing Python dependencies & restarting systemd service on ${VPS_HOST} ==="
ssh "$VPS_HOST" 'bash -s' <<'EOF'
set -euo pipefail
export PATH="/root/.local/bin:/usr/local/bin:/usr/bin:/bin"
cd /opt/decision-advisor
rm -rf /opt/decision-advisor/app/__pycache__
uv sync --no-dev
systemctl daemon-reload
systemctl enable decision-advisor.service
systemctl restart decision-advisor.service

for i in $(seq 1 25); do
  if curl -fsS http://127.0.0.1:8789/ >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

systemctl --no-pager --full status decision-advisor.service | head -n 18
echo ""
echo "Local VPS check:"
curl -sS http://127.0.0.1:8789/
echo ""
EOF

printf 'commit=%s\nbranch=%s\ndeployed_at=%s\n' "$DEPLOY_COMMIT" "$DEPLOY_BRANCH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | ssh "$VPS_HOST" "cat > ${REMOTE_DIR}/DEPLOYED_COMMIT"

echo "=== 5. Public HTTPS verification ==="
curl -sS https://decision.sakuramu.edu.kg/
echo ""
echo "=== VPS DEPLOY COMPLETE ==="
