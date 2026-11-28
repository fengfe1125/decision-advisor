from __future__ import annotations

import hmac
import html
import json
import re
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, StreamingResponse
from pydantic import BaseModel, Field

from .chatgpt_oauth import (
    ChatGPTOAuthError,
    complete_chatgpt_oauth_callback,
    get_default_loopback_port,
    get_pending_flow_status,
    get_public_oauth_status,
    logout_chatgpt_oauth,
    parse_callback_url_params,
    refresh_chatgpt_models,
    start_chatgpt_oauth_flow,
)
from .config import (
    APP_VERSION,
    ProviderPreset,
    ensure_chatgpt_oauth_provider,
    get_deployment_mode,
    load_config,
    merge_config_update,
    normalize_reasoning_effort,
    save_config,
    serialize_public_config,
)
from .db import (
    append_message,
    claim_chat_turn,
    claim_client_op,
    client_chat_session,
    create_session,
    delete_session,
    get_session,
    init_db,
    list_sessions,
    log_proposals,
    release_client_op,
    reply_after,
    update_session,
)
from .git_backup import create_snapshot, list_snapshots, trigger_basic_memory_reindex
from .mcp_server import router as mcp_router
from .memory_importer import IMPORT_PROMPT_TEMPLATES, batch_import_chunks, parse_import_payload
from .memory_store import CATEGORY_ORDER, MemoryStore
from .onboarding import (
    ADVISOR_STYLES,
    CORE_SLOT_BY_ID,
    build_interview_opening_fallback,
    build_quick_profile_proposals,
    evaluate_onboarding_status,
    set_onboarding_state,
)
from .prompts import (
    build_chat_system_prompt,
    build_extraction_prompts,
    build_import_extraction_prompts,
    build_interview_kickoff_prompts,
    parse_proposals_json,
)
from .providers import ProviderError, call_llm, stream_llm
from .search_index import (
    get_index_stats,
    get_knowledge_graph,
    get_timeline,
    hybrid_search,
    sync_vault_index,
)

API_CAPABILITIES = [
    "chat_stream",
    "reasoning_effort",
    "hybrid_search",
    "timeline",
    "graph",
    "proposals",
    "onboarding",
    "memory_import",
    "mcp",
    "vault_export",
    "chatgpt_oauth",
]


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    yield


