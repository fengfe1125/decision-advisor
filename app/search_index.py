from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
import numpy as np

from .config import EmbeddingConfig, load_config
from .db import get_conn
from .memory_store import MemoryDoc, MemoryStore, _tokenize

OBSERVATION_RE = re.compile(r"^\s*-\s*\[([^\]]+)\]\s*(.+)$", re.MULTILINE)
YEAR_RE = re.compile(r"(20\d{2})\s*年?")
DATE_RE = re.compile(r"(20\d{2}-\d{2}(?:-\d{2})?)")

_LOCAL_EMBEDDER_CACHE: dict[str, Any] = {}


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def _extract_observations(body: str) -> list[dict[str, str]]:
    items = []
    for m in OBSERVATION_RE.finditer(body):
        items.append({"tag": m.group(1).strip(), "text": m.group(2).strip()})
    return items


def _normalize_date(val: Any) -> str:
    if val is None:
        return ""
    if hasattr(val, "isoformat"):
        return val.isoformat()[:10]
    s = str(val).strip()
    m = DATE_RE.search(s)
    if m:
        d = m.group(1)
        return d if len(d) == 10 else f"{d}-01"
    ym = YEAR_RE.search(s)
    if ym:
        return f"{ym.group(1)}-01-01"
    return ""


def _parse_temporal_hint(query: str) -> tuple[str | None, str | None]:
    """Extract optional (year_prefix, as_of_cutoff) hint from natural language query."""
    m_before = re.search(r"(20\d{2})\s*年?(?:以前|之前|底前|底)", query)
    if m_before:
        return m_before.group(1), f"{m_before.group(1)}-12-31"
    m_year = YEAR_RE.search(query)
    if m_year:
        return m_year.group(1), None
    if "去年" in query:
        prev_year = str(datetime.now().year - 1)
        return prev_year, None
    return None, None


class EmbeddingEngine:
    """Supports local Chinese BGE (fastembed ONNX) or optional OpenAI-compatible Embedding API."""

    def __init__(self, cfg: EmbeddingConfig | None = None):
        self.cfg = cfg or load_config().embedding

    @property
    def model_id(self) -> str:
        if self.cfg.mode == "disabled":
            return "disabled"
        if self.cfg.mode == "openai_compatible":
            return f"api:{self.cfg.api_model}"
        return f"local:{self.cfg.local_model}"

    def _get_local_model(self):
        key = self.cfg.local_model
        if key not in _LOCAL_EMBEDDER_CACHE:
            from fastembed import TextEmbedding

            _LOCAL_EMBEDDER_CACHE[key] = TextEmbedding(model_name=key)
        return _LOCAL_EMBEDDER_CACHE[key]

    def embed_texts(self, texts: list[str]) -> list[np.ndarray | None]:
        if not texts or self.cfg.mode == "disabled":
            return [None] * len(texts)

        if self.cfg.mode == "openai_compatible":
            if not self.cfg.api_key.strip():
                return [None] * len(texts)
            base = self.cfg.api_base_url.strip().rstrip("/")
            url = base if base.endswith("/embeddings") else (f"{base}/embeddings" if base.endswith("/v1") else f"{base}/v1/embeddings")
            try:
                resp = httpx.post(
                    url,
                    headers={"Authorization": f"Bearer {self.cfg.api_key}", "Content-Type": "application/json"},
                    json={"model": self.cfg.api_model, "input": [t[:4000] for t in texts]},
                    timeout=45.0,
                )
                resp.raise_for_status()
                data = resp.json().get("data") or []
                data.sort(key=lambda item: item.get("index", 0))
                out: list[np.ndarray | None] = []
                for item in data:
                    vec = np.asarray(item["embedding"], dtype=np.float32)
                    norm = np.linalg.norm(vec)
                    out.append(vec / norm if norm > 0 else vec)
                return out if len(out) == len(texts) else [None] * len(texts)
            except Exception:
                return [None] * len(texts)

        # Default: local Chinese BGE via fastembed
        try:
            model = self._get_local_model()
            out = []
            for vec in model.embed([t[:2000] for t in texts]):
                arr = np.asarray(vec, dtype=np.float32)
                norm = np.linalg.norm(arr)
                out.append(arr / norm if norm > 0 else arr)
            return out
        except Exception:
            return [None] * len(texts)


