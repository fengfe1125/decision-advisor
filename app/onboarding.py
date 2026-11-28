from __future__ import annotations

import re
from datetime import datetime
from typing import Any

from .db import get_meta, set_meta
from .memory_store import MemoryStore, strip_private_blocks

CORE_SLOTS: list[dict[str, str]] = [
    {
        "id": "identity",
        "path": "00-核心自我/identity.md",
        "title": "我是谁与当下阶段",
        "description": "称呼、职业或角色、当前所处的人生阶段与生活重心",
        "interview_prompt": "先聊聊我希望怎么称呼你，以及你现在正处在怎样的人生阶段、最近生活重心是什么？",
    },
    {
        "id": "values",
        "path": "00-核心自我/values.md",
        "title": "核心价值观",
        "description": "做重要取舍时的第一优先级与绝不妥协的原则",
        "interview_prompt": "如果只保留 3 个你做人生重要选择时绝不愿妥协的价值排序，会是哪几个？",
    },
    {
        "id": "boundaries",
        "path": "00-核心自我/boundaries.md",
        "title": "红线与底线",
        "description": "明确拒绝的事情、不可触碰的边界与长期消耗源",
        "interview_prompt": "有哪些事一旦踩线就会让你极度内耗或事后后悔？你给自己划过哪些明确底线？",
    },
    {
        "id": "patterns",
        "path": "00-核心自我/patterns.md",
        "title": "情绪与决策模式",
        "description": "高压/犹豫时的典型反应、容易陷入的思维惯性与充能方式",
        "interview_prompt": "回想最近一次让你犹豫或压力很大的瞬间，你通常会怎么反应？什么事最容易耗干你，又是什么能帮你充能？",
    },
    {
        "id": "goals",
        "path": "00-核心自我/goals.md",
        "title": "当下课题与目标",
        "description": "未来 6～12 个月最想推进的目标或正在权衡的核心选择",
        "interview_prompt": "接下来半年到一年，你最想做成的一件事，或者目前最想理清的一个重要课题是什么？",
    },
]

CORE_SLOT_BY_ID: dict[str, dict[str, str]] = {s["id"]: s for s in CORE_SLOTS}

ADVISOR_STYLES: dict[str, dict[str, str]] = {
    "direct_critic": {
        "label": "直率泼冷水",
        "description": "少客套，直接指出盲区、自欺与隐性代价，给我清醒的反方视角。",
    },
    "balanced": {
        "label": "理性均衡",
        "description": "先接住真实感受，再冷静拆解事实、利弊与反方观点，保持克制清醒。",
    },
    "warm_gentle": {
        "label": "温和陪伴",
        "description": "语气更温和细腻、循序渐进，在尊重情绪节奏的前提下温和提醒风险。",
    },
}

_PLACEHOLDER_PATTERNS = [
    r"待补充",
    r"待完善",
    r"暂空",
    r"未填写",
    r"请在此(?:填写|补充|记录)",
    r"\bTODO\b",
    r"\bTBD\b",
    r"（空）",
    r"\(空\)",
    r"暂无内容",
    r"尚未填写",
]
_PLACEHOLDER_RE = re.compile("|".join(_PLACEHOLDER_PATTERNS), re.IGNORECASE)


def _meaningful_body_text(body: str) -> str:
    lines: list[str] = []
    for raw_line in body.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("#") or line.startswith("<!--") or line in {"---", "***", "___"}:
            continue
        # Strip leading list/quote markers
        cleaned = re.sub(r"^(?:[-*+>]|\d+[.)])\s*", "", line).strip()
        # Strip common template key prefixes with empty values like "称呼：" or "- 职业："
        if re.fullmatch(r"[^：:]{1,14}[：:]\s*", cleaned):
            continue
        cleaned = _PLACEHOLDER_RE.sub("", cleaned)
        cleaned = re.sub(r"[\[\]（）()「」『』_*\-`·•:：\s]", "", cleaned)
        if cleaned:
            lines.append(cleaned)
    return "".join(lines)


