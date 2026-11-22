from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
import secrets
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlencode, urlparse

import httpx

BASE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_OAUTH_PATH = BASE_DIR / "chatgpt_oauth.local.json"

OIDC_DISCOVERY_URL = "https://auth.openai.com/.well-known/openid-configuration"
DEFAULT_OIDC_ENDPOINTS = {
    "issuer": "https://auth.openai.com",
    "authorization_endpoint": "https://auth.openai.com/api/accounts/authorize",
    "token_endpoint": "https://auth.openai.com/api/accounts/oauth/token",
    "revocation_endpoint": "https://auth.openai.com/api/accounts/oauth/revoke",
}

OPENAI_API_RESOURCE = "https://api.openai.com/v1"
DYNAMIC_CLIENT_ID = "dynamic_agent_client"
DEFAULT_AGENT_NAME_HINT = "DecisionAdvisor"
CHATGPT_OAUTH_SCOPES = (
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
)

_DISCOVERY_CACHE: dict[str, Any] = {"fetched_at": 0.0, "data": None}
_PENDING_FLOWS: dict[str, dict[str, Any]] = {}
_REFRESH_LOCK: asyncio.Lock | None = None
_PENDING_TTL_SECONDS = 900  # 15 minutes


class ChatGPTOAuthError(RuntimeError):
    """Raised when Sign in with ChatGPT OAuth flow or token refresh fails."""


def _get_refresh_lock() -> asyncio.Lock:
    global _REFRESH_LOCK
    if _REFRESH_LOCK is None:
        _REFRESH_LOCK = asyncio.Lock()
    return _REFRESH_LOCK


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def get_oauth_store_path() -> Path:
    env_path = os.environ.get("ADVISOR_CHATGPT_OAUTH_PATH", "").strip()
    if env_path:
        return Path(env_path).expanduser()
    env_data = os.environ.get("ADVISOR_DATA_DIR", "").strip()
    if env_data:
        return Path(env_data).expanduser() / "chatgpt_oauth.local.json"
    return DEFAULT_OAUTH_PATH


def get_default_loopback_port() -> int:
    try:
        return int(os.environ.get("ADVISOR_PORT", "8789"))
    except ValueError:
        return 8789


def get_loopback_redirect_uri(port: int | None = None) -> str:
    """OpenAI Sign in with ChatGPT requires strict 127.0.0.1 loopback (not localhost)."""
    p = port or get_default_loopback_port()
    return f"http://127.0.0.1:{p}/auth/callback"


