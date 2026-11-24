#!/usr/bin/env zsh
# 统一升级成长决策顾问的版本号（macOS 客户端 + VPS 后端共用同一版本）。
#
# 用法：
#   ./bump-version.sh            # 默认在当前版本上 +0.01（如 0.12 -> 0.13）
#   ./bump-version.sh 0.20       # 显式指定版本（格式 X.YY，两位小数）
#   ./bump-version.sh --show     # 只打印当前版本
#
# 版本号唯一真源是 app/config.py 中的 APP_VERSION，本脚本同步改写：
#   app/config.py、pyproject.toml、uv.lock、macos/build_app.sh、agent.md 顶部「当前版本」
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

current="$(grep -m1 '^APP_VERSION = ' app/config.py | cut -d'"' -f2)"
if [[ -z "$current" ]]; then
  echo "error: 无法从 app/config.py 读取 APP_VERSION" >&2
  exit 1
fi

if [[ "${1:-}" == "--show" ]]; then
  echo "$current"
  exit 0
fi

if [[ -n "${1:-}" ]]; then
  next="$1"
else
  # 以“百分位”为单位整数运算，避免浮点误差：0.12 -> 12 -> 13 -> 0.13；0.99 -> 1.00
  major="${current%%.*}"
  minor="${current#*.}"
  cents=$(( 10#$major * 100 + 10#$minor + 1 ))
  next="$(printf '%d.%02d' $(( cents / 100 )) $(( cents % 100 )))"
fi

if [[ ! "$next" =~ '^[0-9]+\.[0-9]{2}$' ]]; then
  echo "error: 版本号必须是 X.YY 格式（两位小数），收到：$next" >&2
  exit 1
fi

echo "版本号：$current -> $next"

perl -pi -e "s/^APP_VERSION = \"[^\"]*\"/APP_VERSION = \"$next\"/" app/config.py
perl -pi -e "s/^version = \"[^\"]*\"/version = \"$next\"/ if \$. < 10" pyproject.toml
perl -0pi -e "s/(name = \"decision-advisor\"\nversion = )\"[^\"]*\"/\${1}\"$next\"/" uv.lock
perl -pi -e "s/^VERSION=\"[^\"]*\"/VERSION=\"$next\"/" macos/build_app.sh
perl -pi -e "s/(\*\*当前版本\*\*：)\`v[^\`]*\`/\${1}\`v$next\`/" agent.md

grep -n "^APP_VERSION" app/config.py
grep -n "^version" pyproject.toml
grep -n -A1 'name = "decision-advisor"' uv.lock | tail -1
grep -n '^VERSION=' macos/build_app.sh
grep -n '当前版本' agent.md | head -1