def _make_safe_excerpt(body: str, privacy: str) -> str:
    if privacy == "sensitive":
        return "（已填写 · 标记为 sensitive，受本地隐私保护）"
    safe = strip_private_blocks(body)
    lines: list[str] = []
    for raw_line in safe.splitlines():
        s = raw_line.strip()
        if not s or s.startswith("#") or s in {"---", "***"}:
            continue
        if _PLACEHOLDER_RE.fullmatch(re.sub(r"[-*+\s（）()\[\]]", "", s)):
            continue
        lines.append(s)
        if sum(len(x) for x in lines) >= 100:
            break
    joined = " ".join(lines).strip()
    return (joined[:96] + "…") if len(joined) > 96 else joined


def evaluate_onboarding_status(store: MemoryStore) -> dict[str, Any]:
    """Inspect 00-核心自我 core slots and vault readiness to drive onboarding & slot-aware interview."""
    slots_out: list[dict[str, Any]] = []
    score_sum = 0.0
    ready_count = 0
    partial_count = 0
    empty_count = 0

    for spec in CORE_SLOTS:
        full_path = store.vault_path / spec["path"]
        exists = full_path.exists()
        status = "empty"
        char_count = 0
        excerpt = ""
        if exists:
            try:
                doc = store.read_doc(spec["path"])
                meaningful = _meaningful_body_text(doc.body)
                char_count = len(meaningful)
                if char_count >= 24:
                    status = "ready"
                    score_sum += 1.0
                    ready_count += 1
                elif char_count >= 8:
                    status = "partial"
                    score_sum += 0.5
                    partial_count += 1
                else:
                    status = "empty"
                    empty_count += 1
                if status != "empty":
                    excerpt = _make_safe_excerpt(doc.body, doc.privacy)
            except Exception:
                status = "empty"
                empty_count += 1
        else:
            empty_count += 1

        slots_out.append(
            {
                "id": spec["id"],
                "path": spec["path"],
                "title": spec["title"],
                "description": spec["description"],
                "interview_prompt": spec["interview_prompt"],
                "exists": exists,
                "status": status,
                "char_count": char_count,
                "excerpt": excerpt,
            }
        )

    completeness = int(round((score_sum / len(CORE_SLOTS)) * 100)) if CORE_SLOTS else 0

    all_docs = store.scan_all(include_system=False)
    non_core_memories = 0
    for d in all_docs:
        if d.category == "00-核心自我":
            continue
        if d.rel_path == "99-收件箱/inbox.md" and len(_meaningful_body_text(d.body)) < 10:
            continue
        non_core_memories += 1

    has_protocol = (store.vault_path / "_系统协议" / "顾问人格与工作协议.md").exists()
    meta_state = get_meta("onboarding_state", "")
    dismissed = meta_state == "dismissed"
    explicitly_completed = meta_state == "completed"
    completed = explicitly_completed or completeness >= 60

    missing_slots = [s["id"] for s in slots_out if s["status"] == "empty"]
    partial_slots = [s["id"] for s in slots_out if s["status"] == "partial"]
    next_slot_id = missing_slots[0] if missing_slots else (partial_slots[0] if partial_slots else CORE_SLOTS[0]["id"])

    # Auto-trigger onboarding only when core self is largely empty AND user hasn't dismissed/completed it
    needs_onboarding = (not dismissed) and (not completed) and completeness < 40

    return {
        "needs_onboarding": needs_onboarding,
        "completed": completed,
        "dismissed": dismissed,
        "onboarding_state": meta_state,
        "completeness": completeness,
        "ready_count": ready_count,
        "partial_count": partial_count,
        "empty_count": empty_count,
        "total_slots": len(CORE_SLOTS),
        "non_core_memories": non_core_memories,
        "has_protocol": has_protocol,
        "missing_slots": missing_slots,
        "partial_slots": partial_slots,
        "next_slot_id": next_slot_id,
        "slots": slots_out,
    }


def set_onboarding_state(state: str) -> None:
    if state not in {"completed", "dismissed", ""}:
        raise ValueError("非法的 onboarding 状态")
    set_meta("onboarding_state", state)


