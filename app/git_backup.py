from __future__ import annotations

import os
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

from .config import BASE_DIR, get_data_dir


def get_git_dir() -> Path:
    env_dir = os.environ.get("DECISION_GIT_DIR", "").strip()
    if env_dir:
        return Path(env_dir).expanduser()
    env_data = os.environ.get("ADVISOR_DATA_DIR", "").strip()
    if env_data:
        return get_data_dir() / ".memory-git"
    return BASE_DIR / ".memory-git"


def _run_git(git_dir: Path, vault_path: Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", f"--git-dir={git_dir}", f"--work-tree={vault_path}", *args],
        capture_output=True,
        text=True,
        check=False,
        timeout=15,
    )


def ensure_external_git(vault_path: Path) -> Path:
    git_dir = get_git_dir()
    if not git_dir.exists():
        git_dir.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "--bare", str(git_dir)], capture_output=True, text=True, check=True, timeout=15)
        subprocess.run(["git", f"--git-dir={git_dir}", "config", "core.bare", "false"], check=True, timeout=10)
        subprocess.run(["git", f"--git-dir={git_dir}", "config", "core.worktree", str(vault_path)], check=True, timeout=10)
        subprocess.run(["git", f"--git-dir={git_dir}", "config", "core.quotepath", "false"], check=True, timeout=10)
        subprocess.run(["git", f"--git-dir={git_dir}", "config", "user.name", "Decision Advisor"], check=True, timeout=10)
        subprocess.run(["git", f"--git-dir={git_dir}", "config", "user.email", "local@decision-advisor"], check=True, timeout=10)
    else:
        subprocess.run(["git", f"--git-dir={git_dir}", "config", "core.worktree", str(vault_path)], check=False, timeout=10)
    return git_dir


def create_snapshot(vault_path: Path, message: str | None = None) -> dict:
    if not vault_path.exists():
        return {"ok": False, "detail": f"Vault not found: {vault_path}"}
    git_dir = ensure_external_git(vault_path)
    _run_git(git_dir, vault_path, ["add", "-A"])
    diff = _run_git(git_dir, vault_path, ["diff", "--cached", "--quiet"])
    if diff.returncode == 0:
        return {"ok": True, "committed": False, "detail": "无新改动"}
    msg = message or f"memory: 自动快照 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
    commit = _run_git(git_dir, vault_path, ["commit", "-m", msg])
    if commit.returncode != 0:
        return {"ok": False, "committed": False, "detail": commit.stderr.strip() or commit.stdout.strip()}
    rev = _run_git(git_dir, vault_path, ["rev-parse", "--short", "HEAD"])
    return {
        "ok": True,
        "committed": True,
        "hash": rev.stdout.strip(),
        "message": msg,
    }


def list_snapshots(vault_path: Path, limit: int = 20) -> list[dict]:
    git_dir = get_git_dir()
    if not git_dir.exists() or not vault_path.exists():
        return []
    res = _run_git(
        git_dir,
        vault_path,
        ["log", f"-n{limit}", "--pretty=format:%h\t%ci\t%s"],
    )
    if res.returncode != 0 or not res.stdout.strip():
        return []
    items = []
    for line in res.stdout.strip().splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3:
            items.append({"hash": parts[0], "date": parts[1], "message": parts[2]})
    return items


def trigger_basic_memory_reindex() -> None:
    """Fire-and-forget reindex if basic-memory CLI is installed."""
    bm_bin = shutil.which("basic-memory") or str(Path.home() / ".local" / "bin" / "basic-memory")
    if not Path(bm_bin).exists():
        return
    try:
        subprocess.Popen(
            [bm_bin, "project", "index", "decision-kb"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass
