from __future__ import annotations

import base64
import io
import json
import re
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .memory_store import strip_private_blocks

MAX_ZIP_TOTAL_BYTES = 50 * 1024 * 1024
MAX_SINGLE_FILE_BYTES = 25 * 1024 * 1024
MAX_ZIP_FILES = 200
MAX_PREVIEW_ITEMS = 180
DEFAULT_SELECT_CHAR_BUDGET = 30000

IMPORT_PROMPT_TEMPLATES: list[dict[str, str]] = [
    {
        "id": "universal_full",
        "title": "完整画像迁移提示词（推荐 · 全平台通用）",
        "subtitle": "适用于 ChatGPT、Claude、Gemini、DeepSeek、豆包等任意对话 AI",
        "prompt": (
            "我正在把我的长期个人记忆迁移到自己的本地个人决策顾问中。请你把我过去与你对话里、以及你「记忆/自定义指令」中记住的关于我的一切重要信息，整理成一份清晰、客观、无客套废话的 Markdown 个人档案。\n\n"
            "请按以下 6 个小节输出（如果某个小节你没有确切记忆，直接写「暂无记录」，严禁编造）：\n"
            "1. **我是谁与当下阶段**：称呼、职业/角色、所在领域、当前阶段与生活重心\n"
            "2. **核心价值观与红线底线**：我最看重的原则、明确厌恶或拒绝的事情\n"
            "3. **性格、情绪与决策模式**：我常见的情绪触发点、高压下的反应、充能/消耗来源、沟通偏好\n"
            "4. **重要人物与关系**：我在对话中反复提到的重要家人、伴侣、朋友、同事或导师及关系背景\n"
            "5. **关键经历、过往决策与认知变化**：对我影响较大的事件、做过的重要取舍或观念转变（尽量附大致时间）\n"
            "6. **当下正在思考的课题与目标**：未来 6–12 个月我关心的目标、项目或仍在纠结的选择\n\n"
            "要求：请用简洁的要点列表输出，不要包含账号密码或银行卡等绝密凭据，直接输出正文即可。"
        ),
    },
    {
        "id": "universal_compact",
        "title": "精简版：快速提取偏好与个人背景",
        "subtitle": "适合对话历史较短或只想先迁移核心自我画像的场景",
        "prompt": (
            "请用 Markdown 列表总结你在「记忆」和过往对话中了解到的关于我的所有事实，涵盖：我的背景与当下关注点、核心价值观与底线、沟通与工作偏好、常见纠结点，以及正在推进的目标。"
            "只写你有依据的内容，不要编造，直接输出完整内容。"
        ),
    },
]

_PERSONAL_CUES = [
    "我觉得",
    "我感觉",
    "我最近",
    "我一直",
    "我想",
    "我怕",
    "焦虑",
    "迷茫",
    "内耗",
    "后悔",
    "开心",
    "委屈",
    "难过",
    "压力",
    "纠结",
    "选择",
    "决定",
    "offer",
    "辞职",
    "跳槽",
    "转行",
    "人生",
    "价值观",
    "底线",
    "原则",
    "目标",
    "成长",
    "复盘",
    "反思",
    "家人",
    "父母",
    "伴侣",
    "朋友",
    "同事",
    "关系",
    "自我",
    "性格",
    "习惯",
    "职业",
    "规划",
    "情绪",
    "感受",
    "记忆",
    "my life",
    "i feel",
    "i'm feeling",
    "decision",
    "career",
    "values",
    "relationship",
    "anxiety",
    "regret",
    "goal",
    "personality",
    "about me",
    "remember that i",
]

_NOISE_CUES = [
    "traceback (most recent call last)",
    "syntaxerror",
    "typeerror",
    "npm err",
    "pip install",
    "docker compose",
    "select * from",
    "public static void",
    "console.log(",
    "帮我翻译",
    "翻译成英文",
    "翻译成中文",
    "润色一下这封邮件",
    "写一个正则",
    "sql语句",
    "报错如下",
    "leetcode",
]


def _ts_to_date(val: Any) -> str:
    if val is None or val == "":
        return ""
    if isinstance(val, (int, float)):
        try:
            if val > 1e12:
                val = val / 1000.0
            return datetime.fromtimestamp(float(val), tz=timezone.utc).strftime("%Y-%m-%d")
        except Exception:
            return ""
    s = str(val).strip()
    m = re.match(r"(\d{4}-\d{2}-\d{2})", s)
    return m.group(1) if m else s[:10]