def build_interview_slot_guidance(store: MemoryStore, focus_slot: str | None = None) -> str:
    """Build dynamic slot-awareness section injected into interview mode system prompt."""
    status = evaluate_onboarding_status(store)
    lines = [
        f"【当前核心自我档案体检（完整度 {status['completeness']}% · {status['ready_count']}/{status['total_slots']} 项已充实）】"
    ]
    badge_map = {"ready": "✅ 已建立", "partial": "🟡 待充实", "empty": "⬜ 空白（优先了解）"}
    for slot in status["slots"]:
        tag = badge_map.get(slot["status"], "⬜ 空白")
        lines.append(f"- {tag} `{slot['path']}`（{slot['title']}）：{slot['description']}")

    if focus_slot and focus_slot in CORE_SLOT_BY_ID:
        target = CORE_SLOT_BY_ID[focus_slot]
        lines.append(
            f"\n本轮用户希望优先聊聊「{target['title']}」（`{target['path']}`），请先围绕这一维度温和切入。"
        )
    elif status["missing_slots"]:
        first = CORE_SLOT_BY_ID[status["missing_slots"][0]]
        lines.append(
            f"\n建议本轮优先从第一个空白项「{first['title']}」（`{first['path']}`）切入，切记每次只问 1～2 个有画面感的小问题。"
        )
    elif status["partial_slots"]:
        first = CORE_SLOT_BY_ID[status["partial_slots"][0]]
        lines.append(
            f"\n核心骨架已初具雏形，建议继续温和深化「{first['title']}」（`{first['path']}`）或顺着聊一段深刻的人生经历。"
        )
    else:
        lines.append("\n核心自我 5 项已基本建立，本轮可以聊聊重要人生章节、关键人物或最近让你触动的一件事。")

    return "\n".join(lines)


def build_interview_opening_fallback(status: dict[str, Any], focus_slot: str | None = None) -> str:
    """Warm deterministic opening message when LLM is unavailable or unconfigured."""
    if focus_slot and focus_slot in CORE_SLOT_BY_ID:
        slot = CORE_SLOT_BY_ID[focus_slot]
        return (
            f"你好，我们这一轮先轻松聊聊你的「**{slot['title']}**」，不用写得很正式，想到什么说什么就好。\n\n"
            f"1. {slot['interview_prompt']}\n"
            f"2. 如果用一件最近或印象很深的小事来举例，你会想到哪一件事？"
        )

    missing = status.get("missing_slots") or []
    if len(missing) >= 4:
        return (
            "你好，我是你的个人成长决策顾问。为了以后能在你面临选择时真正结合你的经历和底线来思考，我们先用几轮轻松的聊天互相认识一下——不用一次说完，想到哪聊到哪就好。\n\n"
            "先从两个很轻松的问题开始：\n"
            "1. 你希望我平时怎么称呼你？现在的你正处在怎样的人生或工作阶段？\n"
            "2. 最近这一阵子，脑海里最常反复冒出来的那件事（或者最让你纠结的一个课题）是什么？"
        )

    target_id = missing[0] if missing else status.get("next_slot_id", "identity")
    slot = CORE_SLOT_BY_ID.get(target_id, CORE_SLOTS[0])
    return (
        f"欢迎回来！我看到你的核心自我档案已经完成了 {status.get('completeness', 0)}%，"
        f"这一轮我们顺着把「**{slot['title']}**」再补实一点吧。\n\n"
        f"- {slot['interview_prompt']}"
    )


def _merge_or_create_core_doc(
    store: MemoryStore,
    rel_path: str,
    title: str,
    new_sections_md: str,
    *,
    today: str,
) -> tuple[str, str, bool]:
    """Return (action, full_markdown, existed_before). Non-destructively appends when file already has real content."""
    full_path = store.resolve_safe_path(rel_path)
    existed = full_path.exists()
    if existed:
        try:
            doc = store.read_doc(rel_path)
            if len(_meaningful_body_text(doc.body)) >= 8:
                existing_raw = doc.raw.rstrip()
                merged = f"{existing_raw}\n\n---\n\n## 引导建档补充（{today}）\n\n{new_sections_md.strip()}\n"
                return "update", merged, True
        except Exception:
            pass

    content = (
        f"---\n"
        f"title: {title}\n"
        f"recorded_at: {today}\n"
        f"updated_at: {today}\n"
        f"importance: 9\n"
        f"privacy: private\n"
        f"source: onboarding\n"
        f"---\n\n"
        f"# {title}\n\n"
        f"{new_sections_md.strip()}\n"
    )
    return ("update" if existed else "create"), content, existed