def _load_store_raw() -> dict[str, Any]:
    path = get_oauth_store_path()
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save_store_raw(data: dict[str, Any]) -> None:
    path = get_oauth_store_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + f".tmp.{secrets.token_hex(4)}")
    tmp_path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    try:
        os.chmod(tmp_path, 0o600)
    except OSError:
        pass
    os.replace(tmp_path, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def get_or_create_host_id() -> str:
    """Persistent installation-level host identifier (ext_agent_host_id)."""
    store = _load_store_raw()
    host_id = str(store.get("ext_agent_host_id") or "").strip()
    if host_id:
        return host_id
    host_id = f"urn:uuid:{uuid.uuid4()}"
    store["ext_agent_host_id"] = host_id
    _save_store_raw(store)
    return host_id


def _decode_jwt_payload(token: str) -> dict[str, Any]:
    """Decode JWT payload claims without external crypto dependencies."""
    if not token or token.count(".") < 2:
        return {}
    try:
        payload_b64 = token.split(".")[1]
        pad = "=" * (-len(payload_b64) % 4)
        raw = base64.urlsafe_b64decode(payload_b64 + pad)
        data = json.loads(raw.decode("utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _mask_id(val: str) -> str:
    if not val:
        return ""
    if len(val) <= 10:
        return "*" * len(val)
    return f"{val[:6]}...{val[-4:]}"


def _extract_issued_client_id(
    callback_client_id: str,
    token_data: dict[str, Any],
    id_claims: dict[str, Any],
    access_claims: dict[str, Any],
    fallback_client_id: str,
) -> str:
    candidates: list[str] = []
    if callback_client_id:
        candidates.append(callback_client_id.strip())
    if isinstance(token_data.get("client_id"), str):
        candidates.append(token_data["client_id"].strip())
    aud = id_claims.get("aud")
    if isinstance(aud, str):
        candidates.append(aud.strip())
    elif isinstance(aud, list):
        for item in aud:
            if isinstance(item, str):
                candidates.append(item.strip())
    for key in ("client_id", "azp"):
        v = access_claims.get(key) or id_claims.get(key)
        if isinstance(v, str):
            candidates.append(v.strip())
    if fallback_client_id:
        candidates.append(fallback_client_id.strip())

    for c in candidates:
        if c and c != DYNAMIC_CLIENT_ID:
            return c
    return ""


def _extract_scopes(token_data: dict[str, Any], access_claims: dict[str, Any]) -> list[str]:
    scopes: list[str] = []
    raw_scope = token_data.get("scope")
    if isinstance(raw_scope, str) and raw_scope.strip():
        scopes.extend(raw_scope.split())
    for key in ("scope", "scp"):
        v = access_claims.get(key)
        if isinstance(v, str):
            scopes.extend(v.split())
        elif isinstance(v, list):
            scopes.extend(str(x) for x in v if x)
    # Preserve order while deduplicating
    seen: set[str] = set()
    out: list[str] = []
    for s in scopes:
        if s not in seen:
            seen.add(s)
            out.append(s)
    return out


def _prune_pending_flows() -> None:
    now = time.time()
    expired = [
        k for k, v in _PENDING_FLOWS.items()
        if now - float(v.get("created_at", 0)) > _PENDING_TTL_SECONDS
    ]
    for k in expired:
        _PENDING_FLOWS.pop(k, None)


async def get_oidc_discovery(force_refresh: bool = False) -> dict[str, str]:
    now = time.time()
    cached = _DISCOVERY_CACHE.get("data")
    if not force_refresh and cached and (now - float(_DISCOVERY_CACHE.get("fetched_at", 0))) < 3600:
        return dict(cached)

    endpoints = dict(DEFAULT_OIDC_ENDPOINTS)
    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            resp = await client.get(OIDC_DISCOVERY_URL)
            if resp.status_code == 200:
                doc = resp.json()
                for key in (
                    "issuer",
                    "authorization_endpoint",
                    "token_endpoint",
                    "revocation_endpoint",
                ):
                    val = doc.get(key)
                    if isinstance(val, str) and val.startswith("https://"):
                        endpoints[key] = val
    except Exception:
        pass

    _DISCOVERY_CACHE["data"] = endpoints
    _DISCOVERY_CACHE["fetched_at"] = now
    return dict(endpoints)


def generate_pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(48)
    challenge = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest())
        .rstrip(b"=")
        .decode("ascii")
    )
    return verifier, challenge


async def start_chatgpt_oauth_flow(
    *,
    port: int | None = None,
    force_register: bool = False,
    agent_name: str = DEFAULT_AGENT_NAME_HINT,
) -> dict[str, Any]:
    """Generate an official Sign in with ChatGPT authorization URL with PKCE."""
    _prune_pending_flows()
    discovery = await get_oidc_discovery()
    host_id = get_or_create_host_id()
    store = _load_store_raw()

    saved_client_id = str(store.get("client_id") or "").strip()
    if not force_register and saved_client_id and saved_client_id != DYNAMIC_CLIENT_ID:
        client_id = saved_client_id
        is_first_registration = False
    else:
        client_id = DYNAMIC_CLIENT_ID
        is_first_registration = True

    verifier, challenge = generate_pkce_pair()
    state = secrets.token_urlsafe(32)
    nonce = secrets.token_urlsafe(32)
    redirect_uri = get_loopback_redirect_uri(port)

    params: dict[str, str] = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "scope": CHATGPT_OAUTH_SCOPES,
        "resource": OPENAI_API_RESOURCE,
        "state": state,
        "nonce": nonce,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "ext_agent_host_id": host_id,
    }
    if is_first_registration:
        params["agent_name_hint"] = agent_name

    auth_endpoint = discovery["authorization_endpoint"]
    auth_url = f"{auth_endpoint}?{urlencode(params)}"

    _PENDING_FLOWS[state] = {
        "state": state,
        "nonce": nonce,
        "code_verifier": verifier,
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "is_first_registration": is_first_registration,
        "created_at": time.time(),
        "status": "pending",
        "error": "",
    }

    return {
        "auth_url": auth_url,
        "state": state,
        "redirect_uri": redirect_uri,
        "is_first_registration": is_first_registration,
        "client_id_used": client_id,
    }


