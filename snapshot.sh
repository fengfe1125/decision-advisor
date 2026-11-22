#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_DIR="${DECISION_GIT_DIR:-$SCRIPT_DIR/.memory-git}"
WORK_TREE="${DECISION_VAULT_PATH:-/Users/sakura/Library/Mobile Documents/com~apple~CloudDocs/决策}"
MSG="${1:-memory: 自动快照 $(date '+%Y-%m-%d %H:%M:%S')}"

if [[ ! -d "$WORK_TREE" ]]; then
  echo "Vault directory not found: $WORK_TREE" >&2
  exit 1
fi

if [[ ! -d "$GIT_DIR" ]]; then
  git init --bare "$GIT_DIR" >/dev/null 2>&1
  git --git-dir="$GIT_DIR" config core.bare false
  git --git-dir="$GIT_DIR" config core.worktree "$WORK_TREE"
  git --git-dir="$GIT_DIR" config core.quotepath false
  git --git-dir="$GIT_DIR" config user.name "Decision Advisor"
  git --git-dir="$GIT_DIR" config user.email "local@decision-advisor"
fi

git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" add -A
if git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" diff --cached --quiet; then
  echo "No changes to snapshot."
  exit 0
fi

git --git-dir="$GIT_DIR" --work-tree="$WORK_TREE" commit -m "$MSG" >/dev/null
echo "Snapshot saved: $MSG"