def build_quick_profile_proposals(store: MemoryStore, payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Convert the 3-minute onboarding wizard form into structured core-self Markdown proposals with diffs."""
    today = datetime.now().strftime("%Y-%m-%d")

    preferred_name = str(payload.get("preferred_name") or "").strip()
    life_stage = str(payload.get("life_stage") or "").strip()
    current_focus = str(payload.get("current_focus") or "").strip()
    core_values = [str(v).strip() for v in (payload.get("core_values") or []) if str(v).strip()]
    values_note = str(payload.get("values_note") or "").strip()
    boundaries = str(payload.get("boundaries") or "").strip()
    patterns = str(payload.get("patterns") or "").strip()
    goals = str(payload.get("goals") or "").strip()
    advisor_style = str(payload.get("advisor_style") or "").strip()
    advisor_style_note = str(payload.get("advisor_style_note") or "").strip()

    proposals: list[dict[str, Any]] = []

    def add_doc(slot_id: str, title: str, summary: str, sections_md: str) -> None:
        spec = CORE_SLOT_BY_ID[slot_id]
        rel_path = spec["path"]
        action, content, existed = _merge_or_create_core_doc(store, rel_path, title, sections_md, today=today)
        diff = store.compute_diff(rel_path, content, action="update") if existed else ""
        proposals.append(
            {
                "id": f"onboard_{slot_id}",
                "action": action,
                "path": rel_path,
                "exists": existed,
                "level": 3,
                "title": title,
                "summary": summary,
                "importance": 9,
                "emotions": [],
                "relations": [],
                "privacy": "private",
                "evidence": "来自「认识我」3 分钟初始化引导建档",
                "content": content,
                "diff": diff,
            }
        )

    # 1. Identity & Advisor Communication Preference
    id_parts: list[str] = []
    if preferred_name or life_stage or current_focus:
        id_parts.append("## 基本画像与当下阶段")
        if preferred_name:
            id_parts.append(f"- **希望被称呼**：{preferred_name}")
        if life_stage:
            id_parts.append(f"- **当前职业 / 人生阶段**：{life_stage}")
        if current_focus:
            id_parts.append(f"- **当下核心重心**：{current_focus}")
    if advisor_style or advisor_style_note:
        style_meta = ADVISOR_STYLES.get(advisor_style, {})
        id_parts.append("\n## 期望的顾问沟通风格")
        if style_meta:
            id_parts.append(f"- **偏好模式**：{style_meta['label']}（{style_meta['description']}）")
        elif advisor_style:
            id_parts.append(f"- **偏好模式**：{advisor_style}")
        if advisor_style_note:
            id_parts.append(f"- **补充要求**：{advisor_style_note}")

    if id_parts:
        add_doc(
            "identity",
            "核心身份与沟通偏好",
            "记录你的称呼、当前所处人生阶段，以及希望顾问与你沟通的风格。",
            "\n".join(id_parts),
        )

    # 2. Core Values
    if core_values or values_note:
        val_parts = ["## 重要取舍时的核心价值排序"]
        for idx, v in enumerate(core_values, start=1):
            val_parts.append(f"{idx}. **{v}**")
        if values_note:
            val_parts.append(f"\n## 自我补充说明\n{values_note}")
        add_doc(
            "values",
            "核心价值观",
            f"记录你最看重的价值优先级（{'、'.join(core_values[:4]) if core_values else '自定义补充'}）。",
            "\n".join(val_parts),
        )

    # 3. Boundaries
    if boundaries:
        add_doc(
            "boundaries",
            "原则、红线与底线",
            "记录你明确拒绝的红线与长期消耗你的边界条件，供 9 步决策做价值观体检。",
            f"## 明确拒绝与不可触碰的底线\n{boundaries}",
        )

    # 4. Emotional & Decision Patterns
    if patterns:
        add_doc(
            "patterns",
            "情绪与决策模式",
            "记录你在压力、犹豫下的典型反应惯性与充能/消耗来源。",
            f"## 典型反应惯性与能量模式\n{patterns}",
        )

    # 5. Current Goals
    if goals:
        add_doc(
            "goals",
            "当下课题与阶段目标",
            "记录未来 6～12 个月最想推进的目标或正在权衡的核心选择。",
            f"## 未来 6～12 个月重点课题\n{goals}",
        )

    return proposals