def get_pending_flow_status(state: str) -> dict[str, Any] | None:
    _prune_pending_flows()
    flow = _PENDING_FLOWS.get(state)
    if not flow:
        return None
    return {
        "state": state,
        "status": flow.get("status", "pending"),
        "error": flow.get("error", ""),
    }


def parse_models_catalog(payload: dict[str, Any]) -> list[dict[str, str]]:
    """Parse GET https://api.openai.com/v1/models response per OpenAI SIWC docs."""
    out: list[dict[str, str]] = []
    seen: set[str] = set()

    # Official Sign in with ChatGPT catalog format:
    # { "models": [ { "slug": "...", "display_name": "...", "visibility": "list" } ] }
    models_arr = payload.get("models")
    if isinstance(models_arr, list):
        for item in models_arr:
            if not isinstance(item, dict):
                continue
            visibility = item.get("visibility")
            if visibility is not None and visibility != "list":
                continue
            slug = str(item.get("slug") or item.get("id") or "").strip()
            if not slug or slug in seen:
                continue
            seen.add(slug)
            display_name = str(item.get("display_name") or item.get("name") or slug).strip()
            desc = str(item.get("description") or "").strip()
            out.append({"slug": slug, "display_name": display_name, "description": desc})
        return out

    # Fallback: standard OpenAI /v1/models format: { "data": [ { "id": "..." } ] }
    data_arr = payload.get("data")
    if isinstance(data_arr, list):
        for item in data_arr:
            if not isinstance(item, dict):
                continue
            slug = str(item.get("id") or "").strip()
            if not slug or slug in seen:
                continue
            low = slug.lower()
            if not (low.startswith("gpt-") or low.startswith("o1") or low.startswith("o3") or low.startswith("o4") or low.startswith("chatgpt-")):
                continue
            if any(skip in low for skip in ("realtime", "audio", "transcribe", "tts", "image", "whisper", "embedding", "moderation", "dall-e")):
                continue
            seen.add(slug)
            out.append({"slug": slug, "display_name": slug, "description": ""})
    return out


async def fetch_models_with_token(access_token: str) -> list[dict[str, str]]:
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Accept": "application/json",
    }
    async with httpx.AsyncClient(timeout=20.0) as client:
        resp = await client.get(f"{OPENAI_API_RESOURCE}/models", headers=headers)
    if resp.status_code == 401:
        raise ChatGPTOAuthError("HTTP 401: ChatGPT 授权令牌已失效，请重新授权或刷新。")
    if resp.status_code >= 400:
        raise ChatGPTOAuthError(f"获取可用模型失败 (HTTP {resp.status_code}): {resp.text[:300]}")
    try:
        data = resp.json()
    except Exception as exc:
        raise ChatGPTOAuthError(f"模型列表返回格式无效: {resp.text[:200]}") from exc
    return parse_models_catalog(data)