def _make_preview(text: str, limit: int = 180) -> str:
    compact = re.sub(r"\s+", " ", strip_private_blocks(text)).strip()
    return (compact[:limit] + "…") if len(compact) > limit else compact


def _score_conversation_signal(title: str, user_text: str, full_text: str, turn_count: int) -> tuple[int, bool]:
    """Score 0-100 how likely a historical chat contains valuable personal memory vs. ephemeral coding Q&A."""
    if len(user_text.strip()) < 25 or len(full_text.strip()) < 60:
        return 5, False

    haystack = f"{title}\n{user_text[:4000]}".lower()
    score = 30

    personal_hits = sum(1 for cue in _PERSONAL_CUES if cue in haystack)
    score += min(45, personal_hits * 9)

    noise_hits = sum(1 for cue in _NOISE_CUES if cue in full_text[:5000].lower())
    score -= min(40, noise_hits * 12)

    code_fences = full_text.count("```")
    if code_fences >= 4 and personal_hits < 2:
        score -= 28
    elif code_fences >= 2 and personal_hits == 0:
        score -= 18

    if turn_count >= 4:
        score += 10
    elif turn_count == 1 and len(user_text) < 120:
        score -= 12

    if len(user_text) >= 400:
        score += 8

    score = max(0, min(100, score))
    recommended = score >= 45
    return score, recommended


def _extract_chatgpt_text_parts(message: dict[str, Any]) -> str:
    content = message.get("content")
    if not isinstance(content, dict):
        return ""
    parts = content.get("parts")
    if isinstance(parts, list):
        texts = [p.strip() for p in parts if isinstance(p, str) and p.strip()]
        if texts:
            return "\n".join(texts)
    text_val = content.get("text")
    if isinstance(text_val, str) and text_val.strip():
        return text_val.strip()
    return ""


def _parse_chatgpt_conversations(data: list[Any]) -> list[dict[str, Any]]:
    chunks: list[dict[str, Any]] = []
    for idx, conv in enumerate(data):
        if not isinstance(conv, dict) or not isinstance(conv.get("mapping"), dict):
            continue
        title = str(conv.get("title") or f"ChatGPT 对话 #{idx + 1}").strip()
        date_str = _ts_to_date(conv.get("create_time") or conv.get("update_time"))
        mapping: dict[str, Any] = conv["mapping"]
        current = conv.get("current_node")

        ordered_nodes: list[dict[str, Any]] = []
        if isinstance(current, str) and current in mapping:
            seen: set[str] = set()
            node_id: str | None = current
            while node_id and node_id in mapping and node_id not in seen:
                seen.add(node_id)
                node = mapping[node_id]
                if isinstance(node, dict):
                    ordered_nodes.append(node)
                    parent = node.get("parent")
                    node_id = parent if isinstance(parent, str) else None
                else:
                    break
            ordered_nodes.reverse()
        else:
            # Fallback: sort all mapping nodes by create_time
            nodes = [n for n in mapping.values() if isinstance(n, dict)]
            nodes.sort(key=lambda n: float((n.get("message") or {}).get("create_time") or 0))
            ordered_nodes = nodes

        turns: list[str] = []
        user_texts: list[str] = []
        for node in ordered_nodes:
            msg = node.get("message")
            if not isinstance(msg, dict):
                continue
            role = str((msg.get("author") or {}).get("role") or "").lower()
            if role not in {"user", "assistant"}:
                continue
            text = _extract_chatgpt_text_parts(msg)
            if not text:
                continue
            prefix = "我" if role == "user" else "ChatGPT"
            if role == "user":
                user_texts.append(text)
            # Keep assistant replies concise so user voice dominates
            snippet = text[:1600] + ("…" if len(text) > 1600 else "")
            turns.append(f"【{prefix}】：{snippet}")

        if not user_texts:
            continue

        transcript = f"# {title}\n日期：{date_str or '未知'}\n\n" + "\n\n".join(turns)
        if len(transcript) > 7000:
            transcript = transcript[:7000] + "\n…（已截断超长对话尾部）"

        user_joined = "\n".join(user_texts)
        signal, recommended = _score_conversation_signal(title, user_joined, transcript, len(turns))
        chunks.append(
            {
                "id": f"cgpt_{idx + 1}",
                "source_type": "chatgpt_export",
                "source_label": "ChatGPT 对话导出",
                "title": title,
                "date": date_str,
                "char_count": len(transcript),
                "signal_score": signal,
                "recommended": recommended,
                "preview": _make_preview(user_joined),
                "content": transcript,
            }
        )
    return chunks


