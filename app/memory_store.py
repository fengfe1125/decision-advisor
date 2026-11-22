from __future__ import annotations

import difflib
import io
import re
import zipfile
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

import yaml

PRIVATE_BLOCK_RE = re.compile(r"<private>.*?</private>", re.DOTALL | re.IGNORECASE)
WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")
FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", re.DOTALL)

CATEGORY_ORDER = [
    ("00-核心自我", "核心自我"),
    ("01-人生章节", "人生章节"),
    ("02-经历与感受", "经历与感受"),
    ("03-重要关系", "重要关系"),
    ("04-决策实验室", "决策实验室"),
    ("05-认知演进与反思", "认知演进"),
    ("99-收件箱", "收件箱"),
    ("_系统协议", "系统协议"),
]

CORE_DIRS = {"00-核心自我", "01-人生章节", "05-认知演进与反思"}
SYSTEM_PREFIX = "_系统协议"


@dataclass
class MemoryDoc:
    rel_path: str
    title: str
    category: str
    category_label: str
    privacy: str
    importance: int
    event_time: str
    recorded_at: str
    emotions: list[dict[str, Any]] = field(default_factory=list)
    people: list[str] = field(default_factory=list)
    wikilinks: list[str] = field(default_factory=list)
    frontmatter: dict[str, Any] = field(default_factory=dict)
    body: str = ""
    raw: str = ""
    mtime: float = 0.0

    def to_summary(self) -> dict[str, Any]:
        emotion_names = []
        for em in self.emotions:
            if isinstance(em, dict) and em.get("name"):
                emotion_names.append(str(em["name"]))
            elif isinstance(em, str):
                emotion_names.append(em)
        snippet = re.sub(r"\s+", " ", self.body.strip())[:140]
        return {
            "path": self.rel_path,
            "title": self.title,
            "category": self.category,
            "category_label": self.category_label,
            "privacy": self.privacy,
            "importance": self.importance,
            "event_time": self.event_time,
            "recorded_at": self.recorded_at,
            "emotions": emotion_names,
            "people": self.people,
            "wikilinks": self.wikilinks,
            "snippet": snippet,
            "updated_ts": self.mtime,
        }


def strip_private_blocks(text: str) -> str:
    return PRIVATE_BLOCK_RE.sub("[已根据本地隐私规则隐藏]", text)


def parse_markdown_doc(raw: str) -> tuple[dict[str, Any], str]:
    match = FRONTMATTER_RE.match(raw)
    if not match:
        return {}, raw
    fm_text, body = match.group(1), match.group(2)
    try:
        parsed = yaml.safe_load(fm_text)
        if not isinstance(parsed, dict):
            parsed = {}
    except Exception:
        parsed = {}
    return parsed, body


def _infer_category(rel_path: str) -> tuple[str, str]:
    top = rel_path.split("/", 1)[0]
    for prefix, label in CATEGORY_ORDER:
        if top == prefix:
            return prefix, label
    return "root", "根目录"


def _extract_title(frontmatter: dict[str, Any], body: str, rel_path: str) -> str:
    if frontmatter.get("title"):
        return str(frontmatter["title"])
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("# "):
            return s[2:].strip()
    return Path(rel_path).stem


def _safe_int(value: Any, default: int = 5) -> int:
    try:
        return max(1, min(10, int(value)))
    except Exception:
        return default


def _stringify_date(value: Any) -> str:
    if value is None:
        return ""
    if hasattr(value, "isoformat"):
        return value.isoformat()[:10]
    return str(value)[:10]


def _tokenize(text: str) -> set[str]:
    text = text.lower()
    tokens: set[str] = set()
    for word in re.findall(r"[a-z0-9_]{2,}", text):
        tokens.add(word)
    # Chinese character bigrams + single chars for robust zero-dependency CJK matching
    cjk_runs = re.findall(r"[\u4e00-\u9fff]+", text)
    for run in cjk_runs:
        if len(run) == 1:
            tokens.add(run)
        else:
            for i in range(len(run) - 1):
                tokens.add(run[i : i + 2])
            if len(run) <= 4:
                tokens.add(run)
    return tokens