async def complete_chatgpt_oauth_callback(
    *,
    code: str = "",
    state: str = "",
    callback_client_id: str = "",
    error: str = "",
    error_description: str = "",
) -> dict[str, Any]:
    """Complete OAuth callback, exchange authorization code for tokens, and fetch models."""
    _prune_pending_flows()
    if not state:
        raise ChatGPTOAuthError("缺少 OAuth state 参数，请从程序设置页重新点击授权登录。")

    pending = _PENDING_FLOWS.get(state)
    if not pending:
        raise ChatGPTOAuthError("该授权会话已过期或不存在，请返回设置页重新点击「使用 ChatGPT 授权登录」。")

    if pending.get("status") == "completed":
        return get_public_oauth_status()

    if error:
        detail = f"{error}: {error_description}".strip(": ")
        if "3p_login_workspace_scope_denied" in detail:
            detail += "（当前工作区可能限制了第三方应用授权，请尝试切换到个人 ChatGPT 账号/工作区）"
        pending["status"] = "error"
        pending["error"] = detail
        raise ChatGPTOAuthError(f"ChatGPT 授权被拒绝或失败：{detail}")

    if not code:
        pending["status"] = "error"
        pending["error"] = "回调中缺少 authorization code"
        raise ChatGPTOAuthError("回调地址中缺少授权码（code），请重试。")

    discovery = await get_oidc_discovery()
    token_endpoint = discovery["token_endpoint"]
    host_id = get_or_create_host_id()

    cb_cid = callback_client_id.strip()
    exchange_client_id = (
        cb_cid if (cb_cid and cb_cid != DYNAMIC_CLIENT_ID) else str(pending["client_id"])
    )

    form_data: dict[str, str] = {
        "grant_type": "authorization_code",
        "client_id": exchange_client_id,
        "code": code.strip(),
        "redirect_uri": str(pending["redirect_uri"]),
        "code_verifier": str(pending["code_verifier"]),
        "resource": OPENAI_API_RESOURCE,
        "ext_agent_host_id": host_id,
    }

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                token_endpoint,
                data=form_data,
                headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
            )
    except httpx.RequestError as exc:
        msg = f"连接 OpenAI 授权服务器失败：{exc}"
        pending["status"] = "error"
        pending["error"] = msg
        raise ChatGPTOAuthError(msg) from exc

    if resp.status_code >= 400:
        err_text = resp.text[:500]
        try:
            err_json = resp.json()
            err_code = err_json.get("error") or ""
            err_desc = err_json.get("error_description") or err_json.get("message") or ""
            if err_code or err_desc:
                err_text = f"{err_code}: {err_desc}".strip(": ")
        except Exception:
            pass
        msg = f"换取 OpenAI Token 失败 (HTTP {resp.status_code}): {err_text}"
        pending["status"] = "error"
        pending["error"] = msg
        raise ChatGPTOAuthError(msg)

    try:
        token_data = resp.json()
    except Exception as exc:
        msg = f"OpenAI Token 响应不是合法 JSON: {resp.text[:250]}"
        pending["status"] = "error"
        pending["error"] = msg
        raise ChatGPTOAuthError(msg) from exc

    access_token = str(token_data.get("access_token") or "").strip()
    refresh_token = str(token_data.get("refresh_token") or "").strip()
    id_token = str(token_data.get("id_token") or "").strip()
    expires_in = int(token_data.get("expires_in") or 3600)

    if not access_token:
        msg = f"OpenAI 未返回 access_token: {token_data}"
        pending["status"] = "error"
        pending["error"] = msg
        raise ChatGPTOAuthError(msg)

    id_claims = _decode_jwt_payload(id_token)
    access_claims = _decode_jwt_payload(access_token)

    # Validate OIDC issuer and nonce when present in id_token
    if id_claims:
        iss = str(id_claims.get("iss") or "")
        if iss and not iss.rstrip("/").startswith("https://auth.openai.com"):
            msg = f"OIDC issuer 校验失败：{iss}"
            pending["status"] = "error"
            pending["error"] = msg
            raise ChatGPTOAuthError(msg)
        token_nonce = id_claims.get("nonce")
        if token_nonce and token_nonce != pending.get("nonce"):
            msg = "OIDC nonce 校验不匹配，请重新发起授权登录。"
            pending["status"] = "error"
            pending["error"] = msg
            raise ChatGPTOAuthError(msg)

    issued_client_id = _extract_issued_client_id(
        cb_cid, token_data, id_claims, access_claims, exchange_client_id
    )
    scopes = _extract_scopes(token_data, access_claims)
    has_plan_scope = "chatgpt.tokens.use.direct" in scopes

    auth_meta = id_claims.get("https://api.openai.com/auth")
    if not isinstance(auth_meta, dict):
        auth_meta = access_claims.get("https://api.openai.com/auth")
    if not isinstance(auth_meta, dict):
        auth_meta = {}

    account_email = str(id_claims.get("email") or access_claims.get("email") or "").strip()
    account_name = str(id_claims.get("name") or "").strip()
    account_sub = str(id_claims.get("sub") or access_claims.get("sub") or "").strip()
    plan_type = str(auth_meta.get("chatgpt_plan_type") or "").strip()
    account_id = str(auth_meta.get("chatgpt_account_id") or "").strip()

    store = _load_store_raw()
    store["ext_agent_host_id"] = host_id
    if issued_client_id:
        store["client_id"] = issued_client_id
    store["access_token"] = access_token
    if refresh_token:
        store["refresh_token"] = refresh_token
    if id_token:
        store["id_token"] = id_token
    store["expires_at"] = time.time() + max(60, expires_in)
    store["scope"] = " ".join(scopes)
    store["has_plan_usage_scope"] = has_plan_scope
    store["account_email"] = account_email
    store["account_name"] = account_name
    store["account_sub"] = account_sub
    store["plan_type"] = plan_type
    store["account_id"] = account_id
    store["updated_at"] = _now_iso()

    # Discover models available to this ChatGPT subscription right away
    models: list[dict[str, str]] = []
    try:
        models = await fetch_models_with_token(access_token)
        if models:
            store["available_models"] = models
    except Exception:
        pass

    _save_store_raw(store)

    # Mark pending flow completed and wipe PKCE verifier from RAM
    pending["status"] = "completed"
    pending["error"] = ""
    pending.pop("code_verifier", None)

    return get_public_oauth_status()