def _extract_claude_message_text(msg: dict[str, Any]) -> str:
    text = msg.get("text")
    if isinstance(text, str) and text.strip():
        return text.strip()
    content = msg.get("content")
    if isinstance(content, list):
        parts: list[str] = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                if block["text"].strip():
                    parts.append(block["text"].strip())
        if parts:
            return "\n".join(parts)
    return ""


def _parse_claude_conversations(data: list[Any]) -> list[dict[str, Any]]:
    chunks: list[dict[str, Any]] = []
    for idx, conv in enumerate(data):
        if not isinstance(conv, dict) or not isinstance(conv.get("chat_messages"), list):
            continue
        title = str(conv.get("name") or conv.get("title") or f"Claude 对话 #{idx + 1}").strip()
        date_str = _ts_to_date(conv.get("created_at") or conv.get("updated_at"))
        turns: list[str] = []
        user_texts: list[str] = []
        for msg in conv["chat_messages"]:
            if not isinstance(msg, dict):
                continue
            sender = str(msg.get("sender") or msg.get("role") or "").lower()
            if sender not in {"human", "user", "assistant"}:
                continue
            text = _extract_claude_message_text(msg)
            if not text:
                continue
            is_user = sender in {"human", "user"}
            if is_user:
                user_texts.append(text)
            prefix = "我" if is_user else "Claude"
            snippet = text[:1600] + ("…" if len(text) > 1600 else "")
            turns.append(f"【{prefix}】：{snippet}")

        if not user_texts:
            continue

        transcript = f"# {title}\n日期：{date_str or '未知'}\n\n" + "\n\n".join(turns)
        if len(transcript) > 7000:
            transcript = transcript[:7000] + "\n…（已截断超长对话尾部）"

        user_joined = "\n".join(user_texts)
        signal, recommended = _score_conversation_signal(title, user_joined, transcript, len(turns))
        chunks.append(
            {
                "id": f"claude_conv_{idx + 1}",
                "source_type": "claude_export",
                "source_label": "Claude 对话导出",
                "title": title,
                "date": date_str,
                "char_count": len(transcript),
                "signal_score": signal,
                "recommended": recommended,
                "preview": _make_preview(user_joined),
                "content": transcript,
            }
        )
    return chunks


def _parse_claude_memories(data: Any) -> list[dict[str, Any]]:
    chunks: list[dict[str, Any]] = []

    def add_mem_chunk(idx: int, title: str, text: str, date_str: str = "") -> None:
        clean = text.strip()
        if not clean:
            return
        chunks.append(
            {
                "id": f"claude_mem_{idx}",
                "source_type": "claude_memories",
                "source_label": "Claude 官方记忆",
                "title": title,
                "date": date_str,
                "char_count": len(clean),
                "signal_score": 95,
                "recommended": True,
                "preview": _make_preview(clean),
                "content": f"# {title}\n\n{clean}",
            }
        )

    entries = data if isinstance(data, list) else ([data] if isinstance(data, dict) else [])
    seq = 1
    bullet_lines: list[str] = []
    for item in entries:
        if not isinstance(item, dict):
            if isinstance(item, str) and item.strip():
                bullet_lines.append(f"- {item.strip()}")
            continue
        if isinstance(item.get("conversations_memory"), str) and item["conversations_memory"].strip():
            add_mem_chunk(seq, "Claude 长期对话记忆", item["conversations_memory"])
            seq += 1
        proj_mems = item.get("project_memories")
        if isinstance(proj_mems, dict):
            for proj_key, proj_val in proj_mems.items():
                if isinstance(proj_val, str) and proj_val.strip():
                    add_mem_chunk(seq, f"Claude 项目记忆 ({proj_key[:16]})", proj_val)
                    seq += 1
        elif isinstance(proj_mems, list):
            for p_idx, pm in enumerate(proj_mems, start=1):
                if isinstance(pm, dict):
                    body = str(pm.get("memory") or pm.get("content") or pm.get("text") or "").strip()
                    ptitle = str(pm.get("project_name") or pm.get("name") or f"Claude 项目记忆 #{p_idx}")
                    if body:
                        add_mem_chunk(seq, ptitle, body)
                        seq += 1
        # Flat item schema: {"text": "...", "created_at": "..."}
        for key in ("text", "content", "memory", "fact"):
            val = item.get(key)
            if isinstance(val, str) and val.strip():
                dt = _ts_to_date(item.get("created_at") or item.get("updated_at") or item.get("timestamp"))
                prefix = f"[{dt}] " if dt else ""
                bullet_lines.append(f"- {prefix}{val.strip()}")
                break

    if bullet_lines:
        # Group bullet lines into ~5000-char chunks
        cur: list[str] = []
        cur_len = 0
        part = 1
        for line in bullet_lines:
            if cur and cur_len + len(line) > 5000:
                add_mem_chunk(seq, f"Claude 记忆条目（第 {part} 组）", "\n".join(cur))
                seq += 1
                part += 1
                cur = []
                cur_len = 0
            cur.append(line)
            cur_len += len(line) + 1
        if cur:
            title = "Claude 记忆条目" if part == 1 else f"Claude 记忆条目（第 {part} 组）"
            add_mem_chunk(seq, title, "\n".join(cur))

    return chunks


