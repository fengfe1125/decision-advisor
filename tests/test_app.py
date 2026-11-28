from __future__ import annotations

import base64
import hashlib
import io
import json
import zipfile
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.config import AppConfig, EmbeddingConfig, ProviderPreset, save_config
from app.db import append_message, create_session, init_db
from app.main import app
from app.memory_store import MemoryStore, strip_private_blocks
from app.prompts import parse_proposals_json
from app.providers import build_provider_request, parse_provider_response
from app.search_index import EmbeddingEngine, hybrid_search, sync_vault_index


class FakeChineseEmbedder(EmbeddingEngine):
    """Deterministic lightweight semantic embedder for unit tests (no network download)."""

    def __init__(self):
        super().__init__(EmbeddingConfig(mode="local_bge_zh", local_model="fake-bge-zh"))

    def embed_texts(self, texts: list[str]) -> list[np.ndarray | None]:
        concepts = ["焦虑", "高压", "自由", "自主权", "张伟", "朋友", "2024", "2026", "offer", "成长"]
        out: list[np.ndarray | None] = []
        for t in texts:
            vec = np.array([1.0 if c in t else 0.05 for c in concepts], dtype=np.float32)
            norm = np.linalg.norm(vec)
            out.append(vec / norm if norm > 0 else vec)
        return out