def parse_callback_url_params(callback_url: str) -> dict[str, str]:
    parsed = urlparse(callback_url.strip())
    qs = parse_qs(parsed.query)
    return {
        "code": (qs.get("code") or [""])[0],
        "state": (qs.get("state") or [""])[0],
        "client_id": (qs.get("client_id") or qs.get("issued_client_id") or [""])[0],
        "error": (qs.get("error") or [""])[0],
        "error_description": (qs.get("error_description") or [""])[0],
    }


async def get_valid_access_token(*, force_refresh: bool = False) -> str:
    """Return a valid Bearer access_token, refreshing via serialized Lock when needed."""
    lock = _get_refresh_lock()
    async with lock:
        store = _load_store_raw()
        access_token = str(store.get("access_token") or "").strip()
        refresh_token = str(store.get("refresh_token") or "").strip()
        client_id = str(store.get("client_id") or "").strip()
        expires_at = float(store.get("expires_at") or 0.0)

        if not access_token and not refresh_token:
            raise ChatGPTOAuthError(
                "尚未完成 ChatGPT 授权登录。请前往「设置」点击「使用 ChatGPT 授权登录」。"
            )

        if not force_refresh and access_token and expires_at > (time.time() + 120):
            return access_token

        if not refresh_token:
            if access_token and not force_refresh:
                return access_token
            raise ChatGPTOAuthError(
                "ChatGPT 登录令牌已过期且无刷新令牌，请前往「设置」重新点击授权登录。"
            )

        if not client_id or client_id == DYNAMIC_CLIENT_ID:
            raise ChatGPTOAuthError(
                "缺少已签发的 OAuth client_id，请前往「设置」重新授权登录 ChatGPT。"
            )

        discovery = await get_oidc_discovery()
        token_endpoint = discovery["token_endpoint"]

        form_data = {
            "grant_type": "refresh_token",
            "client_id": client_id,
            "refresh_token": refresh_token,
            "resource": OPENAI_API_RESOURCE,
        }
        try:
            async with httpx.AsyncClient(timeout=25.0) as client:
                resp = await client.post(
                    token_endpoint,
                    data=form_data,
                    headers={"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
                )
        except httpx.RequestError as exc:
            raise ChatGPTOAuthError(f"刷新 ChatGPT 登录令牌时网络失败：{exc}") from exc

        if resp.status_code >= 400:
            detail = resp.text[:400]
            if resp.status_code in {400, 401}:
                raise ChatGPTOAuthError(
                    f"ChatGPT 授权已失效或被撤销（HTTP {resp.status_code}: {detail}），请在「设置」重新授权登录。"
                )
            raise ChatGPTOAuthError(f"刷新 ChatGPT 令牌失败 (HTTP {resp.status_code}): {detail}")

        data = resp.json()
        new_access = str(data.get("access_token") or "").strip()
        if not new_access:
            raise ChatGPTOAuthError("刷新令牌成功但未返回 access_token，请重新授权登录。")

        new_refresh = str(data.get("refresh_token") or "").strip()
        new_id = str(data.get("id_token") or "").strip()
        expires_in = int(data.get("expires_in") or 3600)

        store["access_token"] = new_access
        if new_refresh:
            store["refresh_token"] = new_refresh
        if new_id:
            store["id_token"] = new_id
        store["expires_at"] = time.time() + max(60, expires_in)
        access_claims = _decode_jwt_payload(new_access)
        scopes = _extract_scopes(data, access_claims)
        if scopes:
            store["scope"] = " ".join(scopes)
            store["has_plan_usage_scope"] = "chatgpt.tokens.use.direct" in scopes
        store["updated_at"] = _now_iso()
        _save_store_raw(store)
        return new_access


async def refresh_chatgpt_models() -> list[dict[str, str]]:
    """Fetch eligible ChatGPT subscription models and persist to local OAuth store."""
    token = await get_valid_access_token()
    try:
        models = await fetch_models_with_token(token)
    except ChatGPTOAuthError as exc:
        if "401" in str(exc):
            token = await get_valid_access_token(force_refresh=True)
            models = await fetch_models_with_token(token)
        else:
            raise

    store = _load_store_raw()
    store["available_models"] = models
    store["updated_at"] = _now_iso()
    _save_store_raw(store)
    return models


async def logout_chatgpt_oauth(*, reset_client: bool = False) -> dict[str, Any]:
    """Revoke refresh token with OpenAI (RFC 7009) and clear local session tokens."""
    store = _load_store_raw()
    refresh_token = str(store.get("refresh_token") or "").strip()
    access_token = str(store.get("access_token") or "").strip()
    client_id = str(store.get("client_id") or "").strip()

    token_to_revoke = refresh_token or access_token
    token_hint = "refresh_token" if refresh_token else "access_token"
    if token_to_revoke and client_id and client_id != DYNAMIC_CLIENT_ID:
        try:
            discovery = await get_oidc_discovery()
            revoke_url = discovery["revocation_endpoint"]
            async with httpx.AsyncClient(timeout=10.0) as client:
                await client.post(
                    revoke_url,
                    data={
                        "token": token_to_revoke,
                        "token_type_hint": token_hint,
                        "client_id": client_id,
                    },
                    headers={"Content-Type": "application/x-www-form-urlencoded"},
                )
        except Exception:
            pass

    preserved: dict[str, Any] = {}
    if store.get("ext_agent_host_id"):
        preserved["ext_agent_host_id"] = store["ext_agent_host_id"]
    if not reset_client and client_id and client_id != DYNAMIC_CLIENT_ID:
        preserved["client_id"] = client_id
    preserved["updated_at"] = _now_iso()
    _save_store_raw(preserved)
    return get_public_oauth_status()


def get_public_oauth_status() -> dict[str, Any]:
    """Safe status object for frontend/macOS UI — never exposes raw OAuth tokens."""
    store = _load_store_raw()
    access_token = str(store.get("access_token") or "").strip()
    refresh_token = str(store.get("refresh_token") or "").strip()
    client_id = str(store.get("client_id") or "").strip()
    expires_at = float(store.get("expires_at") or 0.0)
    now = time.time()
    is_expired = bool(expires_at and expires_at <= now)
    connected = bool((access_token and not is_expired) or (refresh_token and client_id))

    models = store.get("available_models")
    if not isinstance(models, list):
        models = []

    return {
        "connected": connected,
        "account_email": str(store.get("account_email") or ""),
        "account_name": str(store.get("account_name") or ""),
        "plan_type": str(store.get("plan_type") or ""),
        "has_plan_usage_scope": bool(store.get("has_plan_usage_scope", False)),
        "has_issued_client_id": bool(client_id and client_id != DYNAMIC_CLIENT_ID),
        "client_id_masked": _mask_id(client_id) if client_id != DYNAMIC_CLIENT_ID else "",
        "expires_at": int(expires_at) if expires_at else 0,
        "is_expired": is_expired,
        "can_refresh": bool(refresh_token and client_id and client_id != DYNAMIC_CLIENT_ID),
        "available_models": models,
        "redirect_uri": get_loopback_redirect_uri(),
        "updated_at": str(store.get("updated_at") or ""),
    }
