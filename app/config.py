from __future__ import annotations

import json
import os
import socket
import subprocess
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, Field

from .chatgpt_oauth import get_public_oauth_status

# 产品版本号（macOS 客户端与 VPS 后端统一），由 bump-version.sh 维护
APP_VERSION = "0.16"

BASE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_VAULT_PATH = str(Path.home() / "Library" / "Mobile Documents" / "com~apple~CloudDocs" / "决策")
DEFAULT_CONFIG_PATH = BASE_DIR / "config.local.json"
EXAMPLE_CONFIG_PATH = BASE_DIR / "config.example.json"

ProviderKind = Literal["deepseek", "openai_compatible", "claude", "gemini", "chatgpt_oauth"]
EmbeddingMode = Literal["local_bge_zh", "openai_compatible", "disabled"]
DeploymentMode = Literal["embedded_local", "remote_vps"]


def get_deployment_mode() -> DeploymentMode:
    raw = os.environ.get("ADVISOR_DEPLOYMENT_MODE", "embedded_local").strip().lower()
    if raw == "remote_vps":
        return "remote_vps"
    return "embedded_local"


def get_data_dir() -> Path:
    env_dir = os.environ.get("ADVISOR_DATA_DIR", "").strip()
    return Path(env_dir).expanduser().resolve() if env_dir else BASE_DIR


def get_default_vault_path() -> str:
    env_vault = os.environ.get("DECISION_VAULT_PATH", "").strip()
    if env_vault:
        return env_vault
    if get_deployment_mode() == "remote_vps":
        return str(get_data_dir() / "vault")
    return DEFAULT_VAULT_PATH


class ProviderPreset(BaseModel):
    id: str
    name: str
    kind: ProviderKind
    base_url: str
    api_key: str = ""
    model: str
    temperature: float = 0.7


class EmbeddingConfig(BaseModel):
    mode: EmbeddingMode = "local_bge_zh"
    local_model: str = "BAAI/bge-small-zh-v1.5"
    api_base_url: str = "https://api.openai.com/v1"
    api_key: str = ""
    api_model: str = "text-embedding-3-small"


class AppConfig(BaseModel):
    vault_path: str = Field(default_factory=get_default_vault_path)
    access_token: str = ""
    public_base_url: str = ""
    active_provider_id: str = "deepseek-default"
    providers: list[ProviderPreset] = Field(default_factory=list)
    embedding: EmbeddingConfig = Field(default_factory=EmbeddingConfig)


def _default_config() -> AppConfig:
    if EXAMPLE_CONFIG_PATH.exists():
        raw = json.loads(EXAMPLE_CONFIG_PATH.read_text(encoding="utf-8"))
        cfg = AppConfig.model_validate(raw)
        if not cfg.vault_path or os.environ.get("DECISION_VAULT_PATH") or get_deployment_mode() == "remote_vps":
            cfg.vault_path = get_default_vault_path()
        return cfg
    return AppConfig(
        providers=[
            ProviderPreset(
                id="chatgpt-oauth",
                name="ChatGPT 订阅授权",
                kind="chatgpt_oauth",
                base_url="https://api.openai.com/v1",
                model="gpt-5.4",
            ),
            ProviderPreset(
                id="deepseek-default",
                name="DeepSeek 官方",
                kind="deepseek",
                base_url="https://api.deepseek.com/v1",
                model="deepseek-v4-pro",
            ),
            ProviderPreset(
                id="openai-relay",
                name="OpenAI 兼容中转站",
                kind="openai_compatible",
                base_url="https://api.openai.com/v1",
                model="gpt-6.2-sol",
            ),
            ProviderPreset(
                id="claude-native",
                name="Claude 原生 API",
                kind="claude",
                base_url="https://api.anthropic.com",
                model="claude-sonnet-5-5",
            ),
            ProviderPreset(
                id="gemini-native",
                name="Gemini 原生 API",
                kind="gemini",
                base_url="https://generativelanguage.googleapis.com",
                model="gemini-4-neon",
            ),
        ]
    )


