from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, AsyncIterator

import httpx

from .chatgpt_oauth import ChatGPTOAuthError, get_valid_access_token
from .config import ProviderPreset, normalize_reasoning_effort


def _base_model_name(model: str) -> str:
    clean = model.strip().lower()
    if "/" in clean:
        clean = clean.rsplit("/", 1)[-1]
    return clean


def _uses_openai_max_completion_tokens(model: str) -> bool:
    name = _base_model_name(model)
    return bool(re.match(r"^(?:gpt-(?:[5-9]|[1-9]\d+)|o[1-9])(?:[-.]|$)", name))


def _is_legacy_non_reasoning_openai(model: str) -> bool:
    name = _base_model_name(model)
    return bool(re.match(r"^(?:gpt-(?:3\.5|4)|chatgpt-4o)(?:[-.]|$)", name))


def _openai_supports_xhigh(model: str) -> bool:
    name = _base_model_name(model)
    return bool(re.match(r"^gpt-(?:5\.[2-9]|5\.\d{2,}|[6-9]|[1-9]\d+)(?:[-.]|$)", name))


def _openai_allows_none_effort(model: str) -> bool:
    name = _base_model_name(model)
    return bool(re.match(r"^gpt-5\.[1-9](?:[-.]|$)", name))


def _openai_disallows_temperature(model: str) -> bool:
    name = _base_model_name(model)
    return bool(
        re.match(
            r"^(?:gpt-(?:[5-9]|[1-9]\d+)|o[1-9]|deepseek-reasoner|deepseek-v4|deepseek-flash)(?:[-.]|$)",
            name,
        )
    )


def _claude_version(model: str) -> tuple[int, int] | None:
    name = _base_model_name(model)
    if not name.startswith("claude-"):
        return None
    m = re.match(r"^claude-(?:[a-z]+-)?(\d+)(?:[-.](\d+))?(?:[-.]|$)", name)
    if not m:
        return None
    major = int(m.group(1))
    minor = int(m.group(2)) if m.group(2) is not None else 0
    return (major, minor)


def _claude_disallows_temperature(model: str) -> bool:
    ver = _claude_version(model)
    return ver is not None and ver >= (4, 7)


def _gemini_version(model: str) -> tuple[int, int] | None:
    name = _base_model_name(model)
    if not name.startswith("gemini-"):
        return None
    m = re.match(r"^gemini-(\d+)(?:\.(\d+))?(?:[-.]|$)", name)
    if not m:
        return None
    major = int(m.group(1))
    minor = int(m.group(2)) if m.group(2) is not None else 0
    return (major, minor)


def _gemini_disallows_temperature(model: str) -> bool:
    ver = _gemini_version(model)
    return ver is not None and ver >= (4, 0)


def _resolve_effective_effort(provider: ProviderPreset, reasoning_effort: str | None) -> str:
    if reasoning_effort is not None:
        return normalize_reasoning_effort(reasoning_effort)
    return normalize_reasoning_effort(provider.reasoning_effort)


def _effective_max_tokens(base_max_tokens: int, effort: str) -> int:
    if base_max_tokens < 4096 or effort in {"auto", "none", "low"}:
        return base_max_tokens
    if effort == "medium":
        return max(base_max_tokens, 8192)
    if effort == "high":
        return max(base_max_tokens, 16384)
    if effort == "xhigh":
        return max(base_max_tokens, 32768)
    return base_max_tokens


class ProviderError(RuntimeError):
    """Raised when an upstream LLM provider returns an error or invalid payload."""


@dataclass
class ChatCompletionResult:
    content: str
    reasoning: str = ""
    model: str = ""
    provider_id: str = ""
    usage: dict[str, Any] | None = None


def _normalize_openai_endpoint(base_url: str) -> str:
    clean = base_url.strip().rstrip("/")
    if not clean:
        return "https://api.openai.com/v1/chat/completions"
    if clean.endswith("/chat/completions"):
        return clean
    if clean.endswith("/v1") or clean.endswith("/v1beta/openai"):
        return f"{clean}/chat/completions"
    return f"{clean}/v1/chat/completions"


def _normalize_openai_responses_endpoint(base_url: str) -> str:
    clean = base_url.strip().rstrip("/")
    if not clean:
        return "https://api.openai.com/v1/responses"
    if clean.endswith("/responses"):
        return clean
    if clean.endswith("/v1"):
        return f"{clean}/responses"
    return f"{clean}/v1/responses"