def _parse_generic_memory_json(data: Any, filename: str) -> tuple[str, str, list[dict[str, Any]]]:
    """Parse Mem0, Portable AI Memory (PAM), Letta/MemGPT blocks, or generic memory JSON arrays."""
    detected_source = "generic_memory_json"
    detected_label = "通用记忆 JSON"
    items_out: list[dict[str, Any]] = []

    # Case 1: Letta / MemGPT core memory blocks
    if isinstance(data, dict) and (isinstance(data.get("core_memory"), dict) or isinstance(data.get("blocks"), list)):
        detected_source = "letta_json"
        detected_label = "Letta / MemGPT 记忆 JSON"
        blocks: list[tuple[str, str]] = []
        if isinstance(data.get("core_memory"), dict):
            for k, v in data["core_memory"].items():
                if isinstance(v, str) and v.strip():
                    blocks.append((str(k), v.strip()))
        if isinstance(data.get("blocks"), list):
            for b in data["blocks"]:
                if isinstance(b, dict):
                    lbl = str(b.get("label") or b.get("name") or "memory_block")
                    val = str(b.get("value") or b.get("content") or "").strip()
                    if val:
                        blocks.append((lbl, val))
        for idx, (lbl, val) in enumerate(blocks, start=1):
            items_out.append(
                {
                    "id": f"letta_{idx}",
                    "source_type": detected_source,
                    "source_label": detected_label,
                    "title": f"Core Block · {lbl}",
                    "date": "",
                    "char_count": len(val),
                    "signal_score": 95,
                    "recommended": True,
                    "preview": _make_preview(val),
                    "content": f"# {lbl}\n\n{val}",
                }
            )
        if items_out:
            return detected_source, detected_label, items_out

    # Case 2: Mem0 / PAM / Generic object containing list of memories
    raw_list: list[Any] = []
    profile_block = ""
    if isinstance(data, dict):
        if isinstance(data.get("profile"), dict):
            profile_block = json.dumps(data["profile"], ensure_ascii=False, indent=2)
        elif isinstance(data.get("profile"), str):
            profile_block = data["profile"].strip()

        if "results" in data and isinstance(data["results"], list):
            detected_source = "mem0_json"
            detected_label = "Mem0 记忆 JSON"
            raw_list = data["results"]
        elif "memories" in data and isinstance(data["memories"], list):
            detected_source = "pam_json" if ("schema" in data or "version" in data or "profile" in data) else "generic_memory_json"
            detected_label = "Portable AI Memory (PAM)" if detected_source == "pam_json" else "通用记忆 JSON"
            raw_list = data["memories"]
        elif "items" in data and isinstance(data["items"], list):
            raw_list = data["items"]
        elif "facts" in data and isinstance(data["facts"], list):
            raw_list = data["facts"]
        elif "data" in data and isinstance(data["data"], list):
            raw_list = data["data"]
    elif isinstance(data, list):
        raw_list = data
        if raw_list and isinstance(raw_list[0], dict) and "memory" in raw_list[0]:
            detected_source = "mem0_json"
            detected_label = "Mem0 记忆 JSON"

    seq = 1
    if profile_block:
        items_out.append(
            {
                "id": f"memjson_{seq}",
                "source_type": detected_source,
                "source_label": detected_label,
                "title": f"{Path(filename).stem or '外部档案'} · 用户画像",
                "date": "",
                "char_count": len(profile_block),
                "signal_score": 96,
                "recommended": True,
                "preview": _make_preview(profile_block),
                "content": f"# 用户画像\n\n{profile_block}",
            }
        )
        seq += 1

    entries_lines: list[str] = []
    for elem in raw_list:
        if isinstance(elem, str) and elem.strip():
            entries_lines.append(f"- {elem.strip()}")
            continue
        if not isinstance(elem, dict):
            continue
        text = ""
        for k in ("memory", "content", "text", "fact", "value", "summary", "note", "description"):
            v = elem.get(k)
            if isinstance(v, str) and v.strip():
                text = v.strip()
                break
        if not text:
            continue
        dt = _ts_to_date(elem.get("created_at") or elem.get("updated_at") or elem.get("date") or elem.get("timestamp"))
        cats = elem.get("categories") or elem.get("tags") or elem.get("category") or elem.get("type")
        if isinstance(cats, list):
            cat_str = "/".join(str(c) for c in cats if c)
        elif isinstance(cats, str):
            cat_str = cats.strip()
        else:
            cat_str = ""
        meta_bits = [b for b in (dt, cat_str) if b]
        prefix = f"[{' · '.join(meta_bits)}] " if meta_bits else ""
        entries_lines.append(f"- {prefix}{text}")

    if entries_lines:
        cur: list[str] = []
        cur_len = 0
        part = 1
        for line in entries_lines:
            if cur and cur_len + len(line) > 5500:
                body = "\n".join(cur)
                items_out.append(
                    {
                        "id": f"memjson_{seq}",
                        "source_type": detected_source,
                        "source_label": detected_label,
                        "title": f"{detected_label} · 第 {part} 批（{len(cur)} 条）",
                        "date": "",
                        "char_count": len(body),
                        "signal_score": 90,
                        "recommended": True,
                        "preview": _make_preview(body),
                        "content": f"# {detected_label}（第 {part} 批）\n\n{body}",
                    }
                )
                seq += 1
                part += 1
                cur = []
                cur_len = 0
            cur.append(line)
            cur_len += len(line) + 1
        if cur:
            body = "\n".join(cur)
            title = (
                f"{detected_label}（共 {len(cur)} 条）"
                if part == 1
                else f"{detected_label} · 第 {part} 批（{len(cur)} 条）"
            )
            items_out.append(
                {
                    "id": f"memjson_{seq}",
                    "source_type": detected_source,
                    "source_label": detected_label,
                    "title": title,
                    "date": "",
                    "char_count": len(body),
                    "signal_score": 90,
                    "recommended": True,
                    "preview": _make_preview(body),
                    "content": f"# {title}\n\n{body}",
                }
            )
    elif isinstance(data, dict) and not items_out:
        # Fallback: stringify compact JSON object if it contains text
        pretty = json.dumps(data, ensure_ascii=False, indent=2)
        if len(pretty) >= 20:
            trimmed = pretty[:8000]
            items_out.append(
                {
                    "id": "memjson_1",
                    "source_type": detected_source,
                    "source_label": detected_label,
                    "title": Path(filename).stem or "JSON 记忆文件",
                    "date": "",
                    "char_count": len(trimmed),
                    "signal_score": 75,
                    "recommended": True,
                    "preview": _make_preview(trimmed),
                    "content": trimmed,
                }
            )

    return detected_source, detected_label, items_out