def get_config_path() -> Path:
    env_path = os.environ.get("ADVISOR_CONFIG_PATH", "").strip()
    if env_path:
        return Path(env_path).expanduser()
    env_data = os.environ.get("ADVISOR_DATA_DIR", "").strip()
    if env_data:
        return Path(env_data).expanduser() / "config.local.json"
    return DEFAULT_CONFIG_PATH


def load_config() -> AppConfig:
    cfg_path = get_config_path()
    if not cfg_path.exists():
        cfg = _default_config()
        save_config(cfg)
        return cfg
    raw = json.loads(cfg_path.read_text(encoding="utf-8"))
    cfg = AppConfig.model_validate(raw)
    if not cfg.providers:
        cfg.providers = _default_config().providers
    return cfg


def save_config(cfg: AppConfig) -> AppConfig:
    cfg_path = get_config_path()
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text(
        json.dumps(cfg.model_dump(), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    try:
        os.chmod(cfg_path, 0o600)
    except OSError:
        pass
    return cfg


def mask_secret(secret: str) -> str:
    if not secret:
        return ""
    if len(secret) <= 8:
        return "*" * len(secret)
    return f"{secret[:4]}...{secret[-4:]}"


def serialize_public_config(cfg: AppConfig) -> dict:
    oauth_status = get_public_oauth_status()
    providers_out = []
    for p in cfg.providers:
        item = p.model_dump()
        if p.kind == "chatgpt_oauth":
            item["has_api_key"] = bool(oauth_status["connected"])
            item["api_key_masked"] = (
                oauth_status["account_email"]
                or ("已授权" if oauth_status["connected"] else "")
            )
        else:
            item["has_api_key"] = bool(p.api_key)
            item["api_key_masked"] = mask_secret(p.api_key)
        item["api_key"] = ""
        providers_out.append(item)

    emb_out = cfg.embedding.model_dump()
    emb_out["has_api_key"] = bool(cfg.embedding.api_key)
    emb_out["api_key_masked"] = mask_secret(cfg.embedding.api_key)
    emb_out["api_key"] = ""

    public_url = cfg.public_base_url.rstrip("/")
    return {
        "deployment_mode": get_deployment_mode(),
        "vault_path": cfg.vault_path,
        "public_base_url": public_url,
        "mcp_endpoint_url": f"{public_url}/mcp" if public_url else "",
        "has_access_token": bool(cfg.access_token),
        "active_provider_id": cfg.active_provider_id,
        "providers": providers_out,
        "embedding": emb_out,
        "network": get_network_info(),
        "chatgpt_oauth": oauth_status,
    }


def ensure_chatgpt_oauth_provider(
    cfg: AppConfig,
    *,
    discovered_models: list[dict[str, str]] | None = None,
    activate_if_no_other_key: bool = False,
) -> AppConfig:
    """Ensure a chatgpt_oauth preset exists, sync its default model, and optionally activate it."""
    slugs = [
        str(m.get("slug") or "").strip()
        for m in (discovered_models or [])
        if isinstance(m, dict) and str(m.get("slug") or "").strip()
    ]
    preferred_model = slugs[0] if slugs else "gpt-5.4"

    target = next((p for p in cfg.providers if p.kind == "chatgpt_oauth"), None)
    if target is None:
        target = ProviderPreset(
            id="chatgpt-oauth",
            name="ChatGPT 订阅授权",
            kind="chatgpt_oauth",
            base_url="https://api.openai.com/v1",
            api_key="",
            model=preferred_model,
            temperature=0.7,
        )
        cfg.providers.insert(0, target)
    else:
        if slugs and (not target.model.strip() or target.model.strip() not in slugs):
            target.model = preferred_model

    if activate_if_no_other_key:
        current_active = next((p for p in cfg.providers if p.id == cfg.active_provider_id), None)
        if current_active is None or (current_active.kind != "chatgpt_oauth" and not current_active.api_key.strip()):
            cfg.active_provider_id = target.id

    return cfg


def merge_config_update(current: AppConfig, payload: dict) -> AppConfig:
    existing_by_id = {p.id: p for p in current.providers}
    updated_providers: list[ProviderPreset] = []

    incoming_providers = payload.get("providers")
    if isinstance(incoming_providers, list) and incoming_providers:
        for item in incoming_providers:
            pid = str(item.get("id", "")).strip()
            if not pid:
                continue
            incoming_key = str(item.get("api_key", "")).strip()
            clear_key = bool(item.get("clear_api_key", False))
            if clear_key:
                final_key = ""
            elif incoming_key:
                final_key = incoming_key
            elif pid in existing_by_id:
                final_key = existing_by_id[pid].api_key
            else:
                final_key = ""
            updated_providers.append(
                ProviderPreset(
                    id=pid,
                    name=str(item.get("name", pid)).strip() or pid,
                    kind=item["kind"],
                    base_url=str(item.get("base_url", "")).strip(),
                    api_key=final_key,
                    model=str(item.get("model", "")).strip(),
                    temperature=float(item.get("temperature", 0.7)),
                )
            )
    else:
        updated_providers = current.providers

    vault_path = str(payload.get("vault_path", current.vault_path)).strip() or current.vault_path
    public_base_url = (
        str(payload.get("public_base_url", current.public_base_url)).strip().rstrip("/")
        if "public_base_url" in payload
        else current.public_base_url
    )
    active_id = str(payload.get("active_provider_id", current.active_provider_id)).strip()
    if updated_providers and active_id not in {p.id for p in updated_providers}:
        active_id = updated_providers[0].id

    access_token = current.access_token
    if payload.get("clear_access_token"):
        access_token = ""
    elif "access_token" in payload and str(payload["access_token"]).strip():
        access_token = str(payload["access_token"]).strip()

    emb = current.embedding
    if isinstance(payload.get("embedding"), dict):
        e_in = payload["embedding"]
        e_key_in = str(e_in.get("api_key", "")).strip()
        if e_in.get("clear_api_key"):
            e_final_key = ""
        elif e_key_in:
            e_final_key = e_key_in
        else:
            e_final_key = current.embedding.api_key
        emb = EmbeddingConfig(
            mode=e_in.get("mode", current.embedding.mode),
            local_model=str(e_in.get("local_model", current.embedding.local_model)).strip()
            or "BAAI/bge-small-zh-v1.5",
            api_base_url=str(e_in.get("api_base_url", current.embedding.api_base_url)).strip()
            or "https://api.openai.com/v1",
            api_key=e_final_key,
            api_model=str(e_in.get("api_model", current.embedding.api_model)).strip()
            or "text-embedding-3-small",
        )

    return AppConfig(
        vault_path=vault_path,
        access_token=access_token,
        public_base_url=public_base_url,
        active_provider_id=active_id,
        providers=updated_providers,
        embedding=emb,
    )


def get_network_info(port: int | None = None) -> dict:
    if port is None:
        port = int(os.environ.get("ADVISOR_PORT", "8789"))
    lan_ip = ""
    tailscale_ip = ""
    for iface in ("en0", "en1"):
        try:
            res = subprocess.run(
                ["ipconfig", "getifaddr", iface],
                capture_output=True,
                text=True,
                timeout=1.5,
                check=False,
            )
            if res.returncode == 0 and res.stdout.strip():
                lan_ip = res.stdout.strip()
                break
        except Exception:
            pass

    if not lan_ip:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("8.8.8.8", 80))
                lan_ip = s.getsockname()[0]
        except Exception:
            lan_ip = ""

    try:
        res = subprocess.run(
            ["tailscale", "ip", "-4"],
            capture_output=True,
            text=True,
            timeout=1.5,
            check=False,
        )
        if res.returncode == 0 and res.stdout.strip():
            tailscale_ip = res.stdout.strip().splitlines()[0].strip()
    except Exception:
        pass

    return {
        "local_url": f"http://127.0.0.1:{port}",
        "lan_url": f"http://{lan_ip}:{port}" if lan_ip else "",
        "tailscale_url": f"http://{tailscale_ip}:{port}" if tailscale_ip else "",
    }