app = FastAPI(title="个人成长决策顾问与记忆库 API", version=APP_VERSION, lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(mcp_router)


def _extract_token(authorization: str | None, x_access_token: str | None) -> str:
    if x_access_token:
        return x_access_token.strip()
    if authorization and authorization.lower().startswith("bearer "):
        return authorization[7:].strip()
    return ""


def require_auth(
    authorization: str | None = Header(default=None),
    x_access_token: str | None = Header(default=None),
) -> None:
    cfg = load_config()
    if not cfg.access_token:
        return
    provided = _extract_token(authorization, x_access_token)
    if not provided:
        raise HTTPException(status_code=401, detail="访问密码无效或未提供")
    if hmac.compare_digest(provided, cfg.access_token):
        return
    raise HTTPException(status_code=401, detail="访问密码无效或未提供")


def _get_store() -> MemoryStore:
    cfg = load_config()
    return MemoryStore(cfg.vault_path)


def _select_provider(provider_id: str | None) -> ProviderPreset:
    cfg = load_config()
    target_id = provider_id or cfg.active_provider_id
    for p in cfg.providers:
        if p.id == target_id:
            return p
    if cfg.providers:
        return cfg.providers[0]
    raise HTTPException(status_code=400, detail="尚未配置任何大模型提供商")


def _auto_title(text: str) -> str:
    clean = re.sub(r"\s+", " ", text.strip())
    return (clean[:24] + "…") if len(clean) > 24 else (clean or "新对话")


# ---------- Pydantic Request Models ----------


class SessionCreateRequest(BaseModel):
    title: str = "新对话"
    mode: str = "chat"
    provider_id: str = ""


class SessionUpdateRequest(BaseModel):
    title: str | None = None
    mode: str | None = None
    provider_id: str | None = None


class ChatMessage(BaseModel):
    role: str
    content: str


class ChatRequest(BaseModel):
    messages: list[ChatMessage] = Field(min_length=1)
    mode: str = "chat"
    provider_id: str | None = None
    allow_sensitive: bool = False
    session_id: str | None = None
    as_of: str | None = None
    reasoning_effort: str | None = None
    client_id: str | None = Field(default=None, max_length=80)


class ExtractRequest(BaseModel):
    messages: list[ChatMessage] = Field(min_length=1)
    provider_id: str | None = None
    allow_sensitive: bool = False
    session_id: str | None = None


class CommitProposalItem(BaseModel):
    action: str = "create"
    path: str
    title: str = ""
    content: str
    privacy: str | None = None


class CommitRequest(BaseModel):
    items: list[CommitProposalItem] = Field(min_length=1)
    commit_message: str | None = None
    session_id: str | None = None


class SaveFileRequest(BaseModel):
    path: str
    content: str
    commit_message: str | None = None
    create_only: bool = False


class InboxRequest(BaseModel):
    text: str = Field(min_length=1)
    mood: str = ""
    client_id: str | None = Field(default=None, max_length=80)


class TestProviderRequest(BaseModel):
    provider_id: str | None = None


class ChatGPTOAuthStartRequest(BaseModel):
    force_register: bool = False
    redirect_port: int | None = Field(default=None, ge=1024, le=65535)


class ChatGPTOAuthCompleteCallbackRequest(BaseModel):
    callback_url: str = ""
    code: str = ""
    state: str = ""
    client_id: str = ""


class ChatGPTOAuthLogoutRequest(BaseModel):
    reset_client: bool = False


class OnboardingStateRequest(BaseModel):
    state: str = Field(default="dismissed")


class QuickProfileRequest(BaseModel):
    preferred_name: str = ""
    life_stage: str = ""
    current_focus: str = ""
    core_values: list[str] = Field(default_factory=list)
    values_note: str = ""
    boundaries: str = ""
    patterns: str = ""
    goals: str = ""
    advisor_style: str = "balanced"
    advisor_style_note: str = ""
    commit: bool = True


class InterviewStartRequest(BaseModel):
    focus_slot: str | None = None
    provider_id: str | None = None
    allow_sensitive: bool = False


class ImportFilePayload(BaseModel):
    filename: str
    content_base64: str


class ImportPreviewRequest(BaseModel):
    raw_text: str = ""
    files: list[ImportFilePayload] = Field(default_factory=list)
    source_hint: str = "auto"


class ImportChunkInput(BaseModel):
    id: str = ""
    source_type: str = ""
    source_label: str = ""
    title: str = ""
    date: str = ""
    content: str


class ImportExtractRequest(BaseModel):
    items: list[ImportChunkInput] = Field(min_length=1)
    source_label: str = "外部 Agent 记忆"
    provider_id: str | None = None
    allow_sensitive: bool = False


# ---------- Public Auth Check ----------


@app.get("/api/auth/status")
def auth_status(
    authorization: str | None = Header(default=None),
    x_access_token: str | None = Header(default=None),
) -> dict[str, Any]:
    cfg = load_config()
    mode = get_deployment_mode()
    if not cfg.access_token:
        return {"auth_required": False, "authenticated": True, "deployment_mode": mode, "version": APP_VERSION}
    provided = _extract_token(authorization, x_access_token)
    ok = bool(provided) and hmac.compare_digest(provided, cfg.access_token)
    return {"auth_required": True, "authenticated": ok, "deployment_mode": mode, "version": APP_VERSION}


@app.post("/api/auth/verify", dependencies=[Depends(require_auth)])
def auth_verify() -> dict[str, Any]:
    return {"ok": True, "deployment_mode": get_deployment_mode(), "version": APP_VERSION}


# ---------- Health & Index Stats ----------


@app.get("/api/health", dependencies=[Depends(require_auth)])
def health() -> dict[str, Any]:
    init_db()
    store = _get_store()
    cfg = load_config()
    return {
        "ok": True,
        "version": APP_VERSION,
        "deployment_mode": get_deployment_mode(),
        "capabilities": API_CAPABILITIES,
        "stats": store.get_stats(),
        "index": get_index_stats(),
        "active_provider_id": cfg.active_provider_id,
    }


@app.post("/api/index/rebuild", dependencies=[Depends(require_auth)])
def rebuild_index() -> dict[str, Any]:
    init_db()
    store = _get_store()
    result = sync_vault_index(store, force_rebuild=True)
    return {"ok": True, **result}


# ---------- SQLite Conversation Sessions ----------


@app.get("/api/sessions", dependencies=[Depends(require_auth)])
def api_list_sessions(limit: int = Query(default=50, ge=1, le=200)) -> dict[str, Any]:
    init_db()
    return {"items": list_sessions(limit=limit)}


@app.post("/api/sessions", dependencies=[Depends(require_auth)])
def api_create_session(req: SessionCreateRequest) -> dict[str, Any]:
    init_db()
    return create_session(title=req.title, mode=req.mode, provider_id=req.provider_id)


@app.get("/api/sessions/{session_id}", dependencies=[Depends(require_auth)])
def api_get_session(session_id: str) -> dict[str, Any]:
    init_db()
    sess = get_session(session_id)
    if not sess:
        raise HTTPException(status_code=404, detail="对话不存在")
    return sess


@app.patch("/api/sessions/{session_id}", dependencies=[Depends(require_auth)])
def api_update_session(session_id: str, req: SessionUpdateRequest) -> dict[str, Any]:
    init_db()
    sess = update_session(session_id, title=req.title, mode=req.mode, provider_id=req.provider_id)
    if not sess:
        raise HTTPException(status_code=404, detail="对话不存在")
    return sess


@app.delete("/api/sessions/{session_id}", dependencies=[Depends(require_auth)])
def api_delete_session(session_id: str) -> dict[str, Any]:
    init_db()
    ok = delete_session(session_id)
    if not ok:
        raise HTTPException(status_code=404, detail="对话不存在")
    return {"ok": True}


# ---------- Memory Browser, Hybrid Search, Timeline & Graph ----------


@app.get("/api/memories", dependencies=[Depends(require_auth)])
def list_memories(
    category: str = Query(default="all"),
    q: str = Query(default=""),
    emotion: str = Query(default=""),
    min_importance: int = Query(default=1, ge=1, le=10),
    include_system: bool = Query(default=False),
) -> dict[str, Any]:
    store = _get_store()
    docs = store.scan_all(include_system=include_system)
    q_low = q.strip().lower()
    emo_low = emotion.strip().lower()

    filtered = []
    all_emotions: set[str] = set()
    for d in docs:
        summary = d.to_summary()
        for e in summary["emotions"]:
            all_emotions.add(e)
        if category != "all" and d.category != category:
            continue
        if d.importance < min_importance:
            continue
        if emo_low and not any(emo_low in e.lower() for e in summary["emotions"]):
            continue
        if q_low:
            haystack = f"{d.title}\n{d.rel_path}\n{' '.join(d.people)}\n{' '.join(summary['emotions'])}\n{d.body}".lower()
            if q_low not in haystack:
                continue
        filtered.append(summary)

    filtered.sort(key=lambda item: (item["category"] != "00-核心自我", -item["updated_ts"]))
    return {
        "categories": [{"id": k, "label": v} for k, v in CATEGORY_ORDER if include_system or k != "_系统协议"],
        "emotions": sorted(all_emotions),
        "items": filtered,
        "total": len(filtered),
    }


@app.get("/api/memories/search", dependencies=[Depends(require_auth)])
def semantic_search_memories(
    q: str = Query(..., min_length=1),
    top_k: int = Query(default=10, ge=1, le=30),
    as_of: str = Query(default=""),
    allow_sensitive: bool = Query(default=True),
) -> dict[str, Any]:
    init_db()
    store = _get_store()
    hits = hybrid_search(
        store,
        q,
        top_k=top_k,
        allow_sensitive=allow_sensitive,
        include_core=True,
        include_inbox=True,
        as_of=as_of or None,
    )
    items = []
    for h in hits:
        s = h["doc"].to_summary()
        s["score"] = h["score"]
        s["semantic"] = h["semantic"]
        s["reasons"] = h["reasons"]
        items.append(s)
    return {"items": items, "total": len(items), "as_of": as_of}


@app.get("/api/memories/timeline", dependencies=[Depends(require_auth)])
def memory_timeline(
    start_date: str = Query(default=""),
    end_date: str = Query(default=""),
    allow_sensitive: bool = Query(default=True),
) -> dict[str, Any]:
    init_db()
    store = _get_store()
    items = get_timeline(store, start_date=start_date, end_date=end_date, allow_sensitive=allow_sensitive)
    return {"items": items, "total": len(items)}


@app.get("/api/memories/graph", dependencies=[Depends(require_auth)])
def memory_graph(allow_sensitive: bool = Query(default=True)) -> dict[str, Any]:
    init_db()
    store = _get_store()
    return get_knowledge_graph(store, allow_sensitive=allow_sensitive)


@app.get("/api/memories/file", dependencies=[Depends(require_auth)])
def get_memory_file(path: str = Query(..., min_length=1)) -> dict[str, Any]:
    store = _get_store()
    try:
        doc = store.read_doc(path)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return {
        **doc.to_summary(),
        "frontmatter": doc.frontmatter,
        "body": doc.body,
        "raw": doc.raw,
        "emotions_detail": doc.emotions,
    }


@app.put("/api/memories/file", dependencies=[Depends(require_auth)])
def save_memory_file(req: SaveFileRequest) -> dict[str, Any]:
    init_db()
    store = _get_store()
    try:
        if req.create_only:
            target = store.resolve_safe_path(req.path)
            if target.exists():
                existing = target.read_text(encoding="utf-8")
                wanted = req.content if req.content.endswith("\n") else req.content + "\n"
                if existing == wanted:
                    rel = target.relative_to(store.vault_path).as_posix()
                    return {"ok": True, "path": rel, "snapshot": None, "duplicate": True}
                raise HTTPException(status_code=409, detail="同名记忆已存在，请换个标题")
        saved_rel = store.write_doc(req.path, req.content, action="update")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    snap = create_snapshot(store.vault_path, req.commit_message or f"edit: 手动编辑 {saved_rel}")
    sync_vault_index(store)
    trigger_basic_memory_reindex()
    return {"ok": True, "path": saved_rel, "snapshot": snap}


@app.delete("/api/memories/file", dependencies=[Depends(require_auth)])
def delete_memory_file(path: str = Query(..., min_length=1)) -> dict[str, Any]:
    init_db()
    store = _get_store()
    try:
        deleted_rel = store.delete_doc(path)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    snap = create_snapshot(store.vault_path, f"delete: 删除记忆 {deleted_rel}")
    sync_vault_index(store)
    trigger_basic_memory_reindex()
    return {"ok": True, "path": deleted_rel, "snapshot": snap}


@app.get("/api/vault/export", dependencies=[Depends(require_auth)])
def export_vault_archive() -> Response:
    store = _get_store()
    data = store.export_vault_zip_bytes()
    return Response(
        content=data,
        media_type="application/zip",
        headers={"Content-Disposition": 'attachment; filename="decision-vault-backup.zip"'},
    )


@app.post("/api/inbox", dependencies=[Depends(require_auth)])
def add_inbox_note(req: InboxRequest) -> dict[str, Any]:
    init_db()
    store = _get_store()
    if req.client_id and not claim_client_op(req.client_id, "inbox"):
        return {"ok": True, "path": "99-收件箱/inbox.md", "snapshot": None, "duplicate": True}
    try:
        saved_rel = store.append_inbox(req.text, req.mood)
    except Exception:
        if req.client_id:
            release_client_op(req.client_id)
        raise
    snap = create_snapshot(store.vault_path, "inbox: 速记追加")
    sync_vault_index(store)
    trigger_basic_memory_reindex()
    return {"ok": True, "path": saved_rel, "snapshot": snap}


# ---------- Chat & Streaming Decision Advisor (Persisted in SQLite) ----------


def _prepare_chat_context(req: ChatRequest):
    init_db()
    store = _get_store()
    provider = _select_provider(req.provider_id)

    user_query = "\n".join(m.content for m in req.messages[-3:] if m.role == "user")
    core_docs = store.load_core_self(allow_sensitive=req.allow_sensitive)
    include_inbox = req.mode == "reflect" or ("收件箱" in user_query)

    hits = hybrid_search(
        store,
        user_query,
        top_k=8 if req.mode in {"decision", "reflect"} else 5,
        allow_sensitive=req.allow_sensitive,
        include_core=False,
        include_inbox=include_inbox,
        as_of=req.as_of,
    )
    retrieved_docs = [h["doc"] for h in hits]

    system_prompt = build_chat_system_prompt(
        store,
        req.mode,
        core_docs,
        retrieved_docs,
        allow_sensitive=req.allow_sensitive,
    )

    references = [
        {
            "path": d.rel_path,
            "title": d.title,
            "category": d.category_label,
            "importance": d.importance,
            "source": "核心自我",
            "reasons": ["常驻核心记忆"],
        }
        for d in core_docs
    ] + [
        {
            "path": h["doc"].rel_path,
            "title": h["doc"].title,
            "category": h["doc"].category_label,
            "importance": h["doc"].importance,
            "source": "4路混合召回",
            "reasons": h["reasons"],
        }
        for h in hits
    ]

    # Ensure or create SQLite session and persist latest user turn
    session_id = (client_chat_session(req.client_id) if req.client_id else None) or req.session_id
    latest_user = next((m.content for m in reversed(req.messages) if m.role == "user"), "")
    if not session_id or not get_session(session_id):
        sess = create_session(title=_auto_title(latest_user), mode=req.mode, provider_id=provider.id)
        session_id = sess["id"]
    else:
        existing = get_session(session_id)
        if existing and existing["title"] == "新对话" and latest_user:
            update_session(session_id, title=_auto_title(latest_user), mode=req.mode, provider_id=provider.id)
        else:
            update_session(session_id, mode=req.mode, provider_id=provider.id)

    prior_reply = None
    if req.client_id and latest_user:
        session_id, user_message_id, fresh = claim_chat_turn(req.client_id, session_id, latest_user)
        if not fresh:
            prior_reply = reply_after(session_id, user_message_id)
    elif latest_user:
        append_message(session_id, "user", latest_user)

    msg_dicts = [{"role": m.role, "content": m.content} for m in req.messages[-20:]]
    return provider, system_prompt, msg_dicts, references, session_id, prior_reply


@app.post("/api/chat", dependencies=[Depends(require_auth)])
async def chat_with_advisor(req: ChatRequest) -> dict[str, Any]:
    provider, system_prompt, msg_dicts, references, session_id, prior_reply = _prepare_chat_context(req)
    effective_effort = (
        normalize_reasoning_effort(req.reasoning_effort)
        if req.reasoning_effort is not None
        else normalize_reasoning_effort(provider.reasoning_effort)
    )
    if prior_reply:
        return {
            "session_id": session_id,
            "reply": prior_reply["content"],
            "reasoning": prior_reply["reasoning"],
            "model": prior_reply["model"],
            "provider_id": provider.id,
            "provider_name": prior_reply["provider_name"],
            "reasoning_effort": effective_effort,
            "references": json.loads(prior_reply["references_json"] or "[]"),
            "replayed": True,
        }
    try:
        result = await call_llm(
            provider,
            system_prompt,
            msg_dicts,
            reasoning_effort=effective_effort,
        )
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    append_message(
        session_id,
        "assistant",
        result.content,
        reasoning=result.reasoning,
        model=result.model,
        provider_name=provider.name,
        references=references,
    )

    return {
        "session_id": session_id,
        "reply": result.content,
        "reasoning": result.reasoning,
        "model": result.model,
        "provider_id": provider.id,
        "provider_name": provider.name,
        "reasoning_effort": effective_effort,
        "references": references,
    }


@app.post("/api/chat/stream", dependencies=[Depends(require_auth)])
async def chat_stream_with_advisor(req: ChatRequest) -> StreamingResponse:
    provider, system_prompt, msg_dicts, references, session_id, prior_reply = _prepare_chat_context(req)
    effective_effort = (
        normalize_reasoning_effort(req.reasoning_effort)
        if req.reasoning_effort is not None
        else normalize_reasoning_effort(provider.reasoning_effort)
    )

    async def event_generator():
        meta = {
            "type": "meta",
            "session_id": session_id,
            "provider_id": provider.id,
            "provider_name": provider.name,
            "model": provider.model,
            "reasoning_effort": effective_effort,
            "references": references,
        }
        yield f"data: {json.dumps(meta, ensure_ascii=False)}\n\n"
        if prior_reply:
            replay = {"type": "text", "delta": prior_reply["content"], "replayed": True}
            yield f"data: {json.dumps(replay, ensure_ascii=False)}\n\n"
            yield f"data: {json.dumps({'type': 'done', 'session_id': session_id}, ensure_ascii=False)}\n\n"
            return

        full_text: list[str] = []
        full_reasoning: list[str] = []
        try:
            async for chunk in stream_llm(
                provider,
                system_prompt,
                msg_dicts,
                reasoning_effort=effective_effort,
            ):
                if chunk["type"] == "text":
                    full_text.append(chunk["delta"])
                elif chunk["type"] == "reasoning":
                    full_reasoning.append(chunk["delta"])
                yield f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n"
        except ProviderError as exc:
            err_msg = str(exc)
            yield f"data: {json.dumps({'type': 'error', 'detail': err_msg}, ensure_ascii=False)}\n\n"
            return

        content_str = "".join(full_text).strip()
        reasoning_str = "".join(full_reasoning).strip()
        if content_str:
            append_message(
                session_id,
                "assistant",
                content_str,
                reasoning=reasoning_str,
                model=provider.model,
                provider_name=provider.name,
                references=references,
            )
        yield f"data: {json.dumps({'type': 'done', 'session_id': session_id}, ensure_ascii=False)}\n\n"

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# ---------- Semi-Auto Memory Proposals ----------


def _enrich_proposals(store: MemoryStore, raw_proposals: list[dict[str, Any]], *, id_prefix: str = "prop") -> list[dict[str, Any]]:
    enriched: list[dict[str, Any]] = []
    for idx, p in enumerate(raw_proposals):
        rel_path = str(p.get("path", "")).strip()
        content = str(p.get("content", "")).strip()
        if not rel_path or not content:
            continue
        action = str(p.get("action", "create")).strip().lower()
        if action not in {"create", "update", "append"}:
            action = "create"
        try:
            full_path = store.resolve_safe_path(rel_path)
            safe_rel = full_path.relative_to(store.vault_path).as_posix()
        except ValueError:
            continue

        exists = full_path.exists()
        if exists and action == "create":
            action = "update"
        level = store.infer_write_level(safe_rel, action)
        diff = store.compute_diff(safe_rel, content, action) if exists else ""

        enriched.append(
            {
                "id": f"{id_prefix}_{idx + 1}",
                "action": action,
                "path": safe_rel,
                "exists": exists,
                "level": level,
                "title": str(p.get("title") or Path(safe_rel).stem),
                "summary": str(p.get("summary") or "待确认写入的记忆条目"),
                "importance": int(p.get("importance") or 6),
                "emotions": p.get("emotions") if isinstance(p.get("emotions"), list) else [],
                "relations": p.get("relations") if isinstance(p.get("relations"), list) else [],
                "privacy": str(p.get("privacy") or "private"),
                "evidence": str(p.get("evidence") or ""),
                "content": content,
                "diff": diff,
            }
        )
    return enriched


@app.post("/api/proposals/extract", dependencies=[Depends(require_auth)])
async def extract_proposals(req: ExtractRequest) -> dict[str, Any]:
    init_db()
    store = _get_store()
    provider = _select_provider(req.provider_id)
    existing_paths = [d.rel_path for d in store.scan_all(include_system=False)]

    sys_prompt, user_msgs = build_extraction_prompts(
        store,
        [{"role": m.role, "content": m.content} for m in req.messages],
        existing_paths,
        allow_sensitive=req.allow_sensitive,
    )

    try:
        result = await call_llm(provider, sys_prompt, user_msgs, temperature=0.2, max_tokens=4096, reasoning_effort="auto")
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    try:
        raw_proposals = parse_proposals_json(result.content)
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"模型返回的提案无法解析为 JSON，请重试。原始返回片段：{result.content[:240]}",
        ) from exc

    enriched = _enrich_proposals(store, raw_proposals, id_prefix="prop")
    if enriched:
        log_proposals(req.session_id, enriched, status="pending")

    return {"proposals": enriched, "provider_name": provider.name}