@pytest.fixture()
def temp_env(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    vault = tmp_path / "决策"
    (vault / "00-核心自我").mkdir(parents=True)
    (vault / "01-人生章节").mkdir(parents=True)
    (vault / "02-经历与感受" / "2024").mkdir(parents=True)
    (vault / "02-经历与感受" / "2026").mkdir(parents=True)
    (vault / "03-重要关系").mkdir(parents=True)
    (vault / "04-决策实验室" / "进行中").mkdir(parents=True)
    (vault / "99-收件箱").mkdir(parents=True)
    (vault / "_系统协议").mkdir(parents=True)

    (vault / "_系统协议" / "顾问人格与工作协议.md").write_text("# 协议\n反讨好、重证据。", encoding="utf-8")
    (vault / "00-核心自我" / "values.md").write_text(
        "---\ntitle: 核心价值观\nprivacy: private\n---\n\n# 核心价值观\n1. 自主权\n<private>绝密银行卡123456</private>\n",
        encoding="utf-8",
    )
    (vault / "00-核心自我" / "secret_trauma.md").write_text(
        "---\ntitle: 高度敏感记忆\nprivacy: sensitive\n---\n\n# 高度敏感\n绝对不能发给云端的内容\n",
        encoding="utf-8",
    )
    (vault / "02-经历与感受" / "2024" / "2024-05-01-旧职业焦虑.md").write_text(
        "---\n"
        "id: evt_2024\n"
        "title: 2024年第一次高压焦虑\n"
        "event_time: 2024-05-01\n"
        "importance: 8\n"
        "people: [张伟]\n"
        "emotions:\n"
        "  - name: 焦虑\n"
        "    intensity: 8\n"
        "    valence: negative\n"
        "    trigger: 持续加班失去自主权\n"
        "privacy: private\n"
        "---\n\n# 2024年第一次高压焦虑\n\n当时非常焦虑。\n",
        encoding="utf-8",
    )
    (vault / "02-经历与感受" / "2026" / "2026-06-01-放弃高压岗位.md").write_text(
        "---\n"
        "id: evt_2026\n"
        "title: 放弃高压高薪岗位\n"
        "event_time: 2026-06-01\n"
        "importance: 9\n"
        "people: [张伟]\n"
        "emotions:\n"
        "  - name: 释然\n"
        "    intensity: 8\n"
        "    valence: positive\n"
        "    trigger: 拒绝offer后睡得很香\n"
        "privacy: private\n"
        "---\n\n# 放弃高压高薪岗位\n\n拒绝之后睡得特别踏实，参见 [[03-重要关系/张伟]]。\n",
        encoding="utf-8",
    )
    (vault / "03-重要关系" / "张伟.md").write_text(
        "---\ntitle: 张伟\nprivacy: private\n---\n\n# 张伟\n\n很好的朋友，常给我泼冷水。\n",
        encoding="utf-8",
    )
    (vault / "99-收件箱" / "inbox.md").write_text("---\ntitle: 收件箱\nprivacy: private\n---\n\n# 收件箱\n", encoding="utf-8")

    cfg_path = tmp_path / "config.local.json"
    oauth_path = tmp_path / "chatgpt_oauth.local.json"
    git_dir = tmp_path / ".memory-git"
    db_path = tmp_path / "advisor_state.db"
    monkeypatch.setenv("ADVISOR_CONFIG_PATH", str(cfg_path))
    monkeypatch.setenv("ADVISOR_CHATGPT_OAUTH_PATH", str(oauth_path))
    monkeypatch.setenv("DECISION_GIT_DIR", str(git_dir))
    monkeypatch.setenv("DECISION_DB_PATH", str(db_path))

    cfg = AppConfig(
        vault_path=str(vault),
        access_token="",
        public_base_url="https://decision.example.com",
        active_provider_id="deepseek-default",
        embedding=EmbeddingConfig(mode="disabled"),
        providers=[
            ProviderPreset(
                id="deepseek-default",
                name="DeepSeek",
                kind="deepseek",
                base_url="https://api.deepseek.com/v1",
                api_key="sk-secret-deepseek-1234567890",
                model="deepseek-v4-pro",
            ),
            ProviderPreset(
                id="claude-native",
                name="Claude",
                kind="claude",
                base_url="https://api.anthropic.com",
                api_key="sk-ant-1234567890",
                model="claude-sonnet-5-5",
            ),
        ],
    )
    save_config(cfg)
    init_db()
    return {"vault": vault, "cfg_path": cfg_path, "git_dir": git_dir, "db_path": db_path}


def test_provider_request_builders():
    ds = ProviderPreset(id="d", name="DS", kind="deepseek", base_url="https://api.deepseek.com", api_key="k1", model="deepseek-v4-pro")
    url, headers, body = build_provider_request(ds, "sys", [{"role": "user", "content": "hi"}], stream=True)
    assert url == "https://api.deepseek.com/v1/chat/completions"
    assert headers["Authorization"] == "Bearer k1"
    assert body["stream"] is True
    assert body["max_tokens"] == 4096
    assert "temperature" not in body
    parsed = parse_provider_response(ds, {"choices": [{"message": {"content": "答复", "reasoning_content": "思考"}}], "model": "deepseek-v4-pro"})
    assert parsed.content == "答复" and parsed.reasoning == "思考"

    openai_new = ProviderPreset(id="o", name="OpenAI", kind="openai_compatible", base_url="https://api.openai.com/v1", api_key="k2", model="gpt-6.2-sol")
    url, headers, body = build_provider_request(openai_new, "sys", [{"role": "user", "content": "hi"}], stream=True)
    assert url == "https://api.openai.com/v1/chat/completions"
    assert body["max_completion_tokens"] == 4096
    assert "max_tokens" not in body
    assert "temperature" not in body

    openai_legacy = ProviderPreset(id="ol", name="OpenAI Legacy", kind="openai_compatible", base_url="https://api.openai.com/v1", api_key="k2", model="gpt-4.1")
    _, _, body_legacy = build_provider_request(openai_legacy, "sys", [{"role": "user", "content": "hi"}])
    assert body_legacy["max_tokens"] == 4096
    assert body_legacy["temperature"] == 0.7

    claude = ProviderPreset(id="c", name="Claude", kind="claude", base_url="https://api.anthropic.com", api_key="k3", model="claude-sonnet-5-5")
    url, headers, body = build_provider_request(claude, "sys", [{"role": "user", "content": "hi"}], stream=True)
    assert url == "https://api.anthropic.com/v1/messages"
    assert headers["x-api-key"] == "k3"
    assert body["stream"] is True
    assert body["system"] == "sys"
    assert "temperature" not in body

    claude_legacy = ProviderPreset(id="cl", name="Claude Legacy", kind="claude", base_url="https://api.anthropic.com", api_key="k3", model="claude-sonnet-4-5")
    _, _, claude_legacy_body = build_provider_request(claude_legacy, "sys", [{"role": "user", "content": "hi"}])
    assert claude_legacy_body["temperature"] == 0.7

    gemini = ProviderPreset(id="g", name="Gemini", kind="gemini", base_url="https://generativelanguage.googleapis.com", api_key="k4", model="gemini-4-neon")
    url, headers, body = build_provider_request(gemini, "sys", [{"role": "user", "content": "hi"}, {"role": "assistant", "content": "hello"}], stream=True)
    assert url == "https://generativelanguage.googleapis.com/v1beta/models/gemini-4-neon:streamGenerateContent?alt=sse"
    assert headers["x-goog-api-key"] == "k4"
    assert body["contents"][1]["role"] == "model"
    assert "temperature" not in body["generationConfig"]
    g_parsed = parse_provider_response(
        gemini,
        {
            "candidates": [
                {
                    "content": {
                        "parts": [
                            {"thought": True, "text": "内部推理"},
                            {"text": "最终回答"},
                        ]
                    }
                }
            ]
        },
    )
    assert g_parsed.reasoning == "内部推理" and g_parsed.content == "最终回答"

    gemini_legacy = ProviderPreset(id="gl", name="Gemini Legacy", kind="gemini", base_url="https://generativelanguage.googleapis.com", api_key="k4", model="gemini-2.5-pro")
    _, _, g_legacy_body = build_provider_request(gemini_legacy, "sys", [{"role": "user", "content": "hi"}])
    assert g_legacy_body["generationConfig"]["temperature"] == 0.7


def test_privacy_firewall_and_4way_hybrid_search(temp_env):
    store = MemoryStore(temp_env["vault"])
    embedder = FakeChineseEmbedder()
    stats = sync_vault_index(store, embedder=embedder, force_rebuild=True)
    assert stats["embedded_docs"] == stats["total_docs"]
    assert stats["graph_edges"] >= 2  # wikilink + shared_person(张伟)

    # Privacy firewall: sensitive doc excluded by default
    core = store.load_core_self(allow_sensitive=False)
    assert [d.rel_path for d in core] == ["00-核心自我/values.md"]
    sanitized = store.sanitize_for_llm(core[0], allow_sensitive=False)
    assert "绝密银行卡" not in sanitized

    # 4-way semantic + graph search
    hits = hybrid_search(store, "面对高压高薪offer感到焦虑", top_k=4, embedder=embedder)
    paths = [h["doc"].rel_path for h in hits]
    assert "02-经历与感受/2026/2026-06-01-放弃高压岗位.md" in paths
    assert "02-经历与感受/2024/2024-05-01-旧职业焦虑.md" in paths
    assert "03-重要关系/张伟.md" in paths

    # Bi-temporal as_of query: before end of 2024 -> 2026 event MUST NOT appear!
    hist_hits = hybrid_search(store, "高压焦虑", top_k=5, as_of="2024-12-31", embedder=embedder)
    hist_paths = [h["doc"].rel_path for h in hist_hits]
    assert "02-经历与感受/2024/2024-05-01-旧职业焦虑.md" in hist_paths
    assert "02-经历与感受/2026/2026-06-01-放弃高压岗位.md" not in hist_paths


def test_sqlite_sessions_and_streaming_chat(temp_env, monkeypatch: pytest.MonkeyPatch):
    async def fake_stream_llm(*args, **kwargs):
        yield {"type": "reasoning", "delta": "分析历史中..."}
        yield {"type": "text", "delta": "结合你的过去，"}
        yield {"type": "text", "delta": "建议先小步试错。"}

    monkeypatch.setattr("app.main.stream_llm", fake_stream_llm)

    client = TestClient(app)
    with client.stream(
        "POST",
        "/api/chat/stream",
        json={"messages": [{"role": "user", "content": "我要不要接这个高压offer？"}], "mode": "decision"},
    ) as resp:
        assert resp.status_code == 200
        raw_lines = [line for line in resp.iter_lines() if line.startswith("data:")]

    events = [json.loads(line[5:].strip()) for line in raw_lines]
    meta = next(e for e in events if e["type"] == "meta")
    sid = meta["session_id"]
    assert any(e["type"] == "text" and "小步试错" in e["delta"] for e in events)

    # Confirm persisted in SQLite sessions & messages tables!
    sessions = client.get("/api/sessions").json()["items"]
    assert len(sessions) == 1
    assert sessions[0]["id"] == sid
    assert sessions[0]["message_count"] == 2

    detail = client.get(f"/api/sessions/{sid}").json()
    assert len(detail["messages"]) == 2
    assert detail["messages"][1]["content"] == "结合你的过去，建议先小步试错。"
    assert detail["messages"][1]["reasoning"] == "分析历史中..."

    # Delete session works cleanly
    assert client.delete(f"/api/sessions/{sid}").status_code == 200
    assert client.get("/api/sessions").json()["items"] == []


def test_oauth21_pkce_and_chatgpt_remote_mcp(temp_env):
    client = TestClient(app)
    # Enable access_token password
    assert client.put("/api/config", json={"access_token": "super-secret-pass"}).status_code == 200

    # 1. Unauthenticated /mcp returns 401 with official WWW-Authenticate resource_metadata header
    unauth = client.post("/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "initialize"})
    assert unauth.status_code == 401
    assert "oauth-protected-resource" in unauth.headers.get("www-authenticate", "")

    # 2. Discovery metadata
    prm = client.get("/.well-known/oauth-protected-resource").json()
    assert prm["resource"] == "https://decision.example.com/mcp"
    asm = client.get("/.well-known/oauth-authorization-server").json()
    assert asm["registration_endpoint"] == "https://decision.example.com/oauth/register"

    # 3. Dynamic Client Registration
    reg = client.post("/oauth/register", json={"client_name": "ChatGPT", "redirect_uris": ["https://chatgpt.com/cb"]})
    assert reg.status_code == 201
    client_id = reg.json()["client_id"]

    # 4. PKCE Authorize with correct password
    verifier = "my-random-pkce-verifier-string-1234567890"
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")
    auth_resp = client.post(
        "/oauth/authorize",
        data={
            "client_id": client_id,
            "redirect_uri": "https://chatgpt.com/cb",
            "password": "super-secret-pass",
            "state": "xyz",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "scope": "mcp",
        },
        follow_redirects=False,
    )
    assert auth_resp.status_code == 302
    code = parse_qs(urlparse(auth_resp.headers["location"]).query)["code"][0]

    # 5. Token Exchange validates PKCE verifier
    tok_resp = client.post(
        "/oauth/token",
        data={"grant_type": "authorization_code", "code": code, "code_verifier": verifier},
    )
    assert tok_resp.status_code == 200
    bearer = tok_resp.json()["access_token"]

    # 6. Authorized MCP calls: tools/list + get_core_self (verifies sensitive blocked!) + save_memory
    hdrs = {"Authorization": f"Bearer {bearer}"}
    tl = client.post("/mcp", headers=hdrs, json={"jsonrpc": "2.0", "id": 2, "method": "tools/list"}).json()
    tool_names = [t["name"] for t in tl["result"]["tools"]]
    assert "get_core_self" in tool_names and "search_memories" in tool_names and "save_memory" in tool_names

    core_call = client.post(
        "/mcp",
        headers=hdrs,
        json={"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_core_self", "arguments": {}}},
    ).json()
    core_text = core_call["result"]["content"][0]["text"]
    assert "自主权" in core_text
    assert "绝密银行卡" not in core_text
    assert "绝对不能发给云端的内容" not in core_text

    save_call = client.post(
        "/mcp",
        headers=hdrs,
        json={
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {
                "name": "save_memory",
                "arguments": {
                    "path": "02-经历与感受/2026/2026-11-21-来自ChatGPT记忆.md",
                    "content": "---\ntitle: 来自ChatGPT记忆\nprivacy: private\nimportance: 7\n---\n\n# 测试\n写入成功",
                },
            },
        },
    ).json()
    assert save_call["result"]["isError"] is False
    assert (temp_env["vault"] / "02-经历与感受/2026/2026-11-21-来自ChatGPT记忆.md").exists()
    assert not (temp_env["vault"] / ".git").exists()


def test_mobile_outbox_replays_are_idempotent(temp_env, monkeypatch: pytest.MonkeyPatch):
    calls = []

    async def fake_stream_llm(*args, **kwargs):
        calls.append(1)
        yield {"type": "text", "delta": "离线补传收到"}

    monkeypatch.setattr("app.main.stream_llm", fake_stream_llm)
    client = TestClient(app)

    def stream(body):
        with client.stream("POST", "/api/chat/stream", json=body) as resp:
            assert resp.status_code == 200
            return [json.loads(line[5:]) for line in resp.iter_lines() if line.startswith("data:")]

    body = {"messages": [{"role": "user", "content": "地铁里写的一句话"}], "client_id": "turn-1"}
    first = stream(body)
    sid = first[0]["session_id"]
    # Replaying without the session id (phone never saw `meta`) lands in the same session with no new LLM call.
    second = stream(body)
    assert second[0]["session_id"] == sid
    assert any(e["type"] == "text" and e["delta"] == "离线补传收到" for e in second)
    assert len(calls) == 1
    assert [m["role"] for m in client.get(f"/api/sessions/{sid}").json()["messages"]] == ["user", "assistant"]

    # A turn whose reply never got saved is answered on replay, without duplicating the user message.
    from app.db import claim_chat_turn

    claim_chat_turn("turn-2", sid, "断网前发出的")
    stream({"session_id": sid, "messages": [{"role": "user", "content": "断网前发出的"}], "client_id": "turn-2"})
    assert len(calls) == 2
    roles = [m["role"] for m in client.get(f"/api/sessions/{sid}").json()["messages"]]
    assert roles == ["user", "assistant", "user", "assistant"]

    for _ in range(2):
        assert client.post("/api/inbox", json={"text": "排队的速记", "client_id": "note-1"}).json()["ok"]
    assert (temp_env["vault"] / "99-收件箱/inbox.md").read_text(encoding="utf-8").count("排队的速记") == 1

    memory = {"path": "03-重要关系/小林.md", "content": "# 小林\n手机新建", "create_only": True}
    assert client.put("/api/memories/file", json=memory).status_code == 200
    assert client.put("/api/memories/file", json=memory).json()["duplicate"] is True
    assert client.put("/api/memories/file", json={**memory, "content": "# 小林\n别的"}).status_code == 409


def test_chat_history_requires_separate_mcp_consent(temp_env):
    client = TestClient(app)
    password = "test-advisor-access"
    assert client.put("/api/config", json={"access_token": password}).status_code == 200
    session_id = create_session()["id"]
    append_message(session_id, "user", "手机同步测试 <private>保护内容</private>")
    append_message(session_id, "assistant", "收到", reasoning="内部思考")
    redirect_uri = "https://example.net/callback"
    registration = client.post("/oauth/register", json={"redirect_uris": [redirect_uri]}).json()
    verifier = "test-verifier-for-chat-history-oauth-client-213"
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")

    def authorize(consent: bool) -> str:
        response = client.post(
            "/oauth/authorize",
            data={
                "client_id": registration["client_id"],
                "redirect_uri": redirect_uri,
                "password": password,
                "code_challenge": challenge,
                "scope": "mcp chat_history",
                "allow_chat_history": str(consent).lower(),
            },
            follow_redirects=False,
        )
        assert response.status_code == 302
        code = parse_qs(urlparse(response.headers["location"]).query)["code"][0]
        result = client.post("/oauth/token", data={
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
        })
        assert result.status_code == 200
        return result.json()["access_token"]

    def mcp(token: str, method: str, **params):
        response = client.post("/mcp", headers={"Authorization": f"Bearer {token}"}, json={
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        })
        assert response.status_code == 200
        return response.json()["result"]

    ordinary = authorize(False)
    ordinary_tools = {tool["name"] for tool in mcp(ordinary, "tools/list")["tools"]}
    assert not ordinary_tools & {"list_chat_sessions", "search_chat_history", "get_chat_messages"}
    assert mcp(ordinary, "tools/call", name="list_chat_sessions", arguments={})["isError"]
    assert mcp(ordinary, "tools/call", name="get_chat_messages", arguments={"session_id": session_id})["isError"]
    assert client.get(f"/api/sessions/{session_id}", headers={"Authorization": f"Bearer {ordinary}"}).status_code == 401

    authorized = authorize(True)
    assert "search_chat_history" in {tool["name"] for tool in mcp(authorized, "tools/list")["tools"]}

    def read(name: str, **args):
        result = mcp(authorized, "tools/call", name=name, arguments=args)
        assert not result["isError"]
        return json.loads(result["content"][0]["text"])

    sessions = read("list_chat_sessions")
    assert sessions["items"][0]["id"] == session_id
    assert sessions["items"][0]["message_count"] == 2
    assert sessions["next_before"] is None
    assert read("search_chat_history", query="手机同步")["items"][0]["session_id"] == session_id
    assert read("search_chat_history", query="保护内容")["items"] == []
    first_page = read("get_chat_messages", session_id=session_id, limit=1)
    assert "保护内容" not in first_page["items"][0]["content"]
    second_page = read("get_chat_messages", session_id=session_id, after_id=first_page["next_after_id"])
    assert second_page["items"][0]["content"] == "收到"
    assert "reasoning" not in second_page["items"][0]
    assert client.get(f"/api/sessions/{session_id}", headers={"Authorization": f"Bearer {authorized}"}).status_code == 401


def test_timeline_graph_and_path_traversal(temp_env):
    client = TestClient(app)
    tl = client.get("/api/memories/timeline").json()
    assert tl["total"] >= 2
    assert tl["items"][0]["event_time"] >= tl["items"][-1]["event_time"]

    gr = client.get("/api/memories/graph").json()
    assert len(gr["nodes"]) >= 4
    assert len(gr["edges"]) >= 2

    store = MemoryStore(temp_env["vault"])
    with pytest.raises(ValueError):
        store.resolve_safe_path("../../etc/passwd")
    assert strip_private_blocks("a <private>secret</private> b") == "a [已根据本地隐私规则隐藏] b"
    assert len(parse_proposals_json('```json\n{"proposals": [{"path": "a.md", "content": "x"}]}\n```')) == 1


def test_pure_api_root_vault_export_and_delete(temp_env, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("ADVISOR_DEPLOYMENT_MODE", "remote_vps")
    client = TestClient(app)

    root = client.get("/")
    assert root.status_code == 200
    body = root.json()
    assert body["service"] == "decision-advisor-api"
    assert body["web_ui"] == "disabled"
    assert body["deployment_mode"] == "remote_vps"

    verify = client.post("/api/auth/verify")
    assert verify.status_code == 200
    assert verify.json()["ok"] is True

    health = client.get("/api/health").json()
    assert health["deployment_mode"] == "remote_vps"
    assert "vault_export" in health["capabilities"]

    exp = client.get("/api/vault/export")
    assert exp.status_code == 200
    assert exp.headers["content-type"] == "application/zip"
    with zipfile.ZipFile(io.BytesIO(exp.content), "r") as zf:
        names = zf.namelist()
        assert "00-核心自我/values.md" in names
        assert "03-重要关系/张伟.md" in names

    # Create and delete a temporary memory doc
    put_res = client.put(
        "/api/memories/file",
        json={"path": "99-收件箱/temp_delete_test.md", "content": "---\ntitle: 临时测试\n---\n\n内容"},
    )
    assert put_res.status_code == 200
    assert (temp_env["vault"] / "99-收件箱/temp_delete_test.md").exists()

    del_res = client.delete("/api/memories/file", params={"path": "99-收件箱/temp_delete_test.md"})
    assert del_res.status_code == 200
    assert del_res.json()["ok"] is True
    assert not (temp_env["vault"] / "99-收件箱/temp_delete_test.md").exists()


def _make_fake_jwt(payload: dict) -> str:
    hdr = base64.urlsafe_b64encode(b'{"alg":"RS256","typ":"JWT"}').rstrip(b"=").decode("ascii")
    body = base64.urlsafe_b64encode(json.dumps(payload).encode("utf-8")).rstrip(b"=").decode("ascii")
    return f"{hdr}.{body}.fakesig"


def test_chatgpt_oauth_login_models_and_responses_api(temp_env, monkeypatch: pytest.MonkeyPatch):
    import asyncio
    import httpx
    from app import chatgpt_oauth
    from app.providers import call_llm, stream_llm

    # 1. Verify Responses API request builder for chatgpt_oauth
    gpt_preset = ProviderPreset(
        id="chatgpt-oauth",
        name="ChatGPT 订阅授权",
        kind="chatgpt_oauth",
        base_url="https://api.openai.com/v1",
        model="gpt-5.4",
    )
    url, headers, body = build_provider_request(
        gpt_preset,
        "你是个人成长顾问",
        [
            {"role": "user", "content": "你好"},
            {"role": "assistant", "content": "你好！"},
            {"role": "user", "content": "帮我分析选择"},
        ],
        stream=False,
        oauth_access_token="tok_abc",
    )
    assert url == "https://api.openai.com/v1/responses"
    assert headers["Authorization"] == "Bearer tok_abc"
    assert body["store"] is False
    assert body["stream"] is True
    assert body["instructions"] == "你是个人成长顾问"
    assert "temperature" not in body
    assert body["input"][0]["content"][0]["type"] == "input_text"
    assert body["input"][1]["content"][0]["type"] == "output_text"

    # 2. Stub OIDC discovery + httpx calls for token exchange, models, responses SSE, refresh & revoke
    async def fake_discovery(force_refresh: bool = False):
        return dict(chatgpt_oauth.DEFAULT_OIDC_ENDPOINTS)

    monkeypatch.setattr(chatgpt_oauth, "get_oidc_discovery", fake_discovery)

    recorded_requests: list[tuple[str, str, dict]] = []

    def mock_handler(request: httpx.Request) -> httpx.Response:
        url_str = str(request.url)
        if url_str == "https://auth.openai.com/api/accounts/oauth/token":
            form = dict(parse_qs(request.content.decode("utf-8")))
            flat = {k: v[0] for k, v in form.items()}
            recorded_requests.append(("POST", url_str, flat))
            grant = flat.get("grant_type")
            if grant == "authorization_code":
                # Grab pending nonce for realistic OIDC verification
                state_entry = next(iter(chatgpt_oauth._PENDING_FLOWS.values()))
                id_tok = _make_fake_jwt(
                    {
                        "iss": "https://auth.openai.com",
                        "aud": flat["client_id"],
                        "sub": "user_001",
                        "email": "sakura@example.com",
                        "name": "Sakura",
                        "nonce": state_entry["nonce"],
                        "https://api.openai.com/auth": {"chatgpt_plan_type": "plus"},
                    }
                )
                return httpx.Response(
                    200,
                    json={
                        "access_token": "at_initial_12345",
                        "refresh_token": "rt_initial_12345",
                        "id_token": id_tok,
                        "expires_in": 3600,
                        "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                        "client_id": "oaiapp_issued_999",
                    },
                )
            if grant == "refresh_token":
                return httpx.Response(
                    200,
                    json={
                        "access_token": "at_refreshed_67890",
                        "refresh_token": "rt_rotated_67890",
                        "expires_in": 3600,
                        "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct",
                    },
                )
        if url_str == "https://api.openai.com/v1/models":
            recorded_requests.append(("GET", url_str, {"auth": request.headers.get("authorization", "")}))
            return httpx.Response(
                200,
                json={
                    "models": [
                        {"slug": "gpt-5.4", "display_name": "GPT-5.4", "visibility": "list"},
                        {"slug": "gpt-5.4-mini", "display_name": "GPT-5.4 Mini", "visibility": "list"},
                        {"slug": "internal-hidden", "display_name": "Hidden", "visibility": "hide"},
                    ]
                },
            )
        if url_str == "https://api.openai.com/v1/responses":
            recorded_requests.append(("POST", url_str, json.loads(request.content.decode("utf-8"))))
            sse_body = (
                'event: response.reasoning_summary_text.delta\n'
                'data: {"type":"response.reasoning_summary_text.delta","delta":"先梳理核心原则..."}\n\n'
                'event: response.output_text.delta\n'
                'data: {"type":"response.output_text.delta","delta":"连接"}\n\n'
                'event: response.output_text.delta\n'
                'data: {"type":"response.output_text.delta","delta":"成功！"}\n\n'
                'event: response.completed\n'
                'data: {"type":"response.completed","response":{"model":"gpt-5.4","usage":{"total_tokens":42}}}\n\n'
            )
            return httpx.Response(200, content=sse_body.encode("utf-8"), headers={"content-type": "text/event-stream"})
        if url_str == "https://auth.openai.com/api/accounts/oauth/revoke":
            form = dict(parse_qs(request.content.decode("utf-8")))
            recorded_requests.append(("POST", url_str, {k: v[0] for k, v in form.items()}))
            return httpx.Response(200, text="")
        return httpx.Response(404, text="not mocked")

    orig_async_client = httpx.AsyncClient
    transport = httpx.MockTransport(mock_handler)

    def patched_async_client(*args, **kwargs):
        kwargs["transport"] = transport
        return orig_async_client(*args, **kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", patched_async_client)

    client = TestClient(app)

    # 3. Start OAuth login -> first time uses dynamic_agent_client + agent_name_hint + 127.0.0.1 loopback
    start_resp = client.post("/api/chatgpt-oauth/start", json={"redirect_port": 18789})
    assert start_resp.status_code == 200
    start_data = start_resp.json()
    assert start_data["is_first_registration"] is True
    assert start_data["redirect_uri"] == "http://127.0.0.1:18789/auth/callback"
    auth_qs = parse_qs(urlparse(start_data["auth_url"]).query)
    assert auth_qs["client_id"][0] == "dynamic_agent_client"
    assert auth_qs["agent_name_hint"][0] == "DecisionAdvisor"
    assert auth_qs["ext_agent_host_id"][0].startswith("urn:uuid:")
    assert "chatgpt.tokens.use.direct" in auth_qs["scope"][0]
    assert auth_qs["resource"][0] == "https://api.openai.com/v1"
    assert auth_qs["code_challenge_method"][0] == "S256"

    # 4. Complete callback via /auth/callback (simulating OpenAI browser redirect with issued client_id)
    cb_resp = client.get(
        "/auth/callback",
        params={"code": "auth_code_xyz", "state": start_data["state"], "client_id": "oaiapp_issued_999"},
    )
    assert cb_resp.status_code == 200
    assert "ChatGPT 授权登录成功" in cb_resp.text
    assert "sakura@example.com" in cb_resp.text

    # 5. Verify status & public config (tokens NEVER leaked, models filtered by visibility=="list")
    status = client.get("/api/chatgpt-oauth/status", params={"state": start_data["state"]}).json()
    assert status["connected"] is True
    assert status["account_email"] == "sakura@example.com"
    assert status["plan_type"] == "plus"
    assert status["has_plan_usage_scope"] is True
    assert status["has_issued_client_id"] is True
    assert status["flow"]["status"] == "completed"
    assert [m["slug"] for m in status["available_models"]] == ["gpt-5.4", "gpt-5.4-mini"]
    assert "access_token" not in status and "refresh_token" not in status

    cfg_pub = client.get("/api/config").json()
    gpt_item = next(p for p in cfg_pub["providers"] if p["kind"] == "chatgpt_oauth")
    assert gpt_item["has_api_key"] is True
    assert gpt_item["model"] == "gpt-5.4"

    # 6. Subsequent OAuth start MUST reuse issued client_id and OMIT agent_name_hint
    start_again = client.post("/api/chatgpt-oauth/start", json={"redirect_port": 18789}).json()
    assert start_again["is_first_registration"] is False
    again_qs = parse_qs(urlparse(start_again["auth_url"]).query)
    assert again_qs["client_id"][0] == "oaiapp_issued_999"
    assert "agent_name_hint" not in again_qs

    # 7. Test calling Responses API via call_llm and stream_llm
    res = asyncio.run(call_llm(gpt_preset, "系统指令", [{"role": "user", "content": "测试"}]))
    assert res.content == "连接成功！"
    assert res.reasoning == "先梳理核心原则..."
    assert res.model == "gpt-5.4"

    async def collect_stream():
        return [c async for c in stream_llm(gpt_preset, "系统指令", [{"role": "user", "content": "测试"}])]

    chunks = asyncio.run(collect_stream())
    assert any(c["type"] == "reasoning" and "核心原则" in c["delta"] for c in chunks)
    assert "".join(c["delta"] for c in chunks if c["type"] == "text") == "连接成功！"

    # 8. Test token refresh rotation
    new_tok = asyncio.run(chatgpt_oauth.get_valid_access_token(force_refresh=True))
    assert new_tok == "at_refreshed_67890"

    # 9. Test logout revokes token and clears session while preserving host_id & issued client_id
    out = client.post("/api/chatgpt-oauth/logout", json={"reset_client": False}).json()
    assert out["ok"] is True
    assert out["oauth"]["connected"] is False
    assert out["oauth"]["has_issued_client_id"] is True
    assert any(u == "https://auth.openai.com/api/accounts/oauth/revoke" for _, u, _ in recorded_requests)


def test_onboarding_status_quick_profile_and_interview(temp_env, monkeypatch):
    import app.main as main_mod
    from app.prompts import build_chat_system_prompt
    from app.providers import ChatCompletionResult

    vault = temp_env["vault"]
    client = TestClient(app)

    # 1. Fresh/sparse vault -> needs onboarding (only values.md has short text; 4 slots empty)
    st0 = client.get("/api/onboarding/status").json()
    assert st0["needs_onboarding"] is True
    assert st0["completeness"] < 40
    assert "identity" in st0["missing_slots"]
    assert "boundaries" in st0["missing_slots"]
    assert len(st0["slots"]) == 5
    # Privacy check: <private> block in values.md must never leak into excerpt
    values_slot = next(s for s in st0["slots"] if s["id"] == "values")
    assert "123456" not in values_slot["excerpt"]

    # 2. Dismissing sets needs_onboarding = False, resetting restores it
    dis = client.post("/api/onboarding/state", json={"state": "dismissed"}).json()
    assert dis["ok"] is True
    assert dis["status"]["dismissed"] is True
    assert dis["status"]["needs_onboarding"] is False

    client.post("/api/onboarding/state", json={"state": ""})

    # 3. Quick profile preview (commit=False) returns proposals & diff without modifying disk
    quick_payload = {
        "preferred_name": "阿木",
        "life_stage": "独立开发者第 2 年，兼顾家庭与个人成长，探索可持续节奏。",
        "current_focus": "决定下半年是全职深耕产品还是接顾问项目，希望平衡自由与现金流。",
        "core_values": ["自主权", "健康", "长期成长"],
        "values_note": "宁可慢一点，也不牺牲睡眠与长期判断力。",
        "boundaries": "绝不接受长期无意义内耗的加班，不在情绪上头当晚做不可逆的重大决定。",
        "patterns": "压力大时容易过度搜集信息拖延；独处散步和复盘写作最能帮我充能恢复清醒。",
        "goals": "未来 6 个月跑通个人产品的稳定订阅闭环，同时每周保持三次力量训练。",
        "advisor_style": "direct_critic",
        "advisor_style_note": "结论先行，直接指出盲区。",
        "commit": False,
    }
    prev = client.post("/api/onboarding/quick-profile", json=quick_payload).json()
    assert prev["ok"] is True
    assert prev["written"] == []
    assert len(prev["proposals"]) == 5
    assert not (vault / "00-核心自我" / "identity.md").exists()

    # 4. Quick profile commit writes all 5 slots and non-destructively merges existing values.md
    quick_payload["commit"] = True
    committed = client.post("/api/onboarding/quick-profile", json=quick_payload).json()
    assert committed["ok"] is True
    assert len(committed["written"]) == 5
    assert committed["status"]["completed"] is True
    assert committed["status"]["needs_onboarding"] is False
    assert committed["status"]["completeness"] == 100

    identity_raw = (vault / "00-核心自我" / "identity.md").read_text(encoding="utf-8")
    assert "阿木" in identity_raw
    assert "直率泼冷水" in identity_raw
    values_raw = (vault / "00-核心自我" / "values.md").read_text(encoding="utf-8")
    assert "1. 自主权" in values_raw  # Existing content preserved
    assert "引导建档补充" in values_raw  # New content appended

    # 5. Slot-aware interview prompt injects completeness & slot table
    store = MemoryStore(vault)
    sys_prompt = build_chat_system_prompt(store, "interview", store.load_core_self(), [], focus_slot="boundaries")
    assert "当前核心自我档案体检" in sys_prompt
    assert "00-核心自我/boundaries.md" in sys_prompt

    # 6. Advisor-initiated interview start (mocked LLM + fallback path)
    async def fake_call_llm(provider, sys_p, msgs, **kwargs):
        assert "当前核心自我档案体检" in sys_p
        return ChatCompletionResult(content="你好阿木，我们先聊聊你最在意的边界，最近有没有哪件小事让你觉得被踩线了？", model="deepseek-v4-pro")

    monkeypatch.setattr(main_mod, "call_llm", fake_call_llm)
    started = client.post("/api/onboarding/interview/start", json={"focus_slot": "boundaries"}).json()
    assert started["ok"] is True
    assert started["mode"] == "interview"
    assert started["used_fallback"] is False
    assert "阿木" in started["opening_message"]

    sess = client.get(f"/api/sessions/{started['session_id']}").json()
    assert len(sess["messages"]) == 1
    assert sess["messages"][0]["role"] == "assistant"

    # Fallback path when provider raises error
    async def broken_call_llm(*args, **kwargs):
        raise main_mod.ProviderError("no key")

    monkeypatch.setattr(main_mod, "call_llm", broken_call_llm)
    fallback_started = client.post("/api/onboarding/interview/start", json={"focus_slot": "goals"}).json()
    assert fallback_started["ok"] is True
    assert fallback_started["used_fallback"] is True
    assert "当下课题与目标" in fallback_started["opening_message"]


def test_cross_agent_memory_import_parsers_and_extract(temp_env, monkeypatch):
    import app.main as main_mod
    from app.providers import ChatCompletionResult

    vault = temp_env["vault"]
    client = TestClient(app)

    # 1. Copyable prompt templates
    prompts_resp = client.get("/api/import/prompts").json()
    assert len(prompts_resp["templates"]) >= 2
    assert "Markdown" in prompts_resp["templates"][0]["prompt"]

    # 2. Preview pasted prompt text with <private> block detection
    paste_prev = client.post(
        "/api/import/preview",
        json={
            "raw_text": "## 我是谁\n我是产品经理，重视自主权。\n<private>银行卡999888</private>\n## 目标\n今年启动独立项目。",
            "source_hint": "prompt_paste",
        },
    ).json()
    assert paste_prev["detected_source"] == "pasted_text"
    assert len(paste_prev["items"]) == 1
    assert any("<private>" in w for w in paste_prev["warnings"])
    assert "999888" not in paste_prev["items"][0]["preview"]

    # 3. Preview ChatGPT official export ZIP (high-signal reflection vs. low-signal Traceback chat)
    chatgpt_convs = [
        {
            "title": "是否要离开高压大厂转独立开发",
            "create_time": 1735689600,
            "current_node": "n2",
            "mapping": {
                "n1": {
                    "id": "n1",
                    "parent": None,
                    "message": {
                        "author": {"role": "user"},
                        "create_time": 1735689600,
                        "content": {"parts": ["我最近非常焦虑和内耗，一直在纠结人生选择：要不要辞职追求更大的自主权和价值观一致的工作？家人也有不同看法。"]},
                    },
                },
                "n2": {
                    "id": "n2",
                    "parent": "n1",
                    "message": {
                        "author": {"role": "assistant"},
                        "create_time": 1735689610,
                        "content": {"parts": ["我们可以先盘点你的底线、财务安全垫和最小验证动作。"]},
                    },
                },
            },
        },
        {
            "title": "Fix python error",
            "create_time": 1735689700,
            "current_node": "c1",
            "mapping": {
                "c1": {
                    "id": "c1",
                    "parent": None,
                    "message": {
                        "author": {"role": "user"},
                        "create_time": 1735689700,
                        "content": {
                            "parts": [
                                "Traceback (most recent call last):\nSyntaxError: invalid syntax\n```python\nprint(1)\n```\n```python\nprint(2)\n```"
                            ]
                        },
                    },
                }
            },
        },
    ]
    zip_buf = io.BytesIO()
    with zipfile.ZipFile(zip_buf, "w") as zf:
        zf.writestr("conversations.json", json.dumps(chatgpt_convs, ensure_ascii=False))
    cgpt_prev = client.post(
        "/api/import/preview",
        json={
            "files": [
                {
                    "filename": "chatgpt-export.zip",
                    "content_base64": base64.b64encode(zip_buf.getvalue()).decode("ascii"),
                }
            ]
        },
    ).json()
    assert cgpt_prev["detected_source"] == "chatgpt_export"
    assert cgpt_prev["total_items"] == 2
    assert cgpt_prev["recommended_items"] == 1
    assert cgpt_prev["items"][0]["title"] == "是否要离开高压大厂转独立开发"
    assert cgpt_prev["items"][0]["recommended"] is True
    assert cgpt_prev["items"][1]["recommended"] is False

    # 4. Preview Claude memories.json + conversations.json
    claude_mems = [{"conversations_memory": "用户叫林深，非常看重长期主义和睡眠健康，反感无效社交。", "project_memories": {"p1": "正在打造个人成长工具"}}]
    cm_prev = client.post(
        "/api/import/preview",
        json={
            "files": [
                {
                    "filename": "memories.json",
                    "content_base64": base64.b64encode(json.dumps(claude_mems, ensure_ascii=False).encode("utf-8")).decode("ascii"),
                }
            ]
        },
    ).json()
    assert cm_prev["detected_source"] == "claude_memories"
    assert len(cm_prev["items"]) == 2
    assert all(i["recommended"] for i in cm_prev["items"])

    # 5. Preview Generic Memory JSON (Mem0 & PAM & Letta)
    mem0_payload = {"results": [{"memory": "偏好简洁直接的反馈，不喜欢客套", "created_at": "2026-01-10", "categories": ["preference"]}]}
    mem0_prev = client.post(
        "/api/import/preview",
        json={"raw_text": json.dumps(mem0_payload, ensure_ascii=False)},
    ).json()
    assert mem0_prev["detected_source"] == "mem0_json"
    assert len(mem0_prev["items"]) == 1

    pam_payload = {
        "schema": "pam/1.0",
        "profile": {"name": "林深", "role": "工程师"},
        "memories": [{"content": "2025 年决定减少熬夜，把健康排在第一位", "date": "2025-09-01"}],
    }
    pam_prev = client.post(
        "/api/import/preview",
        json={"raw_text": json.dumps(pam_payload, ensure_ascii=False)},
    ).json()
    assert pam_prev["detected_source"] == "pam_json"
    assert len(pam_prev["items"]) == 2

    # 6. Extract proposals via mocked LLM -> verifies <private> stripping & proposal enrichment
    captured_user_prompts: list[str] = []

    async def fake_import_llm(provider, sys_p, msgs, **kwargs):
        captured_user_prompts.append(msgs[0]["content"])
        fake_json = {
            "proposals": [
                {
                    "action": "create",
                    "path": "00-核心自我/identity.md",
                    "title": "核心身份与背景",
                    "summary": "从外部 AI 导入林深的身份背景与沟通偏好",
                    "importance": 9,
                    "emotions": [],
                    "relations": [],
                    "privacy": "private",
                    "evidence": "用户叫林深，偏好简洁直接反馈",
                    "content": "---\ntitle: 核心身份与背景\nprivacy: private\nsource: import\n---\n\n# 核心身份与背景\n\n- 称呼：林深\n- 沟通偏好：简洁直接，不喜欢客套，注重长期主义与睡眠健康。\n",
                }
            ]
        }
        return ChatCompletionResult(content=json.dumps(fake_json, ensure_ascii=False), model="deepseek-v4-pro")

    monkeypatch.setattr(main_mod, "call_llm", fake_import_llm)
    ext = client.post(
        "/api/import/extract",
        json={
            "source_label": "Claude 官方记忆",
            "items": [
                {
                    "id": "imp_1",
                    "source_type": "claude_memories",
                    "source_label": "Claude 官方记忆",
                    "title": "Claude 长期记忆",
                    "date": "2026-01-10",
                    "content": "用户叫林深 <private>绝密密码ABCD</private> 偏好简洁直接的反馈。",
                }
            ],
        },
    ).json()
    assert len(ext["proposals"]) == 1
    assert ext["proposals"][0]["level"] == 3
    assert ext["proposals"][0]["path"] == "00-核心自我/identity.md"
    assert "绝密密码ABCD" not in captured_user_prompts[0]
    assert "[已根据本地隐私规则隐藏]" in captured_user_prompts[0]

    # Commit the extracted proposal and verify it lands on disk cleanly
    commit_res = client.post(
        "/api/proposals/commit",
        json={"items": [{"action": "create", "path": ext["proposals"][0]["path"], "title": ext["proposals"][0]["title"], "content": ext["proposals"][0]["content"], "privacy": "private"}]},
    ).json()
    assert commit_res["ok"] is True
    assert (vault / "00-核心自我" / "identity.md").exists()


def test_reasoning_effort_builders_config_and_chat_stream(temp_env, monkeypatch: pytest.MonkeyPatch):
    # 1. ChatGPT OAuth Responses API
    gpt54 = ProviderPreset(id="cg", name="ChatGPT", kind="chatgpt_oauth", base_url="https://api.openai.com/v1", model="gpt-5.4")
    _, _, body_auto = build_provider_request(gpt54, "sys", [{"role": "user", "content": "hi"}], oauth_access_token="tok")
    assert "reasoning" not in body_auto
    _, _, body_xhigh = build_provider_request(
        gpt54, "sys", [{"role": "user", "content": "hi"}], oauth_access_token="tok", reasoning_effort="xhigh"
    )
    assert body_xhigh["reasoning"] == {"effort": "xhigh"}
    _, _, body_none = build_provider_request(
        gpt54, "sys", [{"role": "user", "content": "hi"}], oauth_access_token="tok", reasoning_effort="none"
    )
    assert body_none["reasoning"] == {"effort": "none"}

    # 2. OpenAI compatible (GPT-6 maps none -> low; legacy GPT-4.1 omits reasoning_effort)
    gpt6 = ProviderPreset(id="o6", name="OpenAI", kind="openai_compatible", base_url="https://api.openai.com/v1", api_key="k", model="gpt-6.2-sol")
    _, _, body_o6_high = build_provider_request(gpt6, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="high")
    assert body_o6_high["reasoning_effort"] == "high"
    assert body_o6_high["max_completion_tokens"] == 16384
    _, _, body_o6_none = build_provider_request(gpt6, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="none")
    assert body_o6_none["reasoning_effort"] == "low"

    gpt41 = ProviderPreset(id="o4", name="Legacy", kind="openai_compatible", base_url="https://api.openai.com/v1", api_key="k", model="gpt-4.1")
    _, _, body_gpt41 = build_provider_request(gpt41, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="high")
    assert "reasoning_effort" not in body_gpt41

    # 3. DeepSeek (enabled + mapped xhigh -> max; none -> disabled)
    ds = ProviderPreset(id="ds", name="DS", kind="deepseek", base_url="https://api.deepseek.com/v1", api_key="k", model="deepseek-v4-pro")
    _, _, body_ds_xhigh = build_provider_request(ds, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="xhigh")
    assert body_ds_xhigh["thinking"] == {"type": "enabled"}
    assert body_ds_xhigh["reasoning_effort"] == "max"
    assert body_ds_xhigh["max_tokens"] == 32768
    assert "temperature" not in body_ds_xhigh
    _, _, body_ds_none = build_provider_request(ds, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="none")
    assert body_ds_none["thinking"] == {"type": "disabled"}
    assert body_ds_none["reasoning_effort"] == "none"

    # 4. Claude (modern 5.5 adaptive + output_config; legacy 4.5 budget_tokens)
    cl55 = ProviderPreset(id="c1", name="Claude", kind="claude", base_url="https://api.anthropic.com", api_key="k", model="claude-sonnet-5-5")
    _, _, body_cl55 = build_provider_request(cl55, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="high")
    assert body_cl55["thinking"] == {"type": "adaptive"}
    assert body_cl55["output_config"] == {"effort": "high"}
    assert "temperature" not in body_cl55
    _, _, body_cl55_off = build_provider_request(cl55, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="none")
    assert body_cl55_off["thinking"] == {"type": "disabled"}

    cl45 = ProviderPreset(id="c2", name="Claude45", kind="claude", base_url="https://api.anthropic.com", api_key="k", model="claude-sonnet-4-5")
    _, _, body_cl45 = build_provider_request(cl45, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="medium")
    assert body_cl45["thinking"] == {"type": "enabled", "budget_tokens": 6144}
    assert body_cl45["max_tokens"] >= 6144 + 4096
    assert "temperature" not in body_cl45

    # 5. Gemini (modern 4 thinkingLevel; legacy 2.5 thinkingBudget)
    gem4 = ProviderPreset(id="g4", name="Gemini4", kind="gemini", base_url="https://generativelanguage.googleapis.com", api_key="k", model="gemini-4-neon")
    _, _, body_gem4 = build_provider_request(gem4, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="xhigh")
    assert body_gem4["generationConfig"]["thinkingConfig"] == {"thinkingLevel": "xhigh", "includeThoughts": True}
    assert body_gem4["generationConfig"]["maxOutputTokens"] == 32768

    gem25 = ProviderPreset(id="g25", name="Gemini25", kind="gemini", base_url="https://generativelanguage.googleapis.com", api_key="k", model="gemini-2.5-flash")
    _, _, body_gem25_off = build_provider_request(gem25, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="none")
    assert body_gem25_off["generationConfig"]["thinkingConfig"] == {"thinkingBudget": 0}
    _, _, body_gem25_hi = build_provider_request(gem25, "sys", [{"role": "user", "content": "hi"}], reasoning_effort="high")
    assert body_gem25_hi["generationConfig"]["thinkingConfig"] == {"thinkingBudget": 16384, "includeThoughts": True}
    assert body_gem25_hi["generationConfig"]["maxOutputTokens"] >= 16384 + 4096

    # 6. Config persistence + /api/chat/stream forwarding
    client = TestClient(app)
    cfg = client.get("/api/config").json()
    providers = cfg["providers"]
    providers[0]["reasoning_effort"] = "medium"
    updated = client.put("/api/config", json={"providers": providers, "active_provider_id": providers[0]["id"]}).json()
    assert updated["providers"][0]["reasoning_effort"] == "medium"

    captured_efforts: list[str | None] = []

    async def fake_stream(provider, sys_p, msgs, **kwargs):
        captured_efforts.append(kwargs.get("reasoning_effort"))
        yield {"type": "text", "delta": "收到"}

    monkeypatch.setattr("app.main.stream_llm", fake_stream)

    # Explicit request override beats provider preset
    with client.stream(
        "POST",
        "/api/chat/stream",
        json={"messages": [{"role": "user", "content": "测试思考强度"}], "reasoning_effort": "xhigh"},
    ) as resp:
        assert resp.status_code == 200
        events = [json.loads(line[5:].strip()) for line in resp.iter_lines() if line.startswith("data:")]
    assert captured_efforts[-1] == "xhigh"
    assert next(e for e in events if e["type"] == "meta")["reasoning_effort"] == "xhigh"

    # Omitting reasoning_effort falls back to provider preset ("medium")
    with client.stream(
        "POST",
        "/api/chat/stream",
        json={"messages": [{"role": "user", "content": "测试预设回落"}]},
    ) as resp:
        assert resp.status_code == 200
        events2 = [json.loads(line[5:].strip()) for line in resp.iter_lines() if line.startswith("data:")]
    assert captured_efforts[-1] == "medium"
    assert next(e for e in events2 if e["type"] == "meta")["reasoning_effort"] == "medium"