def _split_long_text(text: str, max_chunk_chars: int = 6500) -> list[tuple[str, str]]:
    """Split long markdown/plain text along headings or paragraphs into manageable chunks."""
    clean = text.strip()
    if len(clean) <= max_chunk_chars:
        return [("", clean)]

    # Split on top-level/second-level Markdown headings first
    sections = re.split(r"(?m)^(?=#{1,2}\s+)", clean)
    chunks: list[tuple[str, str]] = []
    cur_buf: list[str] = []
    cur_len = 0
    cur_title = ""

    def flush() -> None:
        nonlocal cur_buf, cur_len, cur_title
        if cur_buf:
            joined = "\n\n".join(cur_buf).strip()
            if joined:
                chunks.append((cur_title, joined))
        cur_buf = []
        cur_len = 0
        cur_title = ""

    for sec in sections:
        sec = sec.strip()
        if not sec:
            continue
        first_line = sec.splitlines()[0].strip()
        heading = first_line.lstrip("#").strip() if first_line.startswith("#") else ""
        if len(sec) > max_chunk_chars:
            flush()
            # Paragraph-level split
            paras = sec.split("\n\n")
            p_buf: list[str] = []
            p_len = 0
            for p in paras:
                if p_buf and p_len + len(p) > max_chunk_chars:
                    chunks.append((heading, "\n\n".join(p_buf).strip()))
                    p_buf = []
                    p_len = 0
                p_buf.append(p[:max_chunk_chars])
                p_len += len(p) + 2
            if p_buf:
                chunks.append((heading, "\n\n".join(p_buf).strip()))
            continue

        if cur_buf and cur_len + len(sec) > max_chunk_chars:
            flush()
        if not cur_title and heading:
            cur_title = heading
        cur_buf.append(sec)
        cur_len += len(sec) + 2

    flush()
    return chunks or [("", clean[:max_chunk_chars])]