@app.post("/api/proposals/commit", dependencies=[Depends(require_auth)])
def commit_proposals(req: CommitRequest) -> dict[str, Any]:
    init_db()
    store = _get_store()
    written = []
    for item in req.items:
        content = item.content
        if item.privacy and content.startswith("---"):
            if re.search(r"^privacy:\s*\w+", content, re.MULTILINE):
                content = re.sub(r"^privacy:\s*\w+", f"privacy: {item.privacy}", content, count=1, flags=re.MULTILINE)
        try:
            saved_rel = store.write_doc(item.path, content, action=item.action)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=f"{item.path}: {exc}") from exc
        written.append(saved_rel)

    msg = req.commit_message or f"memory: 半自动确认写入 {len(written)} 项 ({', '.join(Path(p).stem for p in written[:3])})"
    snap = create_snapshot(store.vault_path, msg)
    log_proposals(req.session_id, [i.model_dump() for i in req.items], status="committed", committed_paths=written)
    sync_vault_index(store)
    trigger_basic_memory_reindex()

    if any(p.startswith("00-核心自我/") for p in written):
        st = evaluate_onboarding_status(store)
        if st["completeness"] >= 40 and st["onboarding_state"] != "completed":
            set_onboarding_state("completed")

    return {"ok": True, "written": written, "snapshot": snap}