def _doc_embedding_text(doc: MemoryDoc, observations: list[dict[str, str]]) -> str:
    emo_str = " ".join(
        f"{e.get('name', '')} {e.get('trigger', '')} {e.get('thought', '')}"
        for e in doc.emotions
        if isinstance(e, dict)
    )
    obs_str = " ".join(f"{o['tag']}:{o['text']}" for o in observations)
    people_str = " ".join(doc.people)
    return f"{doc.title}\n分类:{doc.category_label}\n时间:{doc.event_time}\n人物:{people_str}\n情绪:{emo_str}\n观察:{obs_str}\n{doc.body[:2200]}"


def sync_vault_index(
    store: MemoryStore,
    embedder: EmbeddingEngine | None = None,
    force_rebuild: bool = False,
) -> dict[str, Any]:
    """Incrementally sync Markdown vault into local SQLite vector + FTS5 + temporal + graph tables."""
    embedder = embedder or EmbeddingEngine()
    docs = store.scan_all(include_system=False)
    current_paths = {d.rel_path for d in docs}
    model_id = embedder.model_id

    with get_conn() as conn:
        existing_rows = conn.execute(
            "SELECT rel_path, sha256, embedding_model, embedding_dim FROM doc_index"
        ).fetchall()
        existing_map = {r["rel_path"]: dict(r) for r in existing_rows}

        # Delete stale entries
        stale = [p for p in existing_map if p not in current_paths]
        for p in stale:
            conn.execute("DELETE FROM doc_index WHERE rel_path = ?", (p,))
            conn.execute("DELETE FROM doc_fts WHERE rel_path = ?", (p,))

    to_index: list[tuple[MemoryDoc, str, list[dict[str, str]]]] = []
    for d in docs:
        sha = hashlib.sha256(d.raw.encode("utf-8")).hexdigest()
        prev = existing_map.get(d.rel_path)
        needs_embed = (
            force_rebuild
            or not prev
            or prev["sha256"] != sha
            or (model_id != "disabled" and (prev["embedding_model"] != model_id or prev["embedding_dim"] == 0))
        )
        if needs_embed:
            to_index.append((d, sha, _extract_observations(d.body)))

    vectors: list[np.ndarray | None] = []
    if to_index:
        texts = [_doc_embedding_text(d, obs) for d, _, obs in to_index]
        vectors = embedder.embed_texts(texts)

    now = _now_iso()
    indexed_count = 0
    with get_conn() as conn:
        for (d, sha, obs), vec in zip(to_index, vectors):
            fm = d.frontmatter
            event_time = _normalize_date(fm.get("event_time") or fm.get("date") or fm.get("period") or fm.get("updated_at"))
            recorded_at = _normalize_date(fm.get("recorded_at") or fm.get("updated_at"))
            valid_from = _normalize_date(fm.get("valid_from") or event_time or recorded_at)
            invalid_at = _normalize_date(fm.get("invalid_at"))
            superseded_by = str(fm.get("superseded_by") or "").strip()
            raw_chapters = fm.get("chapters") or fm.get("related_chapters") or []
            if isinstance(raw_chapters, str):
                raw_chapters = [raw_chapters]
            chapters = [str(c) for c in raw_chapters if c]

            emb_blob = vec.astype(np.float32).tobytes() if vec is not None else None
            emb_dim = int(vec.shape[0]) if vec is not None else 0
            emb_model = model_id if vec is not None else ""

            conn.execute(
                """
                INSERT INTO doc_index (
                    rel_path, sha256, title, category, category_label, privacy, importance,
                    event_time, recorded_at, valid_from, invalid_at, superseded_by,
                    emotions_json, people_json, chapters_json, observations_json, wikilinks_json,
                    body_text, embedding_blob, embedding_dim, embedding_model, mtime, indexed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(rel_path) DO UPDATE SET
                    sha256=excluded.sha256, title=excluded.title, category=excluded.category,
                    category_label=excluded.category_label, privacy=excluded.privacy,
                    importance=excluded.importance, event_time=excluded.event_time,
                    recorded_at=excluded.recorded_at, valid_from=excluded.valid_from,
                    invalid_at=excluded.invalid_at, superseded_by=excluded.superseded_by,
                    emotions_json=excluded.emotions_json, people_json=excluded.people_json,
                    chapters_json=excluded.chapters_json, observations_json=excluded.observations_json,
                    wikilinks_json=excluded.wikilinks_json, body_text=excluded.body_text,
                    embedding_blob=excluded.embedding_blob, embedding_dim=excluded.embedding_dim,
                    embedding_model=excluded.embedding_model, mtime=excluded.mtime,
                    indexed_at=excluded.indexed_at
                """,
                (
                    d.rel_path,
                    sha,
                    d.title,
                    d.category,
                    d.category_label,
                    d.privacy,
                    d.importance,
                    event_time,
                    recorded_at,
                    valid_from,
                    invalid_at,
                    superseded_by,
                    json.dumps(d.emotions, ensure_ascii=False),
                    json.dumps(d.people, ensure_ascii=False),
                    json.dumps(chapters, ensure_ascii=False),
                    json.dumps(obs, ensure_ascii=False),
                    json.dumps(d.wikilinks, ensure_ascii=False),
                    d.body,
                    emb_blob,
                    emb_dim,
                    emb_model,
                    d.mtime,
                    now,
                ),
            )

            emo_text = " ".join(
                f"{e.get('name', '')} {e.get('trigger', '')} {e.get('body', '')} {e.get('thought', '')}"
                for e in d.emotions
                if isinstance(e, dict)
            )
            obs_text = " ".join(f"{o['tag']} {o['text']}" for o in obs)
            conn.execute("DELETE FROM doc_fts WHERE rel_path = ?", (d.rel_path,))
            conn.execute(
                "INSERT INTO doc_fts (rel_path, title, body_text, people_text, emotions_text, observations_text) VALUES (?, ?, ?, ?, ?, ?)",
                (d.rel_path, d.title, d.body, " ".join(d.people), emo_text, obs_text),
            )
            indexed_count += 1

        # Rebuild knowledge graph edges cleanly whenever anything changed
        if to_index or stale or force_rebuild:
            _rebuild_graph_edges(conn, docs)

        stats_row = conn.execute(
            "SELECT COUNT(*) AS total, SUM(CASE WHEN embedding_dim > 0 THEN 1 ELSE 0 END) AS embedded FROM doc_index"
        ).fetchone()
        edge_count = conn.execute("SELECT COUNT(*) AS c FROM graph_edges").fetchone()["c"]

    return {
        "total_docs": int(stats_row["total"] or 0),
        "embedded_docs": int(stats_row["embedded"] or 0),
        "updated_now": indexed_count,
        "deleted_stale": len(stale),
        "graph_edges": int(edge_count or 0),
        "embedding_model": model_id,
    }