def _normalize_claude_endpoint(base_url: str) -> str:
    clean = base_url.strip().rstrip("/")
    if not clean:
        return "https://api.anthropic.com/v1/messages"
    if clean.endswith("/v1/messages"):
        return clean
    if clean.endswith("/v1"):
        return f"{clean}/messages"
    return f"{clean}/v1/messages"


def _normalize_gemini_endpoint(base_url: str, model: str, *, stream: bool = False) -> str:
    clean = base_url.strip().rstrip("/")
    if not clean:
        clean = "https://generativelanguage.googleapis.com"
    action = "streamGenerateContent?alt=sse" if stream else "generateContent"
    if ":generateContent" in clean:
        return clean.replace(":generateContent", f":{action}") if stream else clean
    if ":streamGenerateContent" in clean:
        return clean
    if clean.endswith("/v1beta") or clean.endswith("/v1"):
        return f"{clean}/models/{model}:{action}"
    return f"{clean}/v1beta/models/{model}:{action}"


def build_provider_request(
    provider: ProviderPreset,
    system_prompt: str,
    messages: list[dict[str, str]],
    *,
    temperature: float | None = None,
    max_tokens: int = 4096,
    stream: bool = False,
    oauth_access_token: str | None = None,
    reasoning_effort: str | None = None,
) -> tuple[str, dict[str, str], dict[str, Any]]:
    temp = provider.temperature if temperature is None else temperature
    effort = _resolve_effective_effort(provider, reasoning_effort)
    effective_max = _effective_max_tokens(max_tokens, effort)

    if provider.kind == "chatgpt_oauth":
        url = _normalize_openai_responses_endpoint(provider.base_url or "https://api.openai.com/v1")
        token = (oauth_access_token if oauth_access_token is not None else provider.api_key).strip()
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }
        input_items: list[dict[str, Any]] = []
        for m in messages:
            role = m.get("role", "user")
            text = str(m.get("content", ""))
            if role == "assistant":
                input_items.append(
                    {
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": text}],
                    }
                )
            else:
                clean_role = role if role in {"user", "developer", "system"} else "user"
                input_items.append(
                    {
                        "role": clean_role,
                        "content": [{"type": "input_text", "text": text}],
                    }
                )
        # OpenAI Sign in with ChatGPT plan usage requires Responses API with store=False and stream=True.
        body: dict[str, Any] = {
            "model": provider.model,
            "input": input_items,
            "store": False,
            "stream": True,
        }
        if system_prompt:
            body["instructions"] = system_prompt
        if effort != "auto" and not _is_legacy_non_reasoning_openai(provider.model):
            mapped_effort = effort
            if effort == "none" and not _openai_allows_none_effort(provider.model):
                mapped_effort = "low"
            elif effort == "xhigh" and not _openai_supports_xhigh(provider.model):
                mapped_effort = "high"
            body["reasoning"] = {"effort": mapped_effort}
        return url, headers, body

    if provider.kind in {"deepseek", "openai_compatible"}:
        default_base = "https://api.deepseek.com/v1" if provider.kind == "deepseek" else "https://api.openai.com/v1"
        url = _normalize_openai_endpoint(provider.base_url or default_base)
        headers = {
            "Authorization": f"Bearer {provider.api_key}",
            "Content-Type": "application/json",
        }
        payload_messages = []
        if system_prompt:
            payload_messages.append({"role": "system", "content": system_prompt})
        for m in messages:
            role = m.get("role", "user")
            if role not in {"user", "assistant", "system"}:
                role = "user"
            payload_messages.append({"role": role, "content": m.get("content", "")})
        body: dict[str, Any] = {
            "model": provider.model,
            "messages": payload_messages,
        }
        if provider.kind == "openai_compatible" and _uses_openai_max_completion_tokens(provider.model):
            body["max_completion_tokens"] = effective_max
        else:
            body["max_tokens"] = effective_max
        if stream:
            body["stream"] = True
        allow_temp = not (
            _openai_disallows_temperature(provider.model)
            or _claude_disallows_temperature(provider.model)
            or _gemini_disallows_temperature(provider.model)
        )
        if effort != "auto":
            if provider.kind == "deepseek":
                if effort == "none":
                    body["thinking"] = {"type": "disabled"}
                    body["reasoning_effort"] = "none"
                else:
                    ds_map = {"low": "low", "medium": "medium", "high": "high", "xhigh": "max"}
                    body["thinking"] = {"type": "enabled"}
                    body["reasoning_effort"] = ds_map[effort]
                    allow_temp = False
            elif not _is_legacy_non_reasoning_openai(provider.model):
                name = _base_model_name(provider.model)
                mapped_effort = effort
                if re.match(r"^o[1-9](?:[-.]|$)", name):
                    if effort == "none":
                        mapped_effort = "low"
                    elif effort == "xhigh":
                        mapped_effort = "high"
                elif re.match(r"^gpt-(?:[6-9]|[1-9]\d+)(?:[-.]|$)", name):
                    if effort == "none":
                        mapped_effort = "low"
                elif re.match(r"^gpt-5(?:[-]|$)", name):
                    if effort == "none":
                        mapped_effort = "minimal"
                    elif effort == "xhigh":
                        mapped_effort = "high"
                body["reasoning_effort"] = mapped_effort
        if allow_temp:
            body["temperature"] = temp
        return url, headers, body

    if provider.kind == "claude":
        url = _normalize_claude_endpoint(provider.base_url)
        headers = {
            "x-api-key": provider.api_key,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json",
        }
        claude_messages = []
        for m in messages:
            role = "assistant" if m.get("role") == "assistant" else "user"
            claude_messages.append({"role": role, "content": m.get("content", "")})
        body = {
            "model": provider.model,
            "max_tokens": effective_max,
            "messages": claude_messages,
        }
        allow_temp = not _claude_disallows_temperature(provider.model)
        if effort != "auto":
            ver = _claude_version(provider.model)
            if effort == "none":
                body["thinking"] = {"type": "disabled"}
            elif ver is None or ver >= (4, 6):
                body["thinking"] = {"type": "adaptive"}
                body["output_config"] = {"effort": effort}
                allow_temp = False
            elif ver >= (3, 7):
                budgets = {"low": 2048, "medium": 6144, "high": 12288, "xhigh": 24576}
                budget = budgets[effort]
                body["thinking"] = {"type": "enabled", "budget_tokens": budget}
                body["max_tokens"] = max(effective_max, budget + 4096)
                allow_temp = False
        if allow_temp:
            body["temperature"] = temp
        if stream:
            body["stream"] = True
        if system_prompt:
            body["system"] = system_prompt
        return url, headers, body

    if provider.kind == "gemini":
        url = _normalize_gemini_endpoint(provider.base_url, provider.model, stream=stream)
        headers = {
            "x-goog-api-key": provider.api_key,
            "Content-Type": "application/json",
        }
        contents = []
        for m in messages:
            role = "model" if m.get("role") == "assistant" else "user"
            contents.append({"role": role, "parts": [{"text": m.get("content", "")}]})
        generation_config: dict[str, Any] = {
            "maxOutputTokens": effective_max,
        }
        if not _gemini_disallows_temperature(provider.model):
            generation_config["temperature"] = temp
        if effort != "auto":
            ver = _gemini_version(provider.model)
            name = _base_model_name(provider.model)
            if ver is None or ver >= (3, 0):
                if effort == "none":
                    level = "minimal" if ("flash" in name or "lite" in name) else "low"
                    generation_config["thinkingConfig"] = {"thinkingLevel": level}
                else:
                    level = "high" if (effort == "xhigh" and ver is not None and ver < (4, 0)) else effort
                    generation_config["thinkingConfig"] = {
                        "thinkingLevel": level,
                        "includeThoughts": True,
                    }
            elif ver >= (2, 5):
                if effort == "none":
                    budget = 0 if "flash" in name else 1024
                    generation_config["thinkingConfig"] = {"thinkingBudget": budget}
                else:
                    budgets = {"low": 2048, "medium": 8192, "high": 16384, "xhigh": 24576}
                    budget = budgets[effort]
                    generation_config["thinkingConfig"] = {
                        "thinkingBudget": budget,
                        "includeThoughts": True,
                    }
                    generation_config["maxOutputTokens"] = max(effective_max, budget + 4096)
        body = {
            "contents": contents,
            "generationConfig": generation_config,
        }
        if system_prompt:
            body["systemInstruction"] = {"parts": [{"text": system_prompt}]}
        return url, headers, body

    raise ProviderError(f"不支持的模型提供商类型: {provider.kind}")