# ---------- Onboarding & Profile Initialization ----------


@app.get("/api/onboarding/status", dependencies=[Depends(require_auth)])
def onboarding_status() -> dict[str, Any]:
    init_db()
    store = _get_store()
    out = evaluate_onboarding_status(store)
    out["advisor_styles"] = [
        {"id": k, "label": v["label"], "description": v["description"]} for k, v in ADVISOR_STYLES.items()
    ]
    return out


@app.post("/api/onboarding/state", dependencies=[Depends(require_auth)])
def update_onboarding_state(req: OnboardingStateRequest) -> dict[str, Any]:
    init_db()
    store = _get_store()
    try:
        set_onboarding_state(req.state.strip())
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, "status": evaluate_onboarding_status(store)}


@app.post("/api/onboarding/quick-profile", dependencies=[Depends(require_auth)])
def submit_quick_profile(req: QuickProfileRequest) -> dict[str, Any]:
    init_db()
    store = _get_store()
    proposals = build_quick_profile_proposals(store, req.model_dump())
    if not proposals:
        raise HTTPException(status_code=400, detail="请至少填写一项关于你的信息后再保存")

    if not req.commit:
        return {
            "ok": True,
            "written": [],
            "proposals": proposals,
            "status": evaluate_onboarding_status(store),
        }

    written: list[str] = []
    for p in proposals:
        saved_rel = store.write_doc(p["path"], p["content"], action="update")
        written.append(saved_rel)

    set_onboarding_state("completed")
    snap = create_snapshot(
        store.vault_path,
        f"onboarding: 快速建立核心自我档案 ({', '.join(Path(w).stem for w in written)})",
    )
    log_proposals(None, proposals, status="committed", committed_paths=written)
    sync_vault_index(store)
    trigger_basic_memory_reindex()

    return {
        "ok": True,
        "written": written,
        "proposals": proposals,
        "snapshot": snap,
        "status": evaluate_onboarding_status(store),
    }