def _rebuild_graph_edges(conn, docs: list[MemoryDoc]) -> None:
    conn.execute("DELETE FROM graph_edges")
    by_stem: dict[str, str] = {}
    people_to_docs: dict[str, list[str]] = {}
    chapter_to_docs: dict[str, list[str]] = {}

    for d in docs:
        by_stem[Path(d.rel_path).stem] = d.rel_path
        by_stem[d.rel_path[:-3]] = d.rel_path
        by_stem[d.title] = d.rel_path
        for person in d.people:
            people_to_docs.setdefault(person, []).append(d.rel_path)
        raw_ch = d.frontmatter.get("chapters") or d.frontmatter.get("related_chapters") or []
        if isinstance(raw_ch, str):
            raw_ch = [raw_ch]
        for ch in raw_ch:
            if ch:
                chapter_to_docs.setdefault(str(ch), []).append(d.rel_path)

    edge_rows: list[tuple[str, str, str, str, float]] = []
    seen: set[tuple[str, str, str]] = set()

    for d in docs:
        for link in d.wikilinks:
            target = by_stem.get(link) or by_stem.get(link.split("/")[-1]) or ""
            if target == d.rel_path:
                continue
            key = (d.rel_path, target or link, "wikilink")
            if key not in seen:
                seen.add(key)
                edge_rows.append((d.rel_path, link, target, "wikilink", 1.0))

    for person, paths in people_to_docs.items():
        if len(paths) < 2:
            continue
        for i, src in enumerate(paths):
            for dst in paths[i + 1 :]:
                for a, b in ((src, dst), (dst, src)):
                    key = (a, b, f"person:{person}")
                    if key not in seen:
                        seen.add(key)
                        edge_rows.append((a, person, b, "shared_person", 0.7))

    for chapter, paths in chapter_to_docs.items():
        if len(paths) < 2:
            continue
        for i, src in enumerate(paths):
            for dst in paths[i + 1 :]:
                for a, b in ((src, dst), (dst, src)):
                    key = (a, b, f"chapter:{chapter}")
                    if key not in seen:
                        seen.add(key)
                        edge_rows.append((a, chapter, b, "shared_chapter", 0.6))

    if edge_rows:
        conn.executemany(
            "INSERT INTO graph_edges (src_path, dst_key, dst_path, relation_type, weight) VALUES (?, ?, ?, ?, ?)",
            edge_rows,
        )