def _extract_responses_output_parts(data: dict[str, Any]) -> tuple[str, str]:
    """Extract (content, reasoning) from an OpenAI Responses API object."""
    texts: list[str] = []
    reasonings: list[str] = []

    if isinstance(data.get("output_text"), str) and data["output_text"].strip():
        texts.append(data["output_text"])

    output = data.get("output") or []
    if isinstance(output, list):
        for item in output:
            if not isinstance(item, dict):
                continue
            item_type = item.get("type")
            if item_type == "message":
                for part in item.get("content") or []:
                    if isinstance(part, dict) and part.get("type") in {"output_text", "text"}:
                        t = str(part.get("text") or "")
                        if t:
                            texts.append(t)
            elif item_type == "reasoning":
                for s in item.get("summary") or []:
                    if isinstance(s, dict) and s.get("text"):
                        reasonings.append(str(s["text"]))

    return "\n".join(texts).strip(), "\n".join(reasonings).strip()


def parse_provider_response(provider: ProviderPreset, data: dict[str, Any]) -> ChatCompletionResult:
    if provider.kind == "chatgpt_oauth":
        content, reasoning = _extract_responses_output_parts(data)
        return ChatCompletionResult(
            content=content,
            reasoning=reasoning,
            model=str(data.get("model") or provider.model),
            provider_id=provider.id,
            usage=data.get("usage"),
        )

    if provider.kind in {"deepseek", "openai_compatible"}:
        choices = data.get("choices") or []
        if not choices:
            raise ProviderError(f"上游返回缺少 choices: {data}")
        msg = choices[0].get("message") or {}
        content = msg.get("content") or ""
        if isinstance(content, list):
            content = "\n".join(str(p.get("text", "")) for p in content if isinstance(p, dict))
        reasoning = str(msg.get("reasoning_content") or "")
        return ChatCompletionResult(
            content=str(content).strip(),
            reasoning=reasoning.strip(),
            model=str(data.get("model") or provider.model),
            provider_id=provider.id,
            usage=data.get("usage"),
        )

    if provider.kind == "claude":
        blocks = data.get("content") or []
        texts = []
        thinking = []
        for b in blocks:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                texts.append(str(b.get("text", "")))
            elif b.get("type") == "thinking":
                thinking.append(str(b.get("thinking", "")))
        return ChatCompletionResult(
            content="\n".join(texts).strip(),
            reasoning="\n".join(thinking).strip(),
            model=str(data.get("model") or provider.model),
            provider_id=provider.id,
            usage=data.get("usage"),
        )

    if provider.kind == "gemini":
        candidates = data.get("candidates") or []
        if not candidates:
            raise ProviderError(f"Gemini 未返回有效候选结果: {data}")
        parts = ((candidates[0].get("content") or {}).get("parts")) or []
        texts = []
        thoughts = []
        for p in parts:
            if not isinstance(p, dict) or not p.get("text"):
                continue
            if p.get("thought"):
                thoughts.append(str(p.get("text", "")))
            else:
                texts.append(str(p.get("text", "")))
        return ChatCompletionResult(
            content="\n".join(texts).strip(),
            reasoning="\n".join(thoughts).strip(),
            model=provider.model,
            provider_id=provider.id,
            usage=data.get("usageMetadata"),
        )

    raise ProviderError(f"未知的提供商类型: {provider.kind}")