@app.post("/api/onboarding/interview/start", dependencies=[Depends(require_auth)])
async def start_onboarding_interview(req: InterviewStartRequest | None = None) -> dict[str, Any]:
    init_db()
    body = req or InterviewStartRequest()
    store = _get_store()
    status = evaluate_onboarding_status(store)

    focus_slot = body.focus_slot if (body.focus_slot and body.focus_slot in CORE_SLOT_BY_ID) else None
    title = (
        f"冷启动访谈 · {CORE_SLOT_BY_ID[focus_slot]['title']}"
        if focus_slot
        else "冷启动访谈 · 认识彼此"
    )

    provider = None
    try:
        provider = _select_provider(body.provider_id)
    except HTTPException:
        provider = None

    opening_text = ""
    used_fallback = False
    model_name = ""
    provider_name = ""

    if provider is not None:
        has_cred = bool(provider.api_key) or provider.kind == "chatgpt_oauth"
        if has_cred:
            try:
                sys_prompt, user_msgs = build_interview_kickoff_prompts(
                    store,
                    focus_slot=focus_slot,
                    allow_sensitive=body.allow_sensitive,
                )
                res = await call_llm(provider, sys_prompt, user_msgs, max_tokens=1024, timeout=45.0, reasoning_effort="auto")
                opening_text = (res.content or "").strip()
                model_name = res.model or provider.model
                provider_name = provider.name
            except ProviderError:
                opening_text = ""

    if not opening_text:
        used_fallback = True
        opening_text = build_interview_opening_fallback(status, focus_slot=focus_slot)
        provider_name = "引导向导"

    sess = create_session(
        title=title,
        mode="interview",
        provider_id=provider.id if provider else "",
    )
    append_message(
        sess["id"],
        "assistant",
        opening_text,
        model=model_name,
        provider_name=provider_name,
    )

    return {
        "ok": True,
        "session_id": sess["id"],
        "title": title,
        "mode": "interview",
        "opening_message": opening_text,
        "used_fallback": used_fallback,
        "status": status,
    }