def hybrid_search(
    store: MemoryStore,
    query: str,
    *,
    top_k: int = 6,
    allow_sensitive: bool = False,
    include_core: bool = False,
    include_inbox: bool = False,
    as_of: str | None = None,
    embedder: EmbeddingEngine | None = None,
) -> list[dict[str, Any]]:
    """4-Way Hybrid Retrieval: Chinese Semantic Vector + Lexical BM25/CJK + Graph 1-2 Hop + Bi-Temporal & Importance."""
    embedder = embedder or EmbeddingEngine()
    sync_vault_index(store, embedder=embedder, force_rebuild=False)

    year_hint, auto_as_of = _parse_temporal_hint(query)
    effective_as_of = _normalize_date(as_of) if as_of else auto_as_of

    with get_conn() as conn:
        rows = conn.execute("SELECT * FROM doc_index").fetchall()
        edge_rows = conn.execute("SELECT src_path, dst_path, relation_type, weight FROM graph_edges WHERE dst_path != ''").fetchall()

    candidates: dict[str, dict[str, Any]] = {}
    for r in rows:
        d = dict(r)
        if not include_core and d["category"] == "00-核心自我":
            continue
        if not include_inbox and d["category"] == "99-收件箱":
            continue
        if d["privacy"] == "sensitive" and not allow_sensitive:
            continue

        # Bi-temporal as_of filter: show what existed & was valid at `effective_as_of`
        if effective_as_of:
            doc_start = d["event_time"] or d["valid_from"] or d["recorded_at"]
            if doc_start and doc_start > effective_as_of:
                continue
            if d["invalid_at"] and d["invalid_at"] <= effective_as_of:
                continue

        candidates[d["rel_path"]] = d

    if not candidates:
        return []

    # --- Way 1: Chinese Semantic Vector Search ---
    sem_scores: dict[str, float] = {}
    q_vecs = embedder.embed_texts([query])
    q_vec = q_vecs[0] if q_vecs else None
    if q_vec is not None:
        q_dim = int(q_vec.shape[0])
        for path, d in candidates.items():
            if d["embedding_blob"] and d["embedding_dim"] == q_dim:
                doc_vec = np.frombuffer(d["embedding_blob"], dtype=np.float32)
                sim = float(np.dot(q_vec, doc_vec))
                sem_scores[path] = sim

    # --- Way 2: Lexical (CJK Bigrams + Title/Emotion/People/Observations) ---
    q_tokens = _tokenize(query)
    lex_scores: dict[str, float] = {}
    for path, d in candidates.items():
        title_t = _tokenize(d["title"])
        meta_t = _tokenize(d["people_json"] + " " + d["emotions_json"] + " " + d["observations_json"])
        body_t = _tokenize(d["body_text"][:3000])
        score = len(q_tokens & title_t) * 3.5 + len(q_tokens & meta_t) * 2.6 + min(len(q_tokens & body_t), 20) * 0.75
        if score > 0:
            lex_scores[path] = score

    # Compute RRF fusion of Way 1 + Way 2
    rrf: dict[str, float] = {p: 0.0 for p in candidates}
    reasons: dict[str, list[str]] = {p: [] for p in candidates}

    if sem_scores:
        ranked_sem = sorted(sem_scores.items(), key=lambda x: x[1], reverse=True)
        for rank, (p, sim) in enumerate(ranked_sem, start=1):
            rrf[p] += 1.6 / (30.0 + rank)
            if sim >= 0.42:
                reasons[p].append(f"中文语义 {sim:.2f}")

    if lex_scores:
        ranked_lex = sorted(lex_scores.items(), key=lambda x: x[1], reverse=True)
        for rank, (p, sc) in enumerate(ranked_lex, start=1):
            rrf[p] += 1.2 / (30.0 + rank)
            if rank <= 8:
                reasons[p].append("关键词命中")

    # --- Way 4: Temporal + Importance Weighting ---
    for path, d in candidates.items():
        imp = int(d["importance"] or 5)
        rrf[path] += (imp / 10.0) * 0.015
        if imp >= 8:
            reasons[path].append(f"高显著 {imp}/10")
        if year_hint and (d["event_time"].startswith(year_hint) or year_hint in d["title"]):
            rrf[path] += 0.035
            reasons[path].append(f"时间匹配 {year_hint}")
        if not effective_as_of and (d["superseded_by"] or d["invalid_at"]):
            # Down-rank superseded cognition unless historically queried
            rrf[path] *= 0.65
            reasons[path].append("历史已演化认知")
        if path.endswith("观点演变日志.md"):
            rrf[path] += 0.012

    # --- Way 3: Graph 1-Hop Expansion from Top Seeds ---
    adj: dict[str, list[tuple[str, str, float]]] = {}
    for er in edge_rows:
        adj.setdefault(er["src_path"], []).append((er["dst_path"], er["relation_type"], float(er["weight"])))
        adj.setdefault(er["dst_path"], []).append((er["src_path"], er["relation_type"], float(er["weight"]) * 0.85))

    top_seeds = sorted(rrf.items(), key=lambda x: x[1], reverse=True)[:3]
    for seed_path, seed_score in top_seeds:
        if seed_score <= 0:
            continue
        for nbr, rel_type, w in adj.get(seed_path, []):
            if nbr in rrf and nbr != seed_path:
                rrf[nbr] += 0.018 * w
                label = "双链图谱" if rel_type == "wikilink" else ("共同人物" if rel_type == "shared_person" else "同一人生章节")
                if label not in reasons[nbr]:
                    reasons[nbr].append(label)

    ranked_all = sorted(
        rrf.items(),
        key=lambda x: (x[1], candidates[x[0]]["importance"], candidates[x[0]]["mtime"]),
        reverse=True,
    )[:top_k]

    results = []
    for path, final_score in ranked_all:
        d = candidates[path]
        try:
            doc = store.read_doc(path)
        except Exception:
            continue
        results.append(
            {
                "doc": doc,
                "score": round(final_score, 4),
                "semantic": round(sem_scores.get(path, 0.0), 3),
                "reasons": reasons[path][:3] or [f"显著性 {d['importance']}/10"],
            }
        )
    return results


