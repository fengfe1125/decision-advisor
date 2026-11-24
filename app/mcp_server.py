from __future__ import annotations

import base64
import hashlib
import hmac
import html
import json
import re
from typing import Any
from urllib.parse import urlencode

from fastapi import APIRouter, Form, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

from .config import load_config
from .db import (
    consume_oauth_code,
    create_oauth_code,
    get_conn,
    get_oauth_token_scopes,
    issue_oauth_token,
    oauth_redirect_is_registered,
    register_oauth_client,
)
from .git_backup import create_snapshot, trigger_basic_memory_reindex
from .memory_store import MemoryStore, strip_private_blocks
from .search_index import get_timeline, hybrid_search, sync_vault_index

router = APIRouter()

MCP_PROTOCOL_VERSION = "2025-03-26"
CHAT_HISTORY_SCOPE = "chat_history"

MCP_TOOLS: list[dict[str, Any]] = [
    {
        "name": "get_core_self",
        "description": (
            "读取用户的『00-核心自我』全量核心档案（我是谁、价值观排序、情绪触发与行为模式、底线红线、当前目标）"
            "以及个人成长决策顾问协议。在回答人生选择、情绪困扰或深度自我问题前务必先调用此工具。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "search_memories",
        "description": (
            "使用 4 路混合检索引擎（中文语义向量 + 关键词 + 实体双链图谱 + 双时间显著性）"
            "搜索用户的过去经历、情绪感受、重要人物、人生章节与过往决策复盘。"
            "支持传 as_of（如 2024-12-31）回溯截至某个历史时间点的自己。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "搜索问题、情绪词、人物名或主题"},
                "top_k": {"type": "integer", "default": 6, "minimum": 1, "maximum": 15},
                "as_of": {
                    "type": "string",
                    "description": "可选，YYYY-MM-DD，只召回在该日期及之前发生且当时有效的历史记忆",
                },
                "include_inbox": {"type": "boolean", "default": False},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "get_memory",
        "description": "按相对路径读取单篇个人记忆的完整 Markdown 内容（默认自动拦截 sensitive 级绝密文档）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "记忆库内相对路径，如 02-经历与感受/2026/2026-11-21-xxx.md"},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "get_timeline",
        "description": "按发生时间顺序获取用户的人生章节、重要经历与感受、过往决策和认知演变时间轴。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "start_date": {"type": "string", "description": "可选，起始日期 YYYY-MM-DD"},
                "end_date": {"type": "string", "description": "可选，截止日期 YYYY-MM-DD"},
            },
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "add_inbox_note",
        "description": "将一条随手想法或当下感受快速追加到 99-收件箱/inbox.md（低摩擦速记，并自动做外置 Git 快照）。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "速记正文"},
                "mood": {"type": "string", "description": "可选，当下情绪词"},
            },
            "required": ["text"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
    },
    {
        "name": "save_memory",
        "description": (
            "在征得用户明确半自动确认后，将结构化个人记忆写入本地 Markdown 记忆库并自动生成外置 Git 快照。"
            "写入前请先向用户展示 3-5 行摘要（修改 00-核心自我/ 需说明前后变化与证据）。"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "目标相对路径，如 02-经历与感受/2026/2026-11-21-事件.md 或 04-决策实验室/进行中/xxx.md",
                },
                "action": {
                    "type": "string",
                    "enum": ["create", "update", "append"],
                    "default": "create",
                },
                "content": {
                    "type": "string",
                    "description": "完整 Markdown 内容（建议含 YAML Frontmatter、emotions[]、Observations 和 Relations 双链）",
                },
                "commit_message": {"type": "string", "description": "本次写入的简短说明"},
            },
            "required": ["path", "content"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": False, "destructiveHint": False},
    },
]

CHAT_TOOLS = [
    {
        "name": "list_chat_sessions",
        "description": "按最近更新时间列出 VPS 上的顾问会话（含手机与 Mac 端），返回会话 ID、标题、消息数和时间。可用 before 继续翻页。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "before": {"type": "string", "description": "上一页返回的 next_before，用于继续翻页"},
                "limit": {"type": "integer", "default": 20, "minimum": 1, "maximum": 50},
            },
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "search_chat_history",
        "description": "按原文检索 VPS 上已保存的顾问对话。返回会话 ID、消息 ID 和匹配片段。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "minLength": 1, "maxLength": 200},
                "limit": {"type": "integer", "default": 8, "minimum": 1, "maximum": 20},
            },
            "required": ["query"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
    {
        "name": "get_chat_messages",
        "description": "用会话 ID 读取一页对话原文。用 next_after_id 继续读取下一页。",
        "inputSchema": {
            "type": "object",
            "properties": {
                "session_id": {"type": "string", "minLength": 1},
                "after_id": {"type": "integer", "default": 0, "minimum": 0},
                "limit": {"type": "integer", "default": 12, "minimum": 1, "maximum": 20},
            },
            "required": ["session_id"],
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True, "destructiveHint": False},
    },
]
CHAT_TOOL_NAMES = {tool["name"] for tool in CHAT_TOOLS}


def _resolve_base_url(request: Request) -> str:
    cfg = load_config()
    if cfg.public_base_url:
        return cfg.public_base_url.rstrip("/")
    proto = request.headers.get("x-forwarded-proto") or request.url.scheme
    host = request.headers.get("x-forwarded-host") or request.headers.get("host") or request.url.netloc
    return f"{proto}://{host}".rstrip("/")


def _mcp_scopes(request: Request) -> set[str]:
    cfg = load_config()
    if not cfg.access_token:
        return {"mcp"}
    auth = request.headers.get("authorization") or ""
    token = auth[7:].strip() if auth.lower().startswith("bearer ") else (request.headers.get("x-access-token") or "").strip()
    if not token:
        return set()
    if hmac.compare_digest(token, cfg.access_token):
        return {"mcp", CHAT_HISTORY_SCOPE}
    return get_oauth_token_scopes(token)


# ---------- OAuth 2.1 Discovery & PKCE Endpoints (Official ChatGPT Developer Mode Spec) ----------


@router.get("/.well-known/oauth-protected-resource")
@router.get("/.well-known/oauth-protected-resource/mcp")
def oauth_protected_resource(request: Request) -> dict[str, Any]:
    base = _resolve_base_url(request)
    return {
        "resource": f"{base}/mcp",
        "authorization_servers": [base],
        "scopes_supported": ["mcp", CHAT_HISTORY_SCOPE],
        "bearer_methods_supported": ["header"],
    }


@router.get("/.well-known/oauth-authorization-server")
@router.get("/.well-known/openid-configuration")
def oauth_authorization_server(request: Request) -> dict[str, Any]:
    base = _resolve_base_url(request)
    return {
        "issuer": base,
        "authorization_endpoint": f"{base}/oauth/authorize",
        "token_endpoint": f"{base}/oauth/token",
        "registration_endpoint": f"{base}/oauth/register",
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code"],
        "token_endpoint_auth_methods_supported": ["none"],
        "code_challenge_methods_supported": ["S256", "plain"],
        "scopes_supported": ["mcp", CHAT_HISTORY_SCOPE],
    }


@router.post("/oauth/register")
async def oauth_register(request: Request) -> JSONResponse:
    body = await request.json()
    client_name = str(body.get("client_name") or "ChatGPT MCP Client")
    redirect_uris = body.get("redirect_uris") or []
    if not isinstance(redirect_uris, list):
        redirect_uris = []
    client = register_oauth_client(client_name, [str(u) for u in redirect_uris])
    return JSONResponse(status_code=201, content=client)


@router.get("/oauth/authorize", response_class=HTMLResponse)
def oauth_authorize_form(
    client_id: str,
    redirect_uri: str,
    response_type: str = "code",
    state: str = "",
    code_challenge: str = "",
    code_challenge_method: str = "S256",
    scope: str = "mcp",
) -> HTMLResponse:
    if response_type != "code":
        raise HTTPException(status_code=400, detail="Unsupported response_type")
    if not oauth_redirect_is_registered(client_id, redirect_uri):
        raise HTTPException(status_code=400, detail="未注册的客户端或回调地址")
    page = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>授权接入个人成长记忆库 (MCP)</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; background:#f6f4ef; color:#1f2421; display:grid; place-items:center; min-height:100vh; margin:0; padding:16px; }}
    .box {{ background:#fff; border:1px solid #e3ded3; border-radius:16px; padding:26px; max-width:400px; width:100%; box-shadow:0 4px 18px rgba(0,0,0,0.06); }}
    h2 {{ margin:0 0 8px; font-size:19px; }}
    p {{ color:#6c6a64; font-size:13.5px; line-height:1.6; }}
    input {{ width:100%; box-sizing:border-box; padding:11px; border:1px solid #d7d1c5; border-radius:10px; font-size:14px; margin:12px 0; }}
    button {{ width:100%; padding:11px; border:none; border-radius:10px; background:#2c5e4f; color:#fff; font-size:15px; font-weight:600; cursor:pointer; }}
  </style>
</head>
<body>
  <form class="box" method="post" action="/oauth/authorize">
    <h2>🧭 授权访问个人成长记忆库</h2>
    <p>客户端 <code>{html.escape(client_id)}</code> 请求通过官方 MCP 协议访问你的个人成长记忆库（<code>privacy: sensitive</code> 文档仍默认受隐私防火墙保护）。</p>
    <input type="hidden" name="client_id" value="{html.escape(client_id)}" />
    <input type="hidden" name="redirect_uri" value="{html.escape(redirect_uri)}" />
    <input type="hidden" name="state" value="{html.escape(state)}" />
    <input type="hidden" name="code_challenge" value="{html.escape(code_challenge)}" />
    <input type="hidden" name="code_challenge_method" value="{html.escape(code_challenge_method)}" />
    <input type="hidden" name="scope" value="{html.escape(scope)}" />
    <p><label><input type="checkbox" name="allow_chat_history" value="true" style="width:auto" />
        一并允许此 AI 读取已保存的聊天原文</label></p>
    <input type="password" name="password" placeholder="输入你在设置页配置的访问密码" required autofocus />
    <button type="submit">确认授权连接</button>
  </form>
</body>
</html>"""
    return HTMLResponse(page)


@router.post("/oauth/authorize")
def oauth_authorize_submit(
    client_id: str = Form(...),
    redirect_uri: str = Form(...),
    password: str = Form(...),
    state: str = Form(""),
    code_challenge: str = Form(""),
    code_challenge_method: str = Form("S256"),
    scope: str = Form("mcp"),
    allow_chat_history: bool = Form(False),
) -> Response:
    cfg = load_config()
    if cfg.access_token and not hmac.compare_digest(password.strip(), cfg.access_token):
        return HTMLResponse("<h3>访问密码错误，请返回重试。</h3>", status_code=403)
    if not oauth_redirect_is_registered(client_id, redirect_uri):
        raise HTTPException(status_code=400, detail="未注册的客户端或回调地址")
    if allow_chat_history and (
        not cfg.access_token
        or code_challenge_method != "S256"
        or not re.fullmatch(r"[A-Za-z0-9_-]{43}", code_challenge)
    ):
        raise HTTPException(status_code=400, detail="聊天原文授权需要访问密码和 S256 PKCE")
    scope = f"mcp {CHAT_HISTORY_SCOPE}" if allow_chat_history else "mcp"
    code = create_oauth_code(client_id, redirect_uri, code_challenge, code_challenge_method, scope)
    params = {"code": code}
    if state:
        params["state"] = state
    sep = "&" if "?" in redirect_uri else "?"
    return RedirectResponse(url=f"{redirect_uri}{sep}{urlencode(params)}", status_code=302)


@router.post("/oauth/token")
async def oauth_token(request: Request) -> JSONResponse:
    ctype = (request.headers.get("content-type") or "").lower()
    if "application/json" in ctype:
        data = await request.json()
    else:
        form = await request.form()
        data = dict(form)

    grant_type = str(data.get("grant_type") or "")
    if grant_type != "authorization_code":
        return JSONResponse(status_code=400, content={"error": "unsupported_grant_type"})

    code = str(data.get("code") or "")
    verifier = str(data.get("code_verifier") or "")
    record = consume_oauth_code(code)
    if not record:
        return JSONResponse(status_code=400, content={"error": "invalid_grant", "error_description": "授权码无效或已过期"})
    if any(data.get(key) and data[key] != record[key] for key in ("client_id", "redirect_uri")):
        return JSONResponse(status_code=400, content={"error": "invalid_grant"})

    if record["code_challenge"]:
        method = (record["code_challenge_method"] or "S256").upper()
        if method == "S256":
            expected = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")
        else:
            expected = verifier
        if not hmac.compare_digest(expected, record["code_challenge"]):
            return JSONResponse(status_code=400, content={"error": "invalid_grant", "error_description": "PKCE 校验失败"})

    token, expires_in = issue_oauth_token(record["client_id"], record["scope"])
    return JSONResponse(
        content={
            "access_token": token,
            "token_type": "Bearer",
            "expires_in": expires_in,
            "scope": record["scope"],
        }
    )


# ---------- MCP Streamable HTTP Endpoint (POST /mcp) ----------

def _visible_chat_text(value: str) -> str:
    text = strip_private_blocks(value)
    return re.split(r"<private>", text, maxsplit=1, flags=re.IGNORECASE)[0]


def _read_chat_history(name: str, args: dict[str, Any]) -> str:
    if name == "list_chat_sessions":
        limit = max(1, min(50, int(args.get("limit") or 20)))
        before = str(args.get("before") or "").strip()
        with get_conn() as conn:
            rows = conn.execute(
                """
                SELECT s.id, s.title, s.mode, s.created_at, s.updated_at, COUNT(m.id) AS message_count
                FROM sessions s
                LEFT JOIN messages m ON m.session_id = s.id AND m.role IN ('user', 'assistant')
                WHERE (? = '' OR s.updated_at < ?)
                GROUP BY s.id
                ORDER BY s.updated_at DESC
                LIMIT ?
                """,
                (before, before, limit + 1),
            ).fetchall()
        items = [dict(row) for row in rows[:limit]]
        for item in items:
            item["title"] = _visible_chat_text(item["title"]).strip() or "未命名对话"
        return json.dumps(
            {"items": items, "next_before": items[-1]["updated_at"] if len(rows) > limit else None},
            ensure_ascii=False,
        )

    limit = max(1, min(20, int(args.get("limit") or (8 if name == "search_chat_history" else 12))))
    with get_conn() as conn:
        if name == "search_chat_history":
            query = str(args.get("query") or "").strip()
            if not 1 <= len(query) <= 200:
                raise ValueError("请输入 1 到 200 个字符")
            conn.create_function("visible_chat_text", 1, _visible_chat_text)
            rows = conn.execute(
                """
                SELECT id, session_id, role, created_at,
                       SUBSTR(text, MAX(1, INSTR(LOWER(text), LOWER(?)) - 100), 420) AS snippet
                FROM (
                    SELECT id, session_id, role, created_at, visible_chat_text(content) AS text
                    FROM messages WHERE role IN ('user', 'assistant')
                )
                WHERE INSTR(LOWER(text), LOWER(?)) > 0
                ORDER BY id DESC LIMIT ?
                """,
                (query, query, limit),
            ).fetchall()
            result = {"items": [dict(row) for row in rows]}
        else:
            session_id = str(args.get("session_id") or "").strip()
            if not session_id:
                raise ValueError("缺少会话 ID")
            after_id = max(0, int(args.get("after_id") or 0))
            rows = conn.execute(
                """
                SELECT id, role, created_at, content
                FROM messages
                WHERE session_id = ? AND id > ? AND role IN ('user', 'assistant')
                ORDER BY id LIMIT ?
                """,
                (session_id, after_id, limit + 1),
            ).fetchall()
            items = []
            for row in rows[:limit]:
                item = dict(row)
                visible = _visible_chat_text(item["content"])
                item["content"] = visible[:2400]
                item["truncated"] = len(visible) > 2400
                items.append(item)
            result = {
                "session_id": session_id,
                "items": items,
                "next_after_id": items[-1]["id"] if len(rows) > limit else None,
            }
    return json.dumps(result, ensure_ascii=False)


def _execute_mcp_tool(name: str, args: dict[str, Any]) -> str:
    cfg = load_config()
    store = MemoryStore(cfg.vault_path)

    if name == "get_core_self":
        protocol = store.read_protocol_prompt()
        core_docs = store.load_core_self(allow_sensitive=False)
        parts = ["# 个人成长顾问协议\n" + protocol, "# 核心自我档案 (00-核心自我)"]
        for d in core_docs:
            parts.append(f"## [[{d.rel_path}]] — {d.title}\n{store.sanitize_for_llm(d, allow_sensitive=False)}")
        return "\n\n---\n\n".join(parts)

    if name == "search_memories":
        query = str(args.get("query") or "").strip()
        top_k = max(1, min(15, int(args.get("top_k") or 6)))
        as_of = str(args.get("as_of") or "").strip() or None
        include_inbox = bool(args.get("include_inbox", False))
        hits = hybrid_search(
            store,
            query,
            top_k=top_k,
            allow_sensitive=False,
            include_core=True,
            include_inbox=include_inbox,
            as_of=as_of,
        )
        if not hits:
            return "未在记忆库中找到匹配的公开/私人记忆（sensitive 文档默认被隐私防火墙隔离）。"
        lines = []
        for h in hits:
            doc = h["doc"]
            body_clean = store.sanitize_for_llm(doc, allow_sensitive=False)[:1400]
            lines.append(
                f"### [[{doc.rel_path}]] — {doc.title}\n"
                f"- 分类：{doc.category_label} | 发生时间：{doc.event_time or '未知'} | 显著性：{doc.importance}/10 | 召回依据：{' / '.join(h['reasons'])}\n\n"
                f"{body_clean}"
            )
        return "\n\n---\n\n".join(lines)

    if name == "get_memory":
        path = str(args.get("path") or "").strip()
        doc = store.read_doc(path)
        if doc.privacy == "sensitive":
            return f"文档 [[{doc.rel_path}]] 标记为 privacy: sensitive，已按隐私规则拦截。"
        return f"# [[{doc.rel_path}]] — {doc.title}\n\n{store.sanitize_for_llm(doc, allow_sensitive=False)}"

    if name == "get_timeline":
        start_date = str(args.get("start_date") or "").strip()
        end_date = str(args.get("end_date") or "").strip()
        items = get_timeline(store, start_date=start_date, end_date=end_date, allow_sensitive=False)
        if not items:
            return "当前时间范围内暂无人生章节、事件或决策记录。"
        return json.dumps(items, ensure_ascii=False, indent=2)

    if name == "add_inbox_note":
        text = str(args.get("text") or "").strip()
        mood = str(args.get("mood") or "").strip()
        saved = store.append_inbox(text, mood)
        snap = create_snapshot(store.vault_path, "mcp-inbox: 通过远程 MCP 速记追加")
        sync_vault_index(store)
        trigger_basic_memory_reindex()
        return json.dumps({"ok": True, "path": saved, "snapshot": snap}, ensure_ascii=False)

    if name == "save_memory":
        path = str(args.get("path") or "").strip()
        action = str(args.get("action") or "create").strip().lower()
        if action not in {"create", "update", "append"}:
            action = "create"
        content = str(args.get("content") or "")
        commit_msg = str(args.get("commit_message") or f"mcp: 写入 {path}")
        saved = store.write_doc(path, content, action=action)
        snap = create_snapshot(store.vault_path, commit_msg)
        sync_vault_index(store)
        trigger_basic_memory_reindex()
        return json.dumps({"ok": True, "path": saved, "snapshot": snap}, ensure_ascii=False)

    raise ValueError(f"未知 MCP 工具: {name}")


@router.post("/mcp")
async def mcp_endpoint(request: Request) -> Response:
    scopes = _mcp_scopes(request)
    if "mcp" not in scopes:
        base = _resolve_base_url(request)
        return JSONResponse(
            status_code=401,
            content={"error": "unauthorized", "message": "需要有效的 Bearer Token 或 OAuth 2.1 授权"},
            headers={
                "WWW-Authenticate": f'Bearer resource_metadata="{base}/.well-known/oauth-protected-resource"'
            },
        )

    try:
        payload = await request.json()
    except Exception:
        return JSONResponse(
            status_code=400,
            content={"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Invalid JSON"}},
        )

    req_id = payload.get("id")
    method = payload.get("method")
    params = payload.get("params") or {}

    if method == "notifications/initialized":
        return Response(status_code=202)

    if method == "initialize":
        return JSONResponse(
            content={
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": MCP_PROTOCOL_VERSION,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "decision-advisor-mcp", "version": "0.12"},
                },
            }
        )

    if method == "ping":
        return JSONResponse(content={"jsonrpc": "2.0", "id": req_id, "result": {}})

    if method == "tools/list":
        tools = MCP_TOOLS + CHAT_TOOLS if CHAT_HISTORY_SCOPE in scopes else MCP_TOOLS
        return JSONResponse(content={"jsonrpc": "2.0", "id": req_id, "result": {"tools": tools}})

    if method == "tools/call":
        tool_name = str(params.get("name") or "")
        tool_args = params.get("arguments") or {}
        try:
            if tool_name in CHAT_TOOL_NAMES:
                if CHAT_HISTORY_SCOPE not in scopes:
                    raise PermissionError("此连接未获聊天原文读取授权")
                text = _read_chat_history(tool_name, tool_args)
            else:
                text = _execute_mcp_tool(tool_name, tool_args)
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": text}],
                        "isError": False,
                    },
                }
            )
        except Exception as exc:
            return JSONResponse(
                content={
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": f"工具执行失败: {exc}"}],
                        "isError": True,
                    },
                }
            )

    return JSONResponse(
        content={
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }
    )