# ---------- Cross-Agent Memory Importer ----------


@app.get("/api/import/prompts", dependencies=[Depends(require_auth)])
def get_import_prompts() -> dict[str, Any]:
    return {"templates": IMPORT_PROMPT_TEMPLATES}


@app.post("/api/import/preview", dependencies=[Depends(require_auth)])
def preview_agent_memory_import(req: ImportPreviewRequest) -> dict[str, Any]:
    files_payload = [{"filename": f.filename, "content_base64": f.content_base64} for f in req.files]
    result = parse_import_payload(
        raw_text=req.raw_text,
        files=files_payload,
        source_hint=req.source_hint,
    )
    return result


@app.post("/api/import/extract", dependencies=[Depends(require_auth)])
async def extract_imported_memories(req: ImportExtractRequest) -> dict[str, Any]:
    init_db()
    store = _get_store()
    provider = _select_provider(req.provider_id)
    existing_paths = [d.rel_path for d in store.scan_all(include_system=False)]

    batches = batch_import_chunks([i.model_dump() for i in req.items])
    if not batches:
        raise HTTPException(status_code=400, detail="没有可提炼的有效记忆内容")

    merged_by_path: dict[str, dict[str, Any]] = {}
    ordered_raw: list[dict[str, Any]] = []

    for batch_text in batches:
        sys_prompt, user_msgs = build_import_extraction_prompts(
            store,
            batch_text,
            req.source_label or "外部 Agent 记忆",
            existing_paths,
            allow_sensitive=req.allow_sensitive,
        )
        try:
            result = await call_llm(provider, sys_prompt, user_msgs, temperature=0.2, max_tokens=4096, timeout=150.0, reasoning_effort="auto")
        except ProviderError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

        try:
            raw_list = parse_proposals_json(result.content)
        except Exception as exc:
            raise HTTPException(
                status_code=502,
                detail=f"模型返回的导入提案无法解析为 JSON，请重试。原始片段：{result.content[:240]}",
            ) from exc

        for item in raw_list:
            path_key = str(item.get("path", "")).strip()
            if not path_key:
                continue
            if path_key in merged_by_path:
                # If multiple batches touch the same file, append the newer body cleanly
                prev = merged_by_path[path_key]
                prev_content = str(prev.get("content", "")).rstrip()
                new_content = str(item.get("content", "")).strip()
                if new_content and new_content not in prev_content:
                    # Strip duplicate frontmatter when combining two batches targeting the same path
                    new_body = re.sub(r"^---\s*\n.*?\n---\s*\n?", "", new_content, count=1, flags=re.DOTALL).strip()
                    if new_body:
                        prev["content"] = f"{prev_content}\n\n{new_body}"
                        prev["summary"] = f"{prev.get('summary', '')}；{item.get('summary', '')}".strip("；")
            else:
                merged_by_path[path_key] = item
                ordered_raw.append(item)

    enriched = _enrich_proposals(store, ordered_raw, id_prefix="impprop")
    if enriched:
        log_proposals(None, enriched, status="pending")

    return {
        "proposals": enriched,
        "provider_name": provider.name,
        "batches_processed": len(batches),
    }