def get_index_stats() -> dict[str, Any]:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT COUNT(*) AS total, SUM(CASE WHEN embedding_dim > 0 THEN 1 ELSE 0 END) AS embedded, MAX(embedding_model) AS model, MAX(indexed_at) AS last_sync FROM doc_index"
        ).fetchone()
        edges = conn.execute("SELECT COUNT(*) AS c FROM graph_edges").fetchone()["c"]
    return {
        "total_docs": int(row["total"] or 0),
        "embedded_docs": int(row["embedded"] or 0),
        "embedding_model": row["model"] or "尚未构建",
        "last_sync": row["last_sync"] or "",
        "graph_edges": int(edges or 0),
    }


def get_timeline(
    store: MemoryStore,
    *,
    start_date: str = "",
    end_date: str = "",
    allow_sensitive: bool = False,
) -> list[dict[str, Any]]:
    sync_vault_index(store)
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT rel_path, title, category, category_label, privacy, importance,
                   event_time, recorded_at, valid_from, invalid_at, superseded_by,
                   emotions_json, people_json, body_text
            FROM doc_index
            WHERE category IN ('01-人生章节', '02-经历与感受', '04-决策实验室', '05-认知演进与反思')
            ORDER BY CASE WHEN event_time != '' THEN event_time ELSE recorded_at END DESC, importance DESC
            """
        ).fetchall()

    items = []
    for r in rows:
        d = dict(r)
        if d["privacy"] == "sensitive" and not allow_sensitive:
            continue
        t = d["event_time"] or d["recorded_at"]
        if start_date and t and t < start_date:
            continue
        if end_date and t and t > end_date:
            continue
        try:
            emos = [e.get("name", "") for e in json.loads(d["emotions_json"]) if isinstance(e, dict) and e.get("name")]
        except Exception:
            emos = []
        try:
            people = json.loads(d["people_json"])
        except Exception:
            people = []
        items.append(
            {
                "path": d["rel_path"],
                "title": d["title"],
                "category": d["category"],
                "category_label": d["category_label"],
                "event_time": d["event_time"],
                "recorded_at": d["recorded_at"],
                "valid_from": d["valid_from"],
                "invalid_at": d["invalid_at"],
                "superseded_by": d["superseded_by"],
                "importance": d["importance"],
                "privacy": d["privacy"],
                "emotions": emos,
                "people": people,
                "snippet": re.sub(r"\s+", " ", d["body_text"].strip())[:140],
            }
        )
    return items


def get_knowledge_graph(store: MemoryStore, allow_sensitive: bool = False) -> dict[str, Any]:
    sync_vault_index(store)
    with get_conn() as conn:
        docs = conn.execute(
            "SELECT rel_path, title, category, category_label, importance, privacy, emotions_json FROM doc_index"
        ).fetchall()
        edges = conn.execute(
            "SELECT src_path, dst_key, dst_path, relation_type, weight FROM graph_edges WHERE dst_path != ''"
        ).fetchall()

    allowed = set()
    nodes = []
    for r in docs:
        if r["privacy"] == "sensitive" and not allow_sensitive:
            continue
        allowed.add(r["rel_path"])
        try:
            emos = [e.get("name", "") for e in json.loads(r["emotions_json"]) if isinstance(e, dict) and e.get("name")]
        except Exception:
            emos = []
        nodes.append(
            {
                "id": r["rel_path"],
                "title": r["title"],
                "category": r["category"],
                "category_label": r["category_label"],
                "importance": r["importance"],
                "emotions": emos,
            }
        )

    links = []
    seen_pairs = set()
    for e in edges:
        if e["src_path"] in allowed and e["dst_path"] in allowed:
            pair = tuple(sorted([e["src_path"], e["dst_path"]])) + (e["relation_type"],)
            if pair not in seen_pairs:
                seen_pairs.add(pair)
                links.append(
                    {
                        "source": e["src_path"],
                        "target": e["dst_path"],
                        "label": e["dst_key"],
                        "relation_type": e["relation_type"],
                        "weight": e["weight"],
                    }
                )
    return {"nodes": nodes, "edges": links}