def _parse_text_or_markdown(text: str, filename: str = "", source_label: str = "粘贴的外部记忆") -> list[dict[str, Any]]:
    clean = text.strip()
    if not clean:
        return []
    base_title = Path(filename).stem if filename else "外部 AI 记忆摘要"
    pieces = _split_long_text(clean)
    items: list[dict[str, Any]] = []
    for idx, (heading, body) in enumerate(pieces, start=1):
        if len(pieces) == 1:
            title = heading or base_title
        else:
            title = f"{base_title} · {heading or f'片段 {idx}'}"
        items.append(
            {
                "id": f"txt_{Path(filename).stem or 'paste'}_{idx}",
                "source_type": "markdown" if filename.lower().endswith(".md") else "pasted_text",
                "source_label": source_label,
                "title": title[:60],
                "date": "",
                "char_count": len(body),
                "signal_score": 92,
                "recommended": True,
                "preview": _make_preview(body),
                "content": body,
            }
        )
    return items


def _parse_json_bytes(raw_bytes: bytes, filename: str, warnings: list[str]) -> tuple[str, str, list[dict[str, Any]]]:
    try:
        data = json.loads(raw_bytes.decode("utf-8-sig"))
    except Exception as exc:
        warnings.append(f"{filename} 无法解析为有效 JSON：{exc}")
        return "unknown", "未知格式", []

    lower_name = Path(filename).name.lower()
    if lower_name == "memories.json" or (
        isinstance(data, list)
        and data
        and isinstance(data[0], dict)
        and ("conversations_memory" in data[0] or "project_memories" in data[0])
    ) or (isinstance(data, dict) and ("conversations_memory" in data or "project_memories" in data)):
        items = _parse_claude_memories(data)
        return "claude_memories", "Claude 官方记忆 (memories.json)", items

    if isinstance(data, list) and data and isinstance(data[0], dict):
        if "mapping" in data[0]:
            items = _parse_chatgpt_conversations(data)
            return "chatgpt_export", "ChatGPT 官方导出 (conversations.json)", items
        if "chat_messages" in data[0]:
            items = _parse_claude_conversations(data)
            return "claude_export", "Claude 官方导出 (conversations.json)", items

    return _parse_generic_memory_json(data, filename)