# ---------- Git History & Config ----------


@app.get("/api/git/history", dependencies=[Depends(require_auth)])
def git_history(limit: int = Query(default=20, ge=1, le=50)) -> dict[str, Any]:
    store = _get_store()
    return {"items": list_snapshots(store.vault_path, limit=limit)}


@app.get("/api/config", dependencies=[Depends(require_auth)])
def get_config() -> dict[str, Any]:
    return serialize_public_config(load_config())


@app.put("/api/config", dependencies=[Depends(require_auth)])
def update_config(payload: dict[str, Any]) -> dict[str, Any]:
    current = load_config()
    try:
        merged = merge_config_update(current, payload)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"配置格式错误: {exc}") from exc
    save_config(merged)
    return serialize_public_config(merged)


@app.post("/api/config/test", dependencies=[Depends(require_auth)])
async def test_provider(req: TestProviderRequest) -> dict[str, Any]:
    provider = _select_provider(req.provider_id)
    try:
        res = await call_llm(
            provider,
            "你是连通性测试助手。",
            [{"role": "user", "content": "请只回复：连接成功"}],
            temperature=0.0,
            max_tokens=512,
            timeout=30.0,
            reasoning_effort="auto",
        )
    except ProviderError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"ok": True, "provider": provider.name, "model": res.model, "reply": res.content or "连接成功"}


# ---------- Official Sign in with ChatGPT (OAuth 2.0 PKCE + Plan Usage) ----------


def _resolve_loopback_port(request: Request) -> int:
    host = (request.url.hostname or "").lower()
    if host in {"127.0.0.1", "localhost"} and request.url.port:
        return int(request.url.port)
    return get_default_loopback_port()


def _sync_provider_after_chatgpt_oauth(status: dict[str, Any]) -> dict[str, Any]:
    cfg = load_config()
    updated = ensure_chatgpt_oauth_provider(
        cfg,
        discovered_models=status.get("available_models"),
        activate_if_no_other_key=True,
    )
    save_config(updated)
    return serialize_public_config(updated)


