from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Any

from .memory_store import MemoryDoc, MemoryStore

MODE_INSTRUCTIONS: dict[str, str] = {
    "chat": (
        "【当前激活模式：💬 日常倾诉与情绪陪伴】\n"
        "- 优先倾听、共情、帮我理清思绪与真实感受，不急于说教；\n"
        "- 若联想到我过往的真实经历或情绪模式，自然引用 [[路径]] 帮我看见规律；\n"
        "- 话题自然展开后，如有值得沉淀的经历或情绪，可在结尾轻声提示我点击「✨ 提炼记忆提案」做半自动确认入库。"
    ),
    "decision": (
        "【当前激活模式：🧭 9 步反讨好决策顾问】\n"
        "严格按协议中的 9 步决策流程输出：\n"
        "1) 问题重述与判断标准；2) 结合 00-核心自我 价值观/底线/模式；3) 引用高显著历史经历；\n"
        "4) 回溯同类历史决策；5) 至少 3 个选项（必含「暂缓/不做决定」与「低成本小步试错」）；\n"
        "6) 价值观体检与红线/情绪干扰警告；\n"
        "7) 强制反方（Critic）：至少引用 1 条过往失败/后悔/消耗经历（无记录则明确声明）、提出 1 个反对我当前倾向的强论点、明确区分「事实 / 推断 / 价值判断」；\n"
        "8) 排序建议 + [[文件]] 证据引用 + 不确定性 + 1 周内最小验证动作；\n"
        "9) 提示我点击「✨ 提炼记忆提案」将本次推演半自动建档至 04-决策实验室/进行中/。"
    ),
    "interview": (
        "【当前激活模式：🎙️ 冷启动深度访谈】\n"
        "- 每次只问 1～2 个温和、具体、有画面感的问题，绝不一次丢一长串问卷；\n"
        "- 先检查 00-核心自我/ 里哪些还是“待补充”，优先从最有温度的切口聊起（成长转折 / 印象最深的事 / 核心底线 / 重要的人 / 当下课题）；\n"
        "- 每次聊出足够素材后，提醒我可以点「✨ 提炼记忆提案」把聊出来的内容半自动写入核心档案和经历库。"
    ),
    "reflect": (
        "【当前激活模式：🔍 周期反思与收件箱整理】\n"
        "- 结合收件箱（99-收件箱/inbox.md）和近期经历，帮我提炼高频情绪、触发因素、能量充能/消耗来源、新旧观点变化；\n"
        "- 指出哪些内容值得归档为正式事件、哪些值得更新进 00-核心自我/ 或追加到 05-认知演进与反思/观点演变日志.md。"
    ),
}


def build_chat_system_prompt(
    store: MemoryStore,
    mode: str,
    core_docs: list[MemoryDoc],
    retrieved_docs: list[MemoryDoc],
    allow_sensitive: bool = False,
) -> str:
    today = datetime.now().strftime("%Y-%m-%d")
    protocol = store.read_protocol_prompt()
    mode_block = MODE_INSTRUCTIONS.get(mode, MODE_INSTRUCTIONS["chat"])

    sections = [
        f"当前日期：{today}",
        protocol,
        "---",
        mode_block,
        "---",
        "## 一、我的核心自我档案（00-核心自我，全量常驻记忆）",
    ]
    if core_docs:
        for doc in core_docs:
            sanitized = store.sanitize_for_llm(doc, allow_sensitive=allow_sensitive)
            sections.append(f"### [[{doc.rel_path}]]（{doc.title}）\n{sanitized[:2500]}")
    else:
        sections.append("（核心自我档案暂为空，可温和引导用户通过冷启动访谈逐步建立。）")

    sections.append("## 二、本次按相关性与显著性召回的历史记忆")
    if retrieved_docs:
        for doc in retrieved_docs:
            sanitized = store.sanitize_for_llm(doc, allow_sensitive=allow_sensitive)
            sections.append(
                f"### [[{doc.rel_path}]]（{doc.category_label} | 发生时间:{doc.event_time or '未知'} | 显著性:{doc.importance}/10）\n"
                f"{sanitized[:2200]}"
            )
    else:
        sections.append("（记忆库中暂未检索到历史事件，请诚实告知暂无历史证据，严禁编造。）")

    return "\n\n".join(sections)


