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
from app.db import init_db
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