def _render_oauth_result_html(
    *,
    success: bool,
    title: str,
    subtitle: str,
    details: list[tuple[str, str]] | None = None,
    warning: str = "",
) -> str:
    badge_bg = "#e6f0ec" if success else "#fee2e2"
    badge_fg = "#2c5e4f" if success else "#b91c1c"
    badge_icon = "✅" if success else "⚠️"
    detail_rows = "".join(
        f'<div class="row"><span class="k">{html.escape(k)}</span><span class="v">{html.escape(v)}</span></div>'
        for k, v in (details or [])
        if v
    )
    warn_html = (
        f'<div class="warn">{html.escape(warning)}</div>'
        if warning
        else ""
    )
    post_msg_js = (
        '<script>try{if(window.opener){window.opener.postMessage({type:"chatgpt-oauth-success"},"*");}}catch(e){}</script>'
        if success
        else ""
    )
    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>{html.escape(title)} · 成长决策顾问</title>
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; background:#f6f4ef; color:#1f2421; display:grid; place-items:center; min-height:100vh; margin:0; padding:20px; }}
    .card {{ background:#fff; border:1px solid #e3ded3; border-radius:18px; padding:28px 30px; max-width:460px; width:100%; box-shadow:0 6px 24px rgba(24,24,20,0.07); }}
    .badge {{ display:inline-flex; align-items:center; gap:6px; padding:5px 12px; border-radius:999px; font-size:13px; font-weight:600; background:{badge_bg}; color:{badge_fg}; margin-bottom:14px; }}
    h1 {{ margin:0 0 8px; font-size:21px; line-height:1.35; }}
    p {{ margin:0 0 18px; color:#6c6a64; font-size:14px; line-height:1.65; }}
    .box {{ background:#f8f7f3; border:1px solid #eae6dc; border-radius:12px; padding:12px 14px; margin-bottom:16px; }}
    .row {{ display:flex; justify-content:space-between; gap:12px; padding:5px 0; font-size:13px; }}
    .k {{ color:#6c6a64; }}
    .v {{ color:#1f2421; font-weight:500; text-align:right; word-break:break-all; }}
    .warn {{ background:#fef3c7; border:1px solid #f59e0b55; color:#92400e; border-radius:10px; padding:10px 12px; font-size:12.5px; line-height:1.55; margin-bottom:16px; }}
    .hint {{ font-size:12.5px; color:#6c6a64; text-align:center; margin-top:6px; }}
  </style>
</head>
<body>
  <div class="card">
    <div class="badge">{badge_icon} 成长决策顾问 · Sign in with ChatGPT</div>
    <h1>{html.escape(title)}</h1>
    <p>{html.escape(subtitle)}</p>
    {f'<div class="box">{detail_rows}</div>' if detail_rows else ''}
    {warn_html}
    <div class="hint">现在可以直接关闭此浏览器标签页，回到「成长决策顾问」继续对话。</div>
  </div>
  {post_msg_js}
</body>
</html>"""


@app.get("/api/chatgpt-oauth/status", dependencies=[Depends(require_auth)])
def chatgpt_oauth_status(state: str = Query(default="")) -> dict[str, Any]:
    out = get_public_oauth_status()
    if state:
        out["flow"] = get_pending_flow_status(state)
    return out


@app.post("/api/chatgpt-oauth/start", dependencies=[Depends(require_auth)])
async def chatgpt_oauth_start(
    request: Request,
    req: ChatGPTOAuthStartRequest | None = None,
) -> dict[str, Any]:
    body = req or ChatGPTOAuthStartRequest()
    port = body.redirect_port or _resolve_loopback_port(request)
    try:
        return await start_chatgpt_oauth_flow(
            port=port,
            force_register=body.force_register,
        )
    except ChatGPTOAuthError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.get("/auth/callback", response_class=HTMLResponse)
async def chatgpt_oauth_loopback_callback(
    code: str = Query(default=""),
    state: str = Query(default=""),
    client_id: str = Query(default=""),
    issued_client_id: str = Query(default=""),
    error: str = Query(default=""),
    error_description: str = Query(default=""),
) -> HTMLResponse:
    try:
        status = await complete_chatgpt_oauth_callback(
            code=code,
            state=state,
            callback_client_id=client_id or issued_client_id,
            error=error,
            error_description=error_description,
        )
        _sync_provider_after_chatgpt_oauth(status)
    except ChatGPTOAuthError as exc:
        page = _render_oauth_result_html(
            success=False,
            title="ChatGPT 授权未完成",
            subtitle=str(exc),
            warning="常见排查：请确认是从本程序设置页点击生成的最新链接进入、已登录可访问的 ChatGPT 账号，且网络代理未拦截 OpenAI 回调。",
        )
        return HTMLResponse(page, status_code=400)

    models = status.get("available_models") or []
    warn = ""
    if not status.get("has_plan_usage_scope"):
        warn = (
            "提示：本次授权令牌中未检测到 chatgpt.tokens.use.direct 订阅额度权限。"
            "如果调用模型提示 403，请返回设置页点击「重新授权」并确保勾选允许使用你的 ChatGPT 套餐额度。"
        )
    details = [
        ("已登录账号", status.get("account_email") or status.get("account_name") or "ChatGPT 用户"),
        ("订阅方案", (status.get("plan_type") or "ChatGPT 订阅").upper() if status.get("plan_type") else "ChatGPT 订阅"),
        ("套餐额度调用权限", "已授予 (chatgpt.tokens.use.direct)" if status.get("has_plan_usage_scope") else "待确认"),
        ("同步可用模型", f"{len(models)} 个" if models else "已就绪（可在设置页刷新模型列表）"),
    ]
    page = _render_oauth_result_html(
        success=True,
        title="ChatGPT 授权登录成功",
        subtitle="你的本地程序已安全保存 OAuth 令牌并自动配置「ChatGPT 订阅授权」模型预设，现在可以直接调用你的 GPT 额度和模型。",
        details=details,
        warning=warn,
    )
    return HTMLResponse(page, status_code=200)


@app.post("/api/chatgpt-oauth/complete-callback", dependencies=[Depends(require_auth)])
async def chatgpt_oauth_complete_callback_api(req: ChatGPTOAuthCompleteCallbackRequest) -> dict[str, Any]:
    if req.callback_url.strip():
        parsed = parse_callback_url_params(req.callback_url)
        code = parsed["code"]
        state = parsed["state"]
        cid = parsed["client_id"]
        err = parsed["error"]
        err_desc = parsed["error_description"]
    else:
        code = req.code
        state = req.state
        cid = req.client_id
        err = ""
        err_desc = ""

    try:
        status = await complete_chatgpt_oauth_callback(
            code=code,
            state=state,
            callback_client_id=cid,
            error=err,
            error_description=err_desc,
        )
    except ChatGPTOAuthError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    public_cfg = _sync_provider_after_chatgpt_oauth(status)
    return {"ok": True, "oauth": status, "config": public_cfg}


@app.post("/api/chatgpt-oauth/models/refresh", dependencies=[Depends(require_auth)])
async def chatgpt_oauth_refresh_models() -> dict[str, Any]:
    try:
        models = await refresh_chatgpt_models()
    except ChatGPTOAuthError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    status = get_public_oauth_status()
    public_cfg = _sync_provider_after_chatgpt_oauth(status)
    return {"ok": True, "models": models, "oauth": status, "config": public_cfg}


@app.post("/api/chatgpt-oauth/logout", dependencies=[Depends(require_auth)])
async def chatgpt_oauth_logout(req: ChatGPTOAuthLogoutRequest | None = None) -> dict[str, Any]:
    body = req or ChatGPTOAuthLogoutRequest()
    status = await logout_chatgpt_oauth(reset_client=body.reset_client)
    public_cfg = serialize_public_config(load_config())
    return {"ok": True, "oauth": status, "config": public_cfg}


# ---------- Pure API Service Root (Web UI Retired -> demo-mvp/) ----------


@app.get("/")
def service_root() -> dict[str, Any]:
    return {
        "service": "decision-advisor-api",
        "version": APP_VERSION,
        "deployment_mode": get_deployment_mode(),
        "api_base": "/api",
        "mcp_endpoint": "/mcp",
        "health": "/api/health",
        "web_ui": "disabled",
    }