def build_extraction_prompts(
    store: MemoryStore,
    messages: list[dict[str, str]],
    existing_paths: list[str],
    allow_sensitive: bool = False,
) -> tuple[str, list[dict[str, str]]]:
    today = datetime.now().strftime("%Y-%m-%d")
    core_docs = store.load_core_self(allow_sensitive=allow_sensitive)
    core_preview = "\n\n".join(
        f"### {d.rel_path}\n{store.sanitize_for_llm(d, allow_sensitive=allow_sensitive)[:1200]}"
        for d in core_docs
    )

    system_prompt = f"""你是个人成长记忆库的「结构化记忆整理引擎」。当前日期是 {today}。
你的任务是阅读用户的最近对话，提炼出**真正值得长期保存的记忆变更提案**（供用户半自动审核确认后写入 Markdown 文件）。

严格遵守以下规则：
1. 只提取有实质价值的经历、真实情绪感受、重要人物、人生章节、重大决策推演或核心认知变化；闲聊废话不要硬凑提案（如果没有值得保存的内容，返回空数组 `[]`）。
2. 目标路径规范（必须使用相对路径，以 `.md` 结尾）：
   - 经历与感受：`02-经历与感受/{today[:4]}/YYYY-MM-DD-简短标题.md`（若记录多年前的事，年份目录与前缀用事件发生年份，并填准 `event_time` 与 `recorded_at: {today}`）
   - 重要人物：`03-重要关系/人物称呼.md`
   - 人生章节：`01-人生章节/YYYY-YYYY-章节名.md`
   - 进行中决策：`04-决策实验室/进行中/{today}-决策简称.md`
   - 核心自我更新：`00-核心自我/identity.md` / `values.md` / `patterns.md` / `boundaries.md` / `goals.md`（action 用 `"update"`，保留原有用内容并在相应小节融合更新，不抹除历史）
   - 观点演变：`05-认知演进与反思/观点演变日志.md`（action 用 `"append"`）
3. 情绪必须是一等公民：凡是 `02-经历与感受/` 文档，YAML Frontmatter 必须包含 `id`、`title`、`event_time`、`recorded_at`、`type`、`importance`（1-10）、`people`、`emotions`（数组，含 `name`、`intensity`、`valence`、`trigger`、`body`、`thought`）、`privacy`（默认 `"private"`）、`source: chat`，正文必须包含 `## 发生了什么`、`## 我当时怎么想 & 什么感受`、`## 现在回看`、`## 关键观察 (Observations)`（带 `- [感受]` 等标签）和 `## 关联记忆 (Relations)`（带 `[[双链]]`）。
4. 仅输出**纯 JSON**，不要包裹多余解释文字，格式如下：
{{
  "proposals": [
    {{
      "action": "create",
      "path": "02-经历与感受/2026/2026-11-21-示例.md",
      "title": "简短清晰标题",
      "summary": "2-3行精简说明：记录什么事、核心情绪是什么、为什么值得存入记忆库",
      "importance": 8,
      "emotions": ["焦虑", "释然"],
      "relations": ["00-核心自我/values"],
      "privacy": "private",
      "evidence": "触发本条记录的用户原话要点",
      "content": "完整规范的 Markdown 内容（含 YAML frontmatter）"
    }}
  ]
}}

当前已有文件列表（供双链引用或决定 update/append）：
{chr(10).join('- ' + p for p in existing_paths[:80])}

当前核心自我文件内容参考：
{core_preview}
"""

    convo_text = "\n\n".join(
        f"【{'我' if m.get('role') == 'user' else '顾问'}】：{m.get('content', '')}"
        for m in messages[-16:]
    )
    user_messages = [
        {
            "role": "user",
            "content": f"请从下面这段对话中提炼值得保存的记忆提案，并严格返回 JSON：\n\n{convo_text}",
        }
    ]
    return system_prompt, user_messages


def parse_proposals_json(raw_text: str) -> list[dict[str, Any]]:
    cleaned = raw_text.strip()
    fence_match = re.search(r"```(?:json)?\s*(\{.*?\}|\[.*?\])\s*```", cleaned, re.DOTALL)
    if fence_match:
        cleaned = fence_match.group(1)
    else:
        start_obj = cleaned.find("{")
        start_arr = cleaned.find("[")
        starts = [i for i in (start_obj, start_arr) if i != -1]
        if starts:
            cleaned = cleaned[min(starts) :]
            end_obj = cleaned.rfind("}")
            end_arr = cleaned.rfind("]")
            end = max(end_obj, end_arr)
            if end != -1:
                cleaned = cleaned[: end + 1]

    data = json.loads(cleaned)
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    if isinstance(data, dict) and isinstance(data.get("proposals"), list):
        return [item for item in data["proposals"] if isinstance(item, dict)]
    return []