def _format_chatgpt_http_error(status_code: int, raw_detail: str, provider_name: str) -> str:
    detail = raw_detail[:600]
    hint = ""
    if status_code == 401:
        hint = "（ChatGPT 授权可能已过期，请在「设置 → 大模型」重新点击授权登录）"
    elif status_code == 403:
        hint = "（请确认授权时已同意使用 ChatGPT 订阅额度，且工作区未禁用第三方应用额度）"
    elif status_code == 429:
        hint = "（已达 ChatGPT 订阅额度或该应用每周限额，可在 ChatGPT 设置 → Usage 中查看或调整上限）"
    return f"上游 API 返回 HTTP {status_code}（{provider_name}）: {detail}{hint}"


async def _iter_chatgpt_oauth_responses_stream(
    provider: ProviderPreset,
    system_prompt: str,
    messages: list[dict[str, str]],
    *,
    temperature: float | None = None,
    max_tokens: int = 4096,
    timeout: float = 180.0,
    meta_out: dict[str, Any] | None = None,
    reasoning_effort: str | None = None,
) -> AsyncIterator[dict[str, str]]:
    if not provider.model.strip():
        raise ProviderError(f"模型「{provider.name}」尚未填写模型名称。")

    for attempt in range(2):
        try:
            access_token = await get_valid_access_token(force_refresh=(attempt == 1))
        except ChatGPTOAuthError as exc:
            raise ProviderError(str(exc)) from exc

        url, headers, body = build_provider_request(
            provider,
            system_prompt,
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            stream=True,
            oauth_access_token=access_token,
            reasoning_effort=reasoning_effort,
        )

        emitted_text = False
        emitted_reasoning = False
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                async with client.stream("POST", url, headers=headers, json=body) as resp:
                    if resp.status_code == 401 and attempt == 0:
                        await resp.aread()
                        continue
                    if resp.status_code >= 400:
                        err_bytes = await resp.aread()
                        raise ProviderError(
                            _format_chatgpt_http_error(
                                resp.status_code,
                                err_bytes.decode("utf-8", "ignore"),
                                provider.name,
                            )
                        )

                    ctype = (resp.headers.get("content-type") or "").lower()
                    if "application/json" in ctype and "text/event-stream" not in ctype:
                        raw_body = await resp.aread()
                        data = json.loads(raw_body.decode("utf-8", "ignore"))
                        text_out, reason_out = _extract_responses_output_parts(data)
                        if meta_out is not None:
                            meta_out["model"] = str(data.get("model") or provider.model)
                            meta_out["usage"] = data.get("usage")
                        if reason_out:
                            yield {"type": "reasoning", "delta": reason_out}
                        if text_out:
                            yield {"type": "text", "delta": text_out}
                        return

                    async for raw_line in resp.aiter_lines():
                        line = raw_line.strip()
                        if not line or not line.startswith("data:"):
                            continue
                        payload_str = line[5:].strip()
                        if not payload_str or payload_str == "[DONE]":
                            continue
                        try:
                            chunk = json.loads(payload_str)
                        except Exception:
                            continue

                        ev_type = str(chunk.get("type") or "")
                        if ev_type == "response.output_text.delta":
                            delta = chunk.get("delta")
                            if delta:
                                emitted_text = True
                                yield {"type": "text", "delta": str(delta)}
                        elif ev_type in {
                            "response.reasoning_summary_text.delta",
                            "response.reasoning_text.delta",
                        }:
                            delta = chunk.get("delta")
                            if delta:
                                emitted_reasoning = True
                                yield {"type": "reasoning", "delta": str(delta)}
                        elif ev_type == "response.failed":
                            err_obj = (chunk.get("response") or {}).get("error") or chunk.get("error") or {}
                            err_msg = err_obj.get("message") if isinstance(err_obj, dict) else str(err_obj)
                            raise ProviderError(f"ChatGPT 响应失败（{provider.name}）: {err_msg or '未知错误'}")
                        elif ev_type == "error":
                            err_obj = chunk.get("error") if isinstance(chunk.get("error"), dict) else chunk
                            err_msg = err_obj.get("message") or str(err_obj)
                            raise ProviderError(f"ChatGPT 接口错误（{provider.name}）: {err_msg}")
                        elif ev_type == "response.completed":
                            resp_obj = chunk.get("response") or {}
                            if isinstance(resp_obj, dict):
                                if meta_out is not None:
                                    meta_out["model"] = str(resp_obj.get("model") or provider.model)
                                    meta_out["usage"] = resp_obj.get("usage")
                                if not emitted_text or not emitted_reasoning:
                                    fallback_text, fallback_reason = _extract_responses_output_parts(resp_obj)
                                    if fallback_reason and not emitted_reasoning:
                                        emitted_reasoning = True
                                        yield {"type": "reasoning", "delta": fallback_reason}
                                    if fallback_text and not emitted_text:
                                        emitted_text = True
                                        yield {"type": "text", "delta": fallback_text}
                    return
        except httpx.RequestError as exc:
            raise ProviderError(f"流式网络请求失败（{provider.name}）: {exc}") from exc