def _parse_single_file(filename: str, raw_bytes: bytes, warnings: list[str]) -> tuple[list[str], list[str], list[dict[str, Any]]]:
    sources: list[str] = []
    labels: list[str] = []
    items: list[dict[str, Any]] = []

    if len(raw_bytes) > MAX_SINGLE_FILE_BYTES:
        warnings.append(f"{filename} 体积超过 25MB，已跳过。")
        return sources, labels, items

    lower = filename.lower()
    if lower.endswith(".zip"):
        try:
            with zipfile.ZipFile(io.BytesIO(raw_bytes)) as zf:
                total_read = 0
                processed = 0
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    member_name = info.filename
                    parts = Path(member_name).parts
                    if any(p.startswith(".") or p == "__MACOSX" for p in parts):
                        continue
                    if processed >= MAX_ZIP_FILES:
                        warnings.append(f"ZIP 压缩包内文件超过 {MAX_ZIP_FILES} 个，其余已略过。")
                        break
                    if info.file_size > MAX_SINGLE_FILE_BYTES or total_read + info.file_size > MAX_ZIP_TOTAL_BYTES:
                        warnings.append(f"压缩包内文件 {member_name} 过大，已跳过。")
                        continue
                    ext = Path(member_name).suffix.lower()
                    base = Path(member_name).name.lower()
                    # Inside ChatGPT/Claude ZIPs, prioritize memories.json & conversations.json & markdown
                    if ext == ".json" and base in {"conversations.json", "memories.json"}:
                        data_bytes = zf.read(info)
                        total_read += len(data_bytes)
                        processed += 1
                        s, l, parsed = _parse_json_bytes(data_bytes, member_name, warnings)
                        if parsed:
                            sources.append(s)
                            labels.append(l)
                            items.extend(parsed)
                    elif ext in {".md", ".txt"}:
                        data_bytes = zf.read(info)
                        total_read += len(data_bytes)
                        processed += 1
                        text = data_bytes.decode("utf-8", errors="replace")
                        parsed = _parse_text_or_markdown(text, member_name, source_label="压缩包 Markdown / 文本")
                        if parsed:
                            sources.append("markdown")
                            labels.append("Markdown / 文本笔记")
                            items.extend(parsed)
                    elif ext == ".json" and base not in {"user.json", "message_feedback.json", "shared_conversations.json", "model_comparisons.json", "users.json", "projects.json"}:
                        data_bytes = zf.read(info)
                        total_read += len(data_bytes)
                        processed += 1
                        s, l, parsed = _parse_json_bytes(data_bytes, member_name, warnings)
                        if parsed:
                            sources.append(s)
                            labels.append(l)
                            items.extend(parsed)
        except zipfile.BadZipFile:
            warnings.append(f"{filename} 不是有效的 ZIP 压缩包。")
        return sources, labels, items

    if lower.endswith(".json"):
        s, l, parsed = _parse_json_bytes(raw_bytes, filename, warnings)
        if parsed:
            sources.append(s)
            labels.append(l)
            items.extend(parsed)
        return sources, labels, items

    # Markdown or plain text file
    text = raw_bytes.decode("utf-8", errors="replace").strip()
    if text:
        # Check if someone pasted JSON into a .txt file
        if text.startswith("{") or text.startswith("["):
            try:
                json.loads(text)
                s, l, parsed = _parse_json_bytes(text.encode("utf-8"), filename or "pasted.json", warnings)
                if parsed:
                    sources.append(s)
                    labels.append(l)
                    items.extend(parsed)
                    return sources, labels, items
            except Exception:
                pass
        label = "Markdown 记忆文件" if lower.endswith(".md") else "纯文本记忆文件"
        parsed = _parse_text_or_markdown(text, filename, source_label=label)
        if parsed:
            sources.append("markdown" if lower.endswith(".md") else "pasted_text")
            labels.append(label)
            items.extend(parsed)
    return sources, labels, items