class MemoryStore:
    def __init__(self, vault_path: str | Path):
        self.vault_path = Path(vault_path).expanduser().resolve()

    def resolve_safe_path(self, rel_path: str) -> Path:
        cleaned = rel_path.strip().lstrip("/").replace("\\", "/")
        if not cleaned or ".." in Path(cleaned).parts:
            raise ValueError("非法的记忆文件路径")
        if not cleaned.endswith(".md"):
            cleaned += ".md"
        candidate = (self.vault_path / cleaned).resolve()
        if self.vault_path != candidate and self.vault_path not in candidate.parents:
            raise ValueError("路径超出记忆库安全边界")
        for part in candidate.relative_to(self.vault_path).parts:
            if part.startswith("."):
                raise ValueError("禁止访问隐藏目录或隐藏文件")
        return candidate

    def scan_all(self, include_system: bool = False) -> list[MemoryDoc]:
        if not self.vault_path.exists():
            return []
        docs: list[MemoryDoc] = []
        for path in sorted(self.vault_path.rglob("*.md")):
            rel = path.relative_to(self.vault_path).as_posix()
            if any(part.startswith(".") for part in path.relative_to(self.vault_path).parts):
                continue
            if not include_system and (rel.startswith(f"{SYSTEM_PREFIX}/") or rel in {"CLAUDE.md", "AGENTS.md", "README.md"}):
                continue
            doc = self._load_file(path, rel)
            if doc:
                docs.append(doc)
        return docs

    def _load_file(self, full_path: Path, rel_path: str) -> MemoryDoc | None:
        try:
            raw = full_path.read_text(encoding="utf-8")
            stat = full_path.stat()
        except Exception:
            return None
        fm, body = parse_markdown_doc(raw)
        cat, label = _infer_category(rel_path)
        title = _extract_title(fm, body, rel_path)
        privacy = str(fm.get("privacy", "private")).lower().strip()
        if privacy not in {"public", "normal", "private", "sensitive"}:
            privacy = "private"
        importance = _safe_int(fm.get("importance"), default=7 if cat == "00-核心自我" else 5)
        event_time = _stringify_date(fm.get("event_time") or fm.get("date") or fm.get("period") or fm.get("updated_at"))
        recorded_at = _stringify_date(fm.get("recorded_at") or fm.get("updated_at"))
        raw_emotions = fm.get("emotions") or []
        if isinstance(raw_emotions, str):
            raw_emotions = [{"name": raw_emotions}]
        elif not isinstance(raw_emotions, list):
            raw_emotions = []
        raw_people = fm.get("people") or fm.get("key_people") or []
        if isinstance(raw_people, str):
            raw_people = [raw_people]
        people = [str(p) for p in raw_people if p]
        wikilinks = [m.strip() for m in WIKILINK_RE.findall(body)]
        return MemoryDoc(
            rel_path=rel_path,
            title=title,
            category=cat,
            category_label=label,
            privacy=privacy,
            importance=importance,
            event_time=event_time,
            recorded_at=recorded_at,
            emotions=raw_emotions,
            people=people,
            wikilinks=wikilinks,
            frontmatter=fm,
            body=body,
            raw=raw,
            mtime=stat.st_mtime,
        )

    def read_doc(self, rel_path: str) -> MemoryDoc:
        full_path = self.resolve_safe_path(rel_path)
        if not full_path.exists():
            raise FileNotFoundError(f"记忆不存在: {rel_path}")
        actual_rel = full_path.relative_to(self.vault_path).as_posix()
        doc = self._load_file(full_path, actual_rel)
        if not doc:
            raise RuntimeError(f"无法读取记忆: {rel_path}")
        return doc

    def write_doc(self, rel_path: str, content: str, action: str = "update") -> str:
        full_path = self.resolve_safe_path(rel_path)
        full_path.parent.mkdir(parents=True, exist_ok=True)
        if action == "append" and full_path.exists():
            existing = full_path.read_text(encoding="utf-8")
            sep = "\n\n" if existing and not existing.endswith("\n\n") else ""
            final_text = f"{existing}{sep}{content.strip()}\n"
        else:
            final_text = content if content.endswith("\n") else content + "\n"
        full_path.write_text(final_text, encoding="utf-8")
        return full_path.relative_to(self.vault_path).as_posix()

    def delete_doc(self, rel_path: str) -> str:
        full_path = self.resolve_safe_path(rel_path)
        if not full_path.exists():
            raise FileNotFoundError(f"记忆不存在: {rel_path}")
        actual_rel = full_path.relative_to(self.vault_path).as_posix()
        full_path.unlink()
        return actual_rel

    def export_vault_zip_bytes(self) -> bytes:
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            if self.vault_path.exists():
                for path in sorted(self.vault_path.rglob("*.md")):
                    rel = path.relative_to(self.vault_path)
                    if any(part.startswith(".") for part in rel.parts):
                        continue
                    zf.write(path, arcname=rel.as_posix())
        return buf.getvalue()

    def append_inbox(self, text: str, mood: str = "") -> str:
        now = datetime.now().strftime("%Y-%m-%d %H:%M")
        mood_tag = f" `[情绪: {mood.strip()}]`" if mood.strip() else ""
        entry = f"### {now}{mood_tag}\n{text.strip()}"
        return self.write_doc("99-收件箱/inbox.md", entry, action="append")

    def compute_diff(self, rel_path: str, new_content: str, action: str = "update") -> str:
        try:
            full_path = self.resolve_safe_path(rel_path)
        except ValueError:
            return ""
        if not full_path.exists():
            return ""
        old_text = full_path.read_text(encoding="utf-8")
        if action == "append":
            sep = "\n\n" if old_text and not old_text.endswith("\n\n") else ""
            target = f"{old_text}{sep}{new_content.strip()}\n"
        else:
            target = new_content if new_content.endswith("\n") else new_content + "\n"
        diff_lines = difflib.unified_diff(
            old_text.splitlines(),
            target.splitlines(),
            fromfile=f"a/{rel_path}",
            tofile=f"b/{rel_path}",
            lineterm="",
            n=2,
        )
        return "\n".join(list(diff_lines)[:120])

    def read_protocol_prompt(self) -> str:
        proto = self.vault_path / "_系统协议" / "顾问人格与工作协议.md"
        if proto.exists():
            return proto.read_text(encoding="utf-8")
        return "你是我的个人成长决策顾问与记忆共建者。请先理解我的核心自我与历史经历，反讨好、重证据，写入记忆前必须让我半自动确认。"

    def load_core_self(self, allow_sensitive: bool = False) -> list[MemoryDoc]:
        docs = [d for d in self.scan_all(include_system=False) if d.category == "00-核心自我"]
        filtered = []
        for d in docs:
            if d.privacy == "sensitive" and not allow_sensitive:
                continue
            filtered.append(d)
        return filtered

    def retrieve_relevant(
        self,
        query: str,
        top_k: int = 6,
        allow_sensitive: bool = False,
        include_inbox: bool = False,
    ) -> list[MemoryDoc]:
        all_docs = self.scan_all(include_system=False)
        candidates = []
        for d in all_docs:
            if d.category == "00-核心自我":
                continue
            if d.category == "99-收件箱" and not include_inbox:
                continue
            if d.privacy == "sensitive" and not allow_sensitive:
                continue
            candidates.append(d)

        if not candidates:
            return []

        q_tokens = _tokenize(query)
        scored: list[tuple[float, MemoryDoc]] = []
        by_stem: dict[str, MemoryDoc] = {}
        for d in candidates:
            by_stem[Path(d.rel_path).stem] = d
            by_stem[d.rel_path[:-3]] = d

        for d in candidates:
            title_tokens = _tokenize(d.title)
            emo_text = " ".join(
                str(e.get("name", "")) + " " + str(e.get("trigger", ""))
                for e in d.emotions
                if isinstance(e, dict)
            )
            meta_tokens = _tokenize(" ".join(d.people) + " " + emo_text)
            body_tokens = _tokenize(d.body[:3000])

            overlap_title = len(q_tokens & title_tokens)
            overlap_meta = len(q_tokens & meta_tokens)
            overlap_body = len(q_tokens & body_tokens)

            # Generative-Agents inspired scoring: relevance + importance + slight recency
            relevance = overlap_title * 3.0 + overlap_meta * 2.5 + min(overlap_body, 15) * 0.8
            importance_bonus = (d.importance / 10.0) * 1.8
            if d.rel_path.endswith("观点演变日志.md"):
                importance_bonus += 0.8
            score = relevance + importance_bonus
            scored.append((score, d))

        scored.sort(key=lambda item: (item[0], item[1].importance, item[1].mtime), reverse=True)
        selected = [d for _, d in scored[:top_k]]

        # 1-hop wikilink neighbor boost (up to 2 extra docs)
        selected_paths = {d.rel_path for d in selected}
        extras: list[MemoryDoc] = []
        for d in selected:
            for link in d.wikilinks:
                target = by_stem.get(link) or by_stem.get(link.split("/")[-1])
                if target and target.rel_path not in selected_paths:
                    selected_paths.add(target.rel_path)
                    extras.append(target)
                    if len(extras) >= 2:
                        break
            if len(extras) >= 2:
                break

        return selected + extras

    def sanitize_for_llm(self, doc: MemoryDoc, allow_sensitive: bool = False) -> str:
        if doc.privacy == "sensitive" and not allow_sensitive:
            return "[该文档标记为 sensitive，已按隐私规则拦截]"
        return strip_private_blocks(doc.raw)

    def get_stats(self) -> dict[str, Any]:
        docs = self.scan_all(include_system=False)
        counts: dict[str, int] = {k: 0 for k, _ in CATEGORY_ORDER if k != SYSTEM_PREFIX}
        sensitive_count = 0
        high_importance = 0
        for d in docs:
            if d.category in counts:
                counts[d.category] += 1
            if d.privacy == "sensitive":
                sensitive_count += 1
            if d.importance >= 7 and d.category != "00-核心自我":
                high_importance += 1
        return {
            "total": len(docs),
            "by_category": counts,
            "high_importance_events": high_importance,
            "sensitive_protected": sensitive_count,
            "vault_path": str(self.vault_path),
        }

    def infer_write_level(self, rel_path: str, action: str = "create") -> int:
        cleaned = rel_path.strip().lstrip("/")
        if cleaned.startswith("99-收件箱/"):
            return 1
        top = cleaned.split("/", 1)[0]
        if top in CORE_DIRS or action == "delete":
            return 3
        return 2