async def call_llm(
    provider: ProviderPreset,
    system_prompt: str,
    messages: list[dict[str, str]],
    *,
    temperature: float | None = None,
    max_tokens: int = 4096,
    timeout: float = 120.0,
    reasoning_effort: str | None = None,
) -> ChatCompletionResult:
    if provider.kind == "chatgpt_oauth":
        meta_out: dict[str, Any] = {}
        texts: list[str] = []
        reasonings: list[str] = []
        async for chunk in _iter_chatgpt_oauth_responses_stream(
            provider,
            system_prompt,
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            timeout=timeout,
            meta_out=meta_out,
            reasoning_effort=reasoning_effort,
        ):
            if chunk["type"] == "text":
                texts.append(chunk["delta"])
            elif chunk["type"] == "reasoning":
                reasonings.append(chunk["delta"])
        return ChatCompletionResult(
            content="".join(texts).strip(),
            reasoning="".join(reasonings).strip(),
            model=str(meta_out.get("model") or provider.model),
            provider_id=provider.id,
            usage=meta_out.get("usage"),
        )

    if not provider.api_key.strip():
        raise ProviderError(f"模型「{provider.name}」尚未配置 API Key，请先在「设置」中填写。")
    if not provider.model.strip():
        raise ProviderError(f"模型「{provider.name}」尚未填写模型名称。")

    url, headers, body = build_provider_request(
        provider,
        system_prompt,
        messages,
        temperature=temperature,
        max_tokens=max_tokens,
        stream=False,
        reasoning_effort=reasoning_effort,
    )

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(url, headers=headers, json=body)
    except httpx.RequestError as exc:
        raise ProviderError(f"网络请求失败（{provider.name}）: {exc}") from exc

    if resp.status_code >= 400:
        detail = resp.text[:600]
        raise ProviderError(f"上游 API 返回 HTTP {resp.status_code}（{provider.name}）: {detail}")

    try:
        data = resp.json()
    except Exception as exc:
        raise ProviderError(f"上游返回不是合法 JSON: {resp.text[:300]}") from exc

    return parse_provider_response(provider, data)