def parse_import_payload(
    *,
    raw_text: str = "",
    files: list[dict[str, str]] | None = None,
    source_hint: str = "auto",
) -> dict[str, Any]:
    """Deterministically parse pasted text or uploaded files (JSON/ZIP/MD/TXT) into selectable chunks."""
    warnings: list[str] = []
    sources: list[str] = []
    labels: list[str] = []
    all_items: list[dict[str, Any]] = []

    if raw_text and raw_text.strip():
        stripped = raw_text.strip()
        parsed_as_json = False
        if stripped.startswith("{") or stripped.startswith("["):
            try:
                json.loads(stripped)
                s, l, parsed = _parse_json_bytes(stripped.encode("utf-8"), "pasted.json", warnings)
                if parsed:
                    sources.append(s)
                    labels.append(l)
                    all_items.extend(parsed)
                    parsed_as_json = True
            except Exception:
                pass
        if not parsed_as_json:
            label_map = {
                "chatgpt_paste": "ChatGPT 粘贴记忆",
                "claude_paste": "Claude 粘贴记忆",
                "prompt_paste": "外部 AI 提示词导出文本",
            }
            lbl = label_map.get(source_hint, "粘贴的外部 AI 记忆")
            parsed = _parse_text_or_markdown(stripped, "", source_label=lbl)
            sources.append("pasted_text")
            labels.append(lbl)
            all_items.extend(parsed)

    for idx, f in enumerate(files or []):
        fname = str(f.get("filename") or f"file_{idx + 1}.txt").strip()
        b64 = str(f.get("content_base64") or "").strip()
        if not b64:
            continue
        try:
            raw_bytes = base64.b64decode(b64)
        except Exception:
            warnings.append(f"{fname} 编码解析失败，已跳过。")
            continue
        s_list, l_list, parsed = _parse_single_file(fname, raw_bytes, warnings)
        sources.extend(s_list)
        labels.extend(l_list)
        all_items.extend(parsed)

    # Deduplicate IDs and sort: recommended + higher signal + newer date first
    all_items.sort(
        key=lambda x: (
            1 if x["recommended"] else 0,
            int(x["signal_score"]),
            str(x["date"]),
            int(x["char_count"]),
        ),
        reverse=True,
    )

    total_before_cap = len(all_items)
    if total_before_cap > MAX_PREVIEW_ITEMS:
        warnings.append(f"共解析出 {total_before_cap} 条片段，已按个人相关性精选展示前 {MAX_PREVIEW_ITEMS} 条。")
        all_items = all_items[:MAX_PREVIEW_ITEMS]

    selected_chars = 0
    recommended_count = 0
    has_private_tags = False
    for idx, item in enumerate(all_items, start=1):
        item["id"] = f"imp_{idx}"
        if "<private>" in item["content"].lower():
            has_private_tags = True
        if item["recommended"]:
            recommended_count += 1
        # Auto-select recommended items up to context budget (always keep at least 1 item selected)
        if item["recommended"] and (selected_chars + item["char_count"] <= DEFAULT_SELECT_CHAR_BUDGET or selected_chars == 0):
            item["selected"] = True
            selected_chars += item["char_count"]
        else:
            item["selected"] = False

    if all_items and selected_chars == 0:
        all_items[0]["selected"] = True
        selected_chars = all_items[0]["char_count"]

    if has_private_tags:
        warnings.append("检测到 <private> 标签内容，提炼发往大模型前会自动在本地脱敏替换。")

    unique_labels = list(dict.fromkeys(labels))
    detected_source = sources[0] if len(set(sources)) == 1 else ("mixed" if sources else "empty")
    detected_label = " + ".join(unique_labels[:2]) if unique_labels else "未识别到有效内容"

    total_chars = sum(i["char_count"] for i in all_items)
    selected_count = sum(1 for i in all_items if i["selected"])
    skipped_low_signal = len(all_items) - recommended_count

    if not all_items:
        summary = "未解析出可导入的记忆片段，请检查粘贴文本或上传文件格式。"
    elif skipped_low_signal > 0:
        summary = (
            f"识别为「{detected_label}」：共解析 {total_before_cap} 条，自动精选 {recommended_count} 条高个人相关性片段"
            f"（默认勾选 {selected_count} 条，跳过 {skipped_low_signal} 条疑似纯代码/工具问答）。"
        )
    else:
        summary = f"识别为「{detected_label}」：共解析 {len(all_items)} 条片段，默认勾选 {selected_count} 条（约 {selected_chars} 字）。"

    return {
        "detected_source": detected_source,
        "detected_label": detected_label,
        "summary": summary,
        "total_items": total_before_cap,
        "shown_items": len(all_items),
        "recommended_items": recommended_count,
        "selected_items": selected_count,
        "total_chars": total_chars,
        "selected_chars": selected_chars,
        "warnings": warnings,
        "items": all_items,
    }


def batch_import_chunks(
    items: list[dict[str, Any]],
    *,
    max_batch_chars: int = 16000,
    max_batches: int = 3,
) -> list[str]:
    """Pack selected import items into sanitized text batches suitable for LLM extraction."""
    batches: list[str] = []
    cur_parts: list[str] = []
    cur_len = 0

    for item in items:
        title = str(item.get("title") or "外部记忆片段").strip()
        src = str(item.get("source_label") or item.get("source_type") or "外部 Agent").strip()
        dt = str(item.get("date") or "").strip()
        raw_content = strip_private_blocks(str(item.get("content") or "").strip())
        if not raw_content:
            continue
        header = f"=== [{src}] {title}" + (f" ({dt})" if dt else "") + " ==="
        block = f"{header}\n{raw_content[:7500]}"
        if cur_parts and cur_len + len(block) > max_batch_chars:
            batches.append("\n\n".join(cur_parts))
            if len(batches) >= max_batches:
                return batches
            cur_parts = []
            cur_len = 0
        cur_parts.append(block)
        cur_len += len(block) + 2

    if cur_parts and len(batches) < max_batches:
        batches.append("\n\n".join(cur_parts))
    return batches
