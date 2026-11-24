from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from .config import BASE_DIR, get_data_dir


def get_db_path() -> Path:
    env_path = os.environ.get("DECISION_DB_PATH", "").strip()
    if env_path:
        return Path(env_path).expanduser()
    env_data = os.environ.get("ADVISOR_DATA_DIR", "").strip()
    if env_data:
        return get_data_dir() / "advisor_state.db"
    return BASE_DIR / "advisor_state.db"


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


@contextmanager
def get_conn() -> Iterator[sqlite3.Connection]:
    db_path = get_db_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path), timeout=20.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def init_db() -> None:
    with get_conn() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                mode TEXT NOT NULL DEFAULT 'chat',
                provider_id TEXT NOT NULL DEFAULT '',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                reasoning TEXT NOT NULL DEFAULT '',
                model TEXT NOT NULL DEFAULT '',
                provider_name TEXT NOT NULL DEFAULT '',
                references_json TEXT NOT NULL DEFAULT '[]',
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, id);

            CREATE TABLE IF NOT EXISTS client_ops (
                client_id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                session_id TEXT,
                message_id INTEGER,
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS proposals_log (
                id TEXT PRIMARY KEY,
                session_id TEXT REFERENCES sessions(id) ON DELETE SET NULL,
                proposals_json TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                committed_paths_json TEXT NOT NULL DEFAULT '[]',
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS doc_index (
                rel_path TEXT PRIMARY KEY,
                sha256 TEXT NOT NULL,
                title TEXT NOT NULL,
                category TEXT NOT NULL,
                category_label TEXT NOT NULL,
                privacy TEXT NOT NULL,
                importance INTEGER NOT NULL DEFAULT 5,
                event_time TEXT NOT NULL DEFAULT '',
                recorded_at TEXT NOT NULL DEFAULT '',
                valid_from TEXT NOT NULL DEFAULT '',
                invalid_at TEXT NOT NULL DEFAULT '',
                superseded_by TEXT NOT NULL DEFAULT '',
                emotions_json TEXT NOT NULL DEFAULT '[]',
                people_json TEXT NOT NULL DEFAULT '[]',
                chapters_json TEXT NOT NULL DEFAULT '[]',
                observations_json TEXT NOT NULL DEFAULT '[]',
                wikilinks_json TEXT NOT NULL DEFAULT '[]',
                body_text TEXT NOT NULL DEFAULT '',
                embedding_blob BLOB,
                embedding_dim INTEGER NOT NULL DEFAULT 0,
                embedding_model TEXT NOT NULL DEFAULT '',
                mtime REAL NOT NULL DEFAULT 0,
                indexed_at TEXT NOT NULL
            );

            CREATE VIRTUAL TABLE IF NOT EXISTS doc_fts USING fts5(
                rel_path UNINDEXED,
                title,
                body_text,
                people_text,
                emotions_text,
                observations_text
            );

            CREATE TABLE IF NOT EXISTS graph_edges (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                src_path TEXT NOT NULL,
                dst_key TEXT NOT NULL,
                dst_path TEXT NOT NULL DEFAULT '',
                relation_type TEXT NOT NULL,
                weight REAL NOT NULL DEFAULT 1.0
            );
            CREATE INDEX IF NOT EXISTS idx_edges_src ON graph_edges(src_path);
            CREATE INDEX IF NOT EXISTS idx_edges_dst ON graph_edges(dst_path);

            CREATE TABLE IF NOT EXISTS oauth_clients (
                client_id TEXT PRIMARY KEY,
                client_name TEXT NOT NULL DEFAULT 'ChatGPT MCP Client',
                redirect_uris_json TEXT NOT NULL DEFAULT '[]',
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS oauth_codes (
                code TEXT PRIMARY KEY,
                client_id TEXT NOT NULL,
                redirect_uri TEXT NOT NULL,
                code_challenge TEXT NOT NULL DEFAULT '',
                code_challenge_method TEXT NOT NULL DEFAULT 'S256',
                scope TEXT NOT NULL DEFAULT 'mcp',
                expires_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS oauth_tokens (
                token_hash TEXT PRIMARY KEY,
                client_id TEXT NOT NULL,
                scope TEXT NOT NULL DEFAULT 'mcp',
                created_at TEXT NOT NULL,
                expires_at REAL NOT NULL
            );
            """
        )


# ---------- Session & Message History Helpers ----------


def create_session(title: str = "新对话", mode: str = "chat", provider_id: str = "") -> dict[str, Any]:
    sid = f"sess_{uuid.uuid4().hex[:12]}"
    now = _now_iso()
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO sessions (id, title, mode, provider_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            (sid, title.strip() or "新对话", mode, provider_id, now, now),
        )
    return {
        "id": sid,
        "title": title.strip() or "新对话",
        "mode": mode,
        "provider_id": provider_id,
        "created_at": now,
        "updated_at": now,
        "message_count": 0,
    }


def list_sessions(limit: int = 50) -> list[dict[str, Any]]:
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT s.id, s.title, s.mode, s.provider_id, s.created_at, s.updated_at,
                   COUNT(m.id) AS message_count
            FROM sessions s
            LEFT JOIN messages m ON m.session_id = s.id
            GROUP BY s.id
            ORDER BY s.updated_at DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
    return [dict(r) for r in rows]


def get_session(session_id: str) -> dict[str, Any] | None:
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
        if not row:
            return None
        msgs = conn.execute(
            "SELECT * FROM messages WHERE session_id = ? ORDER BY id ASC",
            (session_id,),
        ).fetchall()
    messages = []
    for m in msgs:
        d = dict(m)
        try:
            d["references"] = json.loads(d.pop("references_json", "[]"))
        except Exception:
            d["references"] = []
        messages.append(d)
    out = dict(row)
    out["messages"] = messages
    return out


def update_session(session_id: str, *, title: str | None = None, mode: str | None = None, provider_id: str | None = None) -> dict[str, Any] | None:
    now = _now_iso()
    fields = ["updated_at = ?"]
    params: list[Any] = [now]
    if title is not None:
        fields.append("title = ?")
        params.append(title.strip()[:80] or "未命名对话")
    if mode is not None:
        fields.append("mode = ?")
        params.append(mode)
    if provider_id is not None:
        fields.append("provider_id = ?")
        params.append(provider_id)
    params.append(session_id)
    with get_conn() as conn:
        cur = conn.execute(f"UPDATE sessions SET {', '.join(fields)} WHERE id = ?", params)
        if cur.rowcount == 0:
            return None
    return get_session(session_id)


def delete_session(session_id: str) -> bool:
    with get_conn() as conn:
        cur = conn.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
        return cur.rowcount > 0


def append_message(
    session_id: str,
    role: str,
    content: str,
    *,
    reasoning: str = "",
    model: str = "",
    provider_name: str = "",
    references: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    now = _now_iso()
    refs_json = json.dumps(references or [], ensure_ascii=False)
    with get_conn() as conn:
        cur = conn.execute(
            """
            INSERT INTO messages (session_id, role, content, reasoning, model, provider_name, references_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (session_id, role, content, reasoning, model, provider_name, refs_json, now),
        )
        msg_id = cur.lastrowid
        conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session_id))
    return {
        "id": msg_id,
        "session_id": session_id,
        "role": role,
        "content": content,
        "reasoning": reasoning,
        "model": model,
        "provider_name": provider_name,
        "references": references or [],
        "created_at": now,
    }


def log_proposals(session_id: str | None, proposals: list[dict[str, Any]], status: str = "pending", committed_paths: list[str] | None = None) -> str:
    pid = f"plog_{uuid.uuid4().hex[:10]}"
    now = _now_iso()
    with get_conn() as conn:
        conn.execute(
            """
            INSERT INTO proposals_log (id, session_id, proposals_json, status, committed_paths_json, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                pid,
                session_id,
                json.dumps(proposals, ensure_ascii=False),
                status,
                json.dumps(committed_paths or [], ensure_ascii=False),
                now,
            ),
        )
    return pid


# ---------- OAuth 2.1 Helpers (ChatGPT Developer Mode Remote MCP) ----------


def hash_token(raw_token: str) -> str:
    return hashlib.sha256(raw_token.encode("utf-8")).hexdigest()


def register_oauth_client(client_name: str, redirect_uris: list[str]) -> dict[str, Any]:
    client_id = f"mcp_client_{secrets.token_urlsafe(12)}"
    now = _now_iso()
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO oauth_clients (client_id, client_name, redirect_uris_json, created_at) VALUES (?, ?, ?, ?)",
            (client_id, client_name or "MCP Client", json.dumps(redirect_uris), now),
        )
    return {
        "client_id": client_id,
        "client_name": client_name or "MCP Client",
        "redirect_uris": redirect_uris,
        "token_endpoint_auth_method": "none",
        "grant_types": ["authorization_code"],
        "response_types": ["code"],
    }


def create_oauth_code(
    client_id: str,
    redirect_uri: str,
    code_challenge: str,
    code_challenge_method: str = "S256",
    scope: str = "mcp",
    ttl_seconds: int = 300,
) -> str:
    code = secrets.token_urlsafe(32)
    expires_at = time.time() + ttl_seconds
    with get_conn() as conn:
        conn.execute(
            """
            INSERT INTO oauth_codes (code, client_id, redirect_uri, code_challenge, code_challenge_method, scope, expires_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (code, client_id, redirect_uri, code_challenge, code_challenge_method, scope, expires_at),
        )
    return code


def consume_oauth_code(code: str) -> dict[str, Any] | None:
    with get_conn() as conn:
        row = conn.execute("SELECT * FROM oauth_codes WHERE code = ?", (code,)).fetchone()
        if not row:
            return None
        conn.execute("DELETE FROM oauth_codes WHERE code = ?", (code,))
        data = dict(row)
    if data["expires_at"] < time.time():
        return None
    return data


def issue_oauth_token(client_id: str, scope: str = "mcp", ttl_seconds: int = 86400 * 30) -> tuple[str, int]:
    raw_token = f"da_mcp_{secrets.token_urlsafe(32)}"
    now = _now_iso()
    expires_at = time.time() + ttl_seconds
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO oauth_tokens (token_hash, client_id, scope, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
            (hash_token(raw_token), client_id, scope, now, expires_at),
        )
    return raw_token, ttl_seconds


def get_oauth_token_scopes(raw_token: str) -> set[str]:
    if not raw_token:
        return set()
    h = hash_token(raw_token)
    with get_conn() as conn:
        row = conn.execute("SELECT scope, expires_at FROM oauth_tokens WHERE token_hash = ?", (h,)).fetchone()
    if not row or float(row["expires_at"]) <= time.time():
        return set()
    return set(row["scope"].split())


def oauth_redirect_is_registered(client_id: str, redirect_uri: str) -> bool:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT redirect_uris_json FROM oauth_clients WHERE client_id = ?", (client_id,)
        ).fetchone()
    return bool(row and redirect_uri in json.loads(row["redirect_uris_json"]))


# ---------- Idempotent client operations (offline outbox replays from mobile) ----------


def claim_client_op(client_id: str, kind: str) -> bool:
    """Record a one-shot client operation. Returns False when it was already applied."""
    with get_conn() as conn:
        cur = conn.execute(
            "INSERT OR IGNORE INTO client_ops (client_id, kind, created_at) VALUES (?, ?, ?)",
            (client_id, kind, _now_iso()),
        )
        return cur.rowcount == 1


def release_client_op(client_id: str) -> None:
    with get_conn() as conn:
        conn.execute("DELETE FROM client_ops WHERE client_id = ?", (client_id,))


def claim_chat_turn(client_id: str, session_id: str, content: str) -> tuple[str, int, bool]:
    """Append the user turn once per client_id. Replays get the original session and message."""
    with get_conn() as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT session_id, message_id FROM client_ops WHERE client_id = ? AND kind = 'chat'",
            (client_id,),
        ).fetchone()
        if row and row["session_id"]:
            exists = conn.execute("SELECT 1 FROM sessions WHERE id = ?", (row["session_id"],)).fetchone()
            if exists:
                return row["session_id"], int(row["message_id"]), False
        now = _now_iso()
        cur = conn.execute(
            """
            INSERT INTO messages (session_id, role, content, reasoning, model, provider_name, references_json, created_at)
            VALUES (?, 'user', ?, '', '', '', '[]', ?)
            """,
            (session_id, content, now),
        )
        conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session_id))
        conn.execute(
            """
            INSERT OR REPLACE INTO client_ops (client_id, kind, session_id, message_id, created_at)
            VALUES (?, 'chat', ?, ?, ?)
            """,
            (client_id, session_id, cur.lastrowid, now),
        )
        return session_id, int(cur.lastrowid), True


def client_chat_session(client_id: str) -> str | None:
    with get_conn() as conn:
        row = conn.execute(
            """
            SELECT c.session_id FROM client_ops c JOIN sessions s ON s.id = c.session_id
            WHERE c.client_id = ? AND c.kind = 'chat'
            """,
            (client_id,),
        ).fetchone()
    return row["session_id"] if row else None


def reply_after(session_id: str, message_id: int) -> dict[str, Any] | None:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM messages WHERE session_id = ? AND id > ? ORDER BY id LIMIT 1",
            (session_id, message_id),
        ).fetchone()
    return dict(row) if row and row["role"] == "assistant" else None