async def stream_llm(
    provider: ProviderPreset,
    system_prompt: str,
    messages: list[dict[str, str]],
    *,
    temperature: float | None = None,
    max_tokens: int = 4096,
    timeout: float = 180.0,
    reasoning_effort: str | None = None,
) -> AsyncIterator[dict[str, str]]:
    """Yields normalized SSE chunks: {'type': 'text' | 'reasoning', 'delta': '...'}."""
    if provider.kind == "chatgpt_oauth":
        async for chunk in _iter_chatgpt_oauth_responses_stream(
            provider,
            system_prompt,
            messages,
            temperature=temperature,
            max_tokens=max_tokens,
            timeout=timeout,
            reasoning_effort=reasoning_effort,
        ):
            yield chunk
        return

    if not provider.api_key.strip():
        raise ProviderError(f"模型「{provider.name}」尚未配置 API Key，请先在「设置」中填写。")
    if not provider.model.strip():
        raise ProviderError(f"模型「{provider.name}」尚未填写模型名称。")

    url, headers, body = build_provider_request(
        provider,
        system_prompt,
        messages,
        temperature=temperature,
        max_tokens=max_tokens,
        stream=True,
        reasoning_effort=reasoning_effort,
    )

    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            async with client.stream("POST", url, headers=headers, json=body) as resp:
                if resp.status_code >= 400:
                    err_bytes = await resp.aread()
                    raise ProviderError(
                        f"上游 API 返回 HTTP {resp.status_code}（{provider.name}）: {err_bytes.decode('utf-8', 'ignore')[:500]}"
                    )

                async for raw_line in resp.aiter_lines():
                    line = raw_line.strip()
                    if not line or not line.startswith("data:"):
                        continue
                    payload_str = line[5:].strip()
                    if not payload_str or payload_str == "[DONE]":
                        continue
                    try:
                        chunk = json.loads(payload_str)
                    except Exception:
                        continue

                    if provider.kind in {"deepseek", "openai_compatible"}:
                        choices = chunk.get("choices") or []
                        if not choices:
                            continue
                        delta = choices[0].get("delta") or {}
                        r_delta = delta.get("reasoning_content")
                        if r_delta:
                            yield {"type": "reasoning", "delta": str(r_delta)}
                        c_delta = delta.get("content")
                        if c_delta:
                            yield {"type": "text", "delta": str(c_delta)}

                    elif provider.kind == "claude":
                        ev_type = chunk.get("type")
                        if ev_type == "content_block_delta":
                            delta = chunk.get("delta") or {}
                            if delta.get("type") == "text_delta" and delta.get("text"):
                                yield {"type": "text", "delta": str(delta["text"])}
                            elif delta.get("type") == "thinking_delta" and delta.get("thinking"):
                                yield {"type": "reasoning", "delta": str(delta["thinking"])}

                    elif provider.kind == "gemini":
                        candidates = chunk.get("candidates") or []
                        if not candidates:
                            continue
                        parts = ((candidates[0].get("content") or {}).get("parts")) or []
                        for p in parts:
                            if isinstance(p, dict) and p.get("text"):
                                chunk_type = "reasoning" if p.get("thought") else "text"
                                yield {"type": chunk_type, "delta": str(p["text"])}
    except httpx.RequestError as exc:
        raise ProviderError(f"流式网络请求失败（{provider.name}）: {exc}") from exc
