#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
import re
import time
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve()
DEFAULT_CODEX_HOME = SCRIPT_PATH.parents[3]
CODEX_HOME = Path(os.environ.get("CODEX_HOME", str(DEFAULT_CODEX_HOME))).expanduser()
HOME = CODEX_HOME.parent
MEMORY_ROOT = CODEX_HOME / "memories"
DATA_DIR = MEMORY_ROOT / "data"
HISTORY_FILE = CODEX_HOME / "history.jsonl"
QUERIES_FILE = DATA_DIR / "queries.jsonl"
PROFILE_FILE = DATA_DIR / "profile.json"
PROJECTS_FILE = DATA_DIR / "projects.json"
MANUAL_NOTES_FILE = DATA_DIR / "manual-notes.jsonl"
SEMANTIC_INDEX_FILE = DATA_DIR / "semantic-index.json"
STATE_FILE = DATA_DIR / "state.json"
BRIEF_FILE = MEMORY_ROOT / "memory-brief.md"

TOPIC_KEYWORDS = {
    "audio": ["alsa", "audio", "sound", "gstreamer", "volume", "buffer", "pcm", "codec"],
    "airplay": ["airplay", "raop"],
    "bluetooth": ["bluetooth", "bt", "a2dp"],
    "yocto": ["yocto", "bitbake", "recipe", "oe-init-build-env", "meta-"],
    "kernel-driver": ["driver", "kernel", "dts", "dtsi", "device tree", "i2c", "spi"],
    "embedded-audio-io": ["i2s", "dma", "cs8406", "hw_params"],
    "upnp-dlna": ["upnp", "dlna", "gmediarender"],
    "build-debug": ["build", "compile", "test", "fail", "error", "log"],
}


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def now_ts():
    return int(time.time())


def ensure_layout():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    MANUAL_NOTES_FILE.touch(exist_ok=True)


def load_json(path, default):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def load_jsonl(path):
    if not path.exists():
        return []
    items = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            items.append(json.loads(line))
    return items


def write_json(path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_jsonl(path, items):
    with path.open("w", encoding="utf-8") as handle:
        for item in items:
            handle.write(json.dumps(item, ensure_ascii=False) + "\n")


def stable_id(*parts):
    raw = "||".join(str(part) for part in parts)
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]


def clean_text(text):
    return " ".join((text or "").split()).strip()


def summarize_text(text, limit=180):
    text = clean_text(text)
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 3)] + "..."


def focus_text(text, limit=720):
    text = clean_text(text)
    if len(text) <= limit:
        return text
    head = text[:200]
    tail = text[-520:]
    return clean_text(f"{head} {tail}")


def extract_paths(text):
    matches = re.findall(r"/(?:home|data|mnt|tmp)/[-._/@+a-zA-Z0-9/]+", text)
    paths = []
    for path in matches:
        path = path.rstrip(".,);:?!\"'")
        if path not in paths:
            paths.append(path)
    return paths


def project_root(path):
    parts = Path(path).parts
    if len(parts) >= 4 and parts[1] == "data" and parts[2] == "test":
        return str(Path(*parts[:4]))
    if len(parts) >= 5 and parts[1] == "home" and parts[2] == "ameba_builder" and parts[3] == "sources":
        return str(Path(*parts[:5]))
    if len(parts) >= 4 and parts[1] == "home" and parts[2] == "ameba_builder":
        candidate = parts[3]
        if candidate.startswith("."):
            return "/home/ameba_builder"
        if "." in candidate:
            return "/home/ameba_builder"
        return str(Path(*parts[:4]))
    if len(parts) >= 3 and parts[1] == "home" and parts[2] == "ameba_builder":
        return "/home/ameba_builder"
    return ""


def normalize_project(project):
    project = clean_text(project)
    if not project:
        return ""
    derived = project_root(project)
    if derived:
        return derived
    return project


def detect_topics(text):
    lowered = (text or "").lower()
    return [topic for topic, keywords in TOPIC_KEYWORDS.items() if any(keyword in lowered for keyword in keywords)]


def is_chinese_heavy(text):
    chinese_chars = len(re.findall(r"[\u4e00-\u9fff]", text))
    return chinese_chars >= 4


def tokenize_text(text):
    text = clean_text(text).lower()
    tokens = []

    for raw in re.findall(r"[a-z0-9][a-z0-9_./:-]*", text):
        for part in re.split(r"[/_.:\-]+", raw):
            if len(part) < 2:
                continue
            if part.isdigit():
                continue
            if re.fullmatch(r"[0-9a-f]{8,}", part):
                continue
            tokens.append(part)

    for chunk in re.findall(r"[\u4e00-\u9fff]{2,}", text):
        if len(chunk) <= 8:
            tokens.append(chunk)
        for size in (2, 3):
            if len(chunk) < size:
                continue
            for idx in range(len(chunk) - size + 1):
                tokens.append(chunk[idx : idx + size])

    return tokens


def parse_timestamp(value):
    if isinstance(value, (int, float)):
        return int(value)
    text = clean_text(value)
    if not text:
        return 0
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return int(datetime.fromisoformat(text).timestamp())
    except ValueError:
        return 0


def normalize_entry(entry):
    text = clean_text(entry.get("text", ""))
    paths = entry.get("paths") or extract_paths(text)
    roots = entry.get("project_roots") or sorted(root for root in {project_root(path) for path in paths} if root)
    focused = clean_text(entry.get("focus_text") or focus_text(text))
    topics = entry.get("topics") or detect_topics(focused)
    return {
        "id": entry.get("id") or stable_id(entry.get("session_id", ""), entry.get("ts", ""), text),
        "session_id": entry.get("session_id"),
        "ts": parse_timestamp(entry.get("ts")),
        "text": text,
        "focus_text": focused,
        "paths": paths,
        "project_roots": roots,
        "topics": topics,
    }


def load_history_entries(max_entries=None):
    entries = [normalize_entry(item) for item in load_jsonl(HISTORY_FILE) if clean_text(item.get("text", ""))]
    entries.sort(key=lambda item: (item.get("ts") or 0, item["id"]))
    if max_entries and len(entries) > max_entries:
        entries = entries[-max_entries:]
    return entries


def load_query_entries():
    entries = [normalize_entry(item) for item in load_jsonl(QUERIES_FILE)]
    if entries:
        return entries
    return load_history_entries()


def build_profile(entries):
    total = len(entries)
    topic_counter = Counter(topic for entry in entries for topic in entry["topics"])
    chinese_entries = sum(1 for entry in entries if is_chinese_heavy(entry["text"]))
    path_entries = sum(1 for entry in entries if entry["paths"])
    why_entries = sum(1 for entry in entries if any(token in entry["text"].lower() for token in ["为什么", "原因", "分析", "why"]))
    fix_entries = sum(1 for entry in entries if any(token in entry["text"].lower() for token in ["怎么修改", "如何修改", "修复", "怎么做", "帮我", "fix"]))
    signals = []
    if total:
        if chinese_entries * 2 >= total:
            signals.append({"label": "preferred-language", "detail": "Chinese appears to be the dominant working language.", "confidence": "high", "evidence_count": chinese_entries})
        if path_entries * 3 >= total:
            signals.append({"label": "path-heavy-questions", "detail": "Questions often include concrete absolute paths or repository locations.", "confidence": "medium", "evidence_count": path_entries})
        if why_entries:
            signals.append({"label": "root-cause-first", "detail": "Many requests ask for root-cause analysis before or alongside fixes.", "confidence": "medium", "evidence_count": why_entries})
        if fix_entries:
            signals.append({"label": "implementation-oriented", "detail": "Requests frequently move from diagnosis to concrete code or config changes.", "confidence": "medium", "evidence_count": fix_entries})
    return {
        "generated_at": now_iso(),
        "history_entries": total,
        "top_topics": [{"name": name, "count": count} for name, count in topic_counter.most_common(8)],
        "signals": signals,
    }


def build_projects(entries):
    projects = {}
    for entry in entries:
        for root in entry["project_roots"]:
            project = projects.setdefault(
                root,
                {
                    "root": root,
                    "mentions": 0,
                    "last_seen_ts": 0,
                    "topic_counter": Counter(),
                    "sample_queries": [],
                },
            )
            project["mentions"] += 1
            project["last_seen_ts"] = max(project["last_seen_ts"], entry.get("ts") or 0)
            project["topic_counter"].update(entry["topics"])
            if len(project["sample_queries"]) < 3 and entry["focus_text"] not in project["sample_queries"]:
                project["sample_queries"].append(summarize_text(entry["focus_text"], limit=180))
    normalized = []
    for root, project in projects.items():
        normalized.append(
            {
                "root": root,
                "mentions": project["mentions"],
                "last_seen_ts": project["last_seen_ts"],
                "topics": [{"name": name, "count": count} for name, count in project["topic_counter"].most_common(5)],
                "sample_queries": project["sample_queries"],
            }
        )
    normalized.sort(key=lambda item: (-item["mentions"], -(item["last_seen_ts"] or 0), item["root"]))
    return {"generated_at": now_iso(), "projects": normalized[:12]}


def load_notes():
    notes = []
    for note in load_jsonl(MANUAL_NOTES_FILE):
        normalized_project = normalize_project(note.get("project", ""))
        notes.append(
            {
                "id": note.get("id") or stable_id(note.get("kind", ""), note.get("title", ""), note.get("content", ""), normalized_project, note.get("created_at", "")),
                "kind": note.get("kind", "reflection"),
                "title": clean_text(note.get("title", "")),
                "content": clean_text(note.get("content", "")),
                "summary": clean_text(note.get("summary", note.get("content", ""))),
                "changes": clean_text(note.get("changes", "")),
                "lessons": clean_text(note.get("lessons", "")),
                "next_step": clean_text(note.get("next_step", "")),
                "project": normalized_project,
                "confidence": note.get("confidence", "high"),
                "origin": note.get("origin", "manual"),
                "created_at": note.get("created_at", now_iso()),
                "ts": parse_timestamp(note.get("created_at", "")),
            }
        )
    return notes


def note_text(note):
    parts = []
    seen = set()
    for part in (
        note.get("title", ""),
        note.get("content", ""),
        note.get("summary", ""),
        note.get("changes", ""),
        note.get("lessons", ""),
        note.get("next_step", ""),
    ):
        cleaned = clean_text(part)
        if not cleaned or cleaned in seen:
            continue
        seen.add(cleaned)
        parts.append(cleaned)
    return clean_text(" ".join(parts))


def build_token_counts(text, roots=None, topics=None, kind="", title=""):
    counts = Counter(tokenize_text(title))
    counts.update(tokenize_text(text))
    for root in roots or []:
        normalized_root = normalize_project(root)
        if not normalized_root:
            continue
        counts.update(tokenize_text(normalized_root))
        counts[f"project::{normalized_root}"] += 2
        repo_name = Path(normalized_root).name.lower()
        if repo_name:
            counts[f"repo::{repo_name}"] += 1
    for topic in topics or []:
        counts[f"topic::{topic}"] += 2
    if kind:
        counts[f"kind::{kind}"] += 1
    return counts


def build_semantic_index(entries, notes):
    raw_docs = []

    for entry in entries:
        raw_docs.append(
            {
                "id": f"history:{entry['id']}",
                "source": "history",
                "kind": "query",
                "title": summarize_text(entry["focus_text"], limit=90),
                "summary": summarize_text(entry["focus_text"], limit=180),
                "project_roots": entry["project_roots"],
                "topics": entry["topics"],
                "ts": entry.get("ts") or 0,
                "token_counts": build_token_counts(entry["focus_text"], roots=entry["project_roots"], topics=entry["topics"], kind="query"),
            }
        )

    for note in notes:
        roots = []
        if note.get("project"):
            roots.append(note["project"])
        roots.extend(root for root in {project_root(path) for path in extract_paths(note_text(note))} if root)
        roots = sorted(set(root for root in roots if root))
        text = note_text(note)
        raw_docs.append(
            {
                "id": f"note:{note['id']}",
                "source": "note",
                "kind": note["kind"],
                "title": note["title"] or summarize_text(text, limit=90),
                "summary": summarize_text(text, limit=180),
                "project_roots": roots,
                "topics": detect_topics(text),
                "ts": note.get("ts") or 0,
                "origin": note.get("origin", "manual"),
                "token_counts": build_token_counts(text, roots=roots, topics=detect_topics(text), kind=note["kind"], title=note["title"]),
            }
        )

    document_frequency = Counter()
    for doc in raw_docs:
        for token in doc["token_counts"]:
            document_frequency[token] += 1

    total_docs = max(1, len(raw_docs))
    documents = []
    for doc in raw_docs:
        token_weights = {}
        for token, count in doc["token_counts"].items():
            idf = 1.0 + math.log((total_docs + 1) / (document_frequency[token] + 1))
            token_weights[token] = round((1.0 + math.log(count)) * idf, 4)
        documents.append(
            {
                "id": doc["id"],
                "source": doc["source"],
                "kind": doc["kind"],
                "origin": doc.get("origin", ""),
                "title": doc["title"],
                "summary": doc["summary"],
                "project_roots": doc["project_roots"],
                "topics": doc["topics"],
                "ts": doc["ts"],
                "token_weights": token_weights,
            }
        )

    return {
        "generated_at": now_iso(),
        "doc_count": len(documents),
        "document_frequency": dict(sorted(document_frequency.items())),
        "documents": documents,
    }


def query_token_counts(task="", project=""):
    normalized_project = normalize_project(project)
    topics = detect_topics(task)
    counts = build_token_counts(task, roots=[normalized_project] if normalized_project else [], topics=topics, kind="query")
    return counts, normalized_project, topics


def project_relation_bonus(query_project, doc_roots):
    if not query_project or not doc_roots:
        return 0.0

    bonus = 0.0
    for root in doc_roots:
        normalized_root = normalize_project(root)
        if not normalized_root:
            continue
        if normalized_root == query_project:
            bonus = max(bonus, 8.0)
            continue
        if normalized_root.startswith(query_project.rstrip("/") + "/") or query_project.startswith(normalized_root.rstrip("/") + "/"):
            bonus = max(bonus, 5.0)
            continue
        if Path(normalized_root).name == Path(query_project).name:
            bonus = max(bonus, 2.0)
    return bonus


def recency_boost(ts_value):
    if not ts_value:
        return 0.0
    age_days = max(0.0, (now_ts() - ts_value) / 86400.0)
    return round(1.2 / (1.0 + age_days / 60.0), 4)


def search_documents(index, task="", project="", limit=8):
    counts, normalized_project, topics = query_token_counts(task=task, project=project)
    doc_count = max(1, index.get("doc_count") or len(index.get("documents", [])) or 1)
    document_frequency = index.get("document_frequency", {})

    query_weights = {}
    for token, count in counts.items():
        df = document_frequency.get(token, 0)
        idf = 1.0 + math.log((doc_count + 1) / (df + 1))
        query_weights[token] = (1.0 + math.log(count)) * idf

    if not task and not normalized_project:
        recent = sorted(index.get("documents", []), key=lambda item: (item.get("ts") or 0, item["id"]), reverse=True)
        return [dict(item, score=0.0) for item in recent[:limit]]

    results = []
    for doc in index.get("documents", []):
        lexical = 0.0
        for token, query_weight in query_weights.items():
            doc_weight = doc.get("token_weights", {}).get(token)
            if doc_weight:
                lexical += query_weight * doc_weight

        topic_overlap = len(set(topics) & set(doc.get("topics", []))) * 0.8
        project_bonus = project_relation_bonus(normalized_project, doc.get("project_roots", []))
        recency = recency_boost(doc.get("ts"))
        reflection_bonus = 0.6 if doc.get("kind") == "reflection" and lexical > 0 else 0.0

        score = lexical + topic_overlap + project_bonus + recency + reflection_bonus
        if score <= 0:
            continue
        results.append(
            {
                **doc,
                "score": round(score, 4),
            }
        )

    results.sort(key=lambda item: (-item["score"], -(item.get("ts") or 0), item["id"]))
    return results[:limit]


def refresh_derived_data(entries, task="", project="", persist_queries=False):
    notes = load_notes()
    profile = build_profile(entries)
    projects = build_projects(entries)
    semantic_index = build_semantic_index(entries, notes)

    if persist_queries:
        write_jsonl(QUERIES_FILE, entries)

    write_json(PROFILE_FILE, profile)
    write_json(PROJECTS_FILE, projects)
    write_json(SEMANTIC_INDEX_FILE, semantic_index)
    write_json(
        STATE_FILE,
        {
            "last_refresh_at": now_iso(),
            "history_file": str(HISTORY_FILE),
            "entry_count": len(entries),
            "note_count": len(notes),
            "semantic_doc_count": semantic_index["doc_count"],
        },
    )

    brief = render_brief(profile, projects, notes, semantic_index, task=task, project=project)
    BRIEF_FILE.write_text(brief, encoding="utf-8")
    return notes, semantic_index


def render_brief(profile, projects, notes, semantic_index, task="", project=""):
    project = normalize_project(project)
    results = search_documents(semantic_index, task=task, project=project, limit=12)
    reflection_hits = [item for item in results if item["kind"] == "reflection"][:4]
    note_hits = [item for item in results if item["source"] == "note" and item["kind"] in ("preference", "project")][:4]
    history_hits = [item for item in results if item["source"] == "history"][:6]

    lines = [
        "# Codex Memory Brief",
        "",
        f"Generated: {now_iso()}",
        "",
        "## Stable Signals",
    ]
    if profile.get("signals"):
        for signal in profile["signals"]:
            lines.append(f"- {signal['label']}: {signal['detail']} (confidence={signal['confidence']}, evidence={signal['evidence_count']})")
    else:
        lines.append("- No stable signals recorded yet.")

    lines.extend(["", "## Frequent Topics"])
    if profile.get("top_topics"):
        for topic in profile["top_topics"][:6]:
            lines.append(f"- {topic['name']}: {topic['count']} mentions")
    else:
        lines.append("- No topic history recorded yet.")

    lines.extend(["", "## Project Roots"])
    if projects.get("projects"):
        for project_item in projects["projects"][:6]:
            topic_summary = ", ".join(topic["name"] for topic in project_item.get("topics", [])[:3]) or "none"
            lines.append(f"- {project_item['root']}: {project_item['mentions']} mentions; topics={topic_summary}")
    else:
        lines.append("- No project roots extracted yet.")

    lines.extend(["", "## Relevant Reflections"])
    if reflection_hits:
        for item in reflection_hits:
            scope = ", ".join(item.get("project_roots", [])[:2]) or "no-project"
            lines.append(f"- [score={item['score']:.2f}] {item['title']} -> {item['summary']} [{scope}]")
    else:
        lines.append("- No related reflections recorded yet.")

    lines.extend(["", "## Relevant Notes"])
    if note_hits:
        for item in note_hits:
            scope = ", ".join(item.get("project_roots", [])[:2]) or "global"
            lines.append(f"- [score={item['score']:.2f}] {item['kind']}: {item['title']} -> {item['summary']} [{scope}]")
    elif notes:
        recent_notes = sorted(notes, key=lambda item: (item.get("ts") or 0, item["id"]), reverse=True)[:3]
        for note in recent_notes:
            scope = note.get("project") or "global"
            lines.append(f"- {note['kind']}: {note['title']} -> {summarize_text(note_text(note), limit=180)} [{scope}]")
    else:
        lines.append("- No manual notes recorded yet.")

    lines.extend(["", "## Semantic Matches"])
    if history_hits:
        for item in history_hits:
            scope = ", ".join(item.get("project_roots", [])[:2]) or "no-project"
            lines.append(f"- [score={item['score']:.2f}] {item['summary']} [{scope}]")
    else:
        lines.append("- No related history found.")

    return "\n".join(lines) + "\n"


def store_note(note):
    notes = load_notes()
    duplicate = next(
        (
            item
            for item in notes
            if all(
                item.get(key) == note.get(key)
                for key in ("kind", "title", "content", "summary", "project", "origin")
            )
        ),
        None,
    )
    if duplicate:
        return duplicate, False
    notes.append(note)
    serialized = []
    for item in notes:
        serialized.append(
            {
                "id": item["id"],
                "kind": item["kind"],
                "title": item["title"],
                "content": item["content"],
                "summary": item.get("summary", ""),
                "changes": item.get("changes", ""),
                "lessons": item.get("lessons", ""),
                "next_step": item.get("next_step", ""),
                "project": item.get("project", ""),
                "confidence": item.get("confidence", "high"),
                "origin": item.get("origin", "manual"),
                "created_at": item.get("created_at", now_iso()),
            }
        )
    write_jsonl(MANUAL_NOTES_FILE, serialized)
    return note, True


def command_refresh(args):
    ensure_layout()
    entries = load_history_entries(max_entries=args.max_entries)
    refresh_derived_data(entries, task=args.task, project=args.project, persist_queries=True)
    print(f"refreshed {len(entries)} history entries into {MEMORY_ROOT}")


def command_brief(args):
    ensure_layout()
    entries = load_query_entries()
    notes = load_notes()
    profile = load_json(PROFILE_FILE, build_profile(entries))
    projects = load_json(PROJECTS_FILE, build_projects(entries))
    semantic_index = load_json(SEMANTIC_INDEX_FILE, build_semantic_index(entries, notes))
    brief = render_brief(profile, projects, notes, semantic_index, task=args.task, project=args.project)
    BRIEF_FILE.write_text(brief, encoding="utf-8")
    print(brief, end="")


def command_search(args):
    ensure_layout()
    entries = load_query_entries()
    notes = load_notes()
    semantic_index = load_json(SEMANTIC_INDEX_FILE, build_semantic_index(entries, notes))
    results = search_documents(semantic_index, task=args.task, project=args.project, limit=args.limit)

    print("# Memory Search Results")
    print()
    print(f"- query: {clean_text(args.task) or '(empty)'}")
    print(f"- project: {normalize_project(args.project) or '(none)'}")
    print(f"- results: {len(results)}")
    for idx, item in enumerate(results, start=1):
        scope = ", ".join(item.get("project_roots", [])[:2]) or "global"
        print(f"{idx}. score={item['score']:.2f} source={item['source']} kind={item['kind']} [{scope}]")
        print(f"   {item['title']}")
        print(f"   {item['summary']}")


def command_add(args):
    ensure_layout()
    note = {
        "id": stable_id(args.kind, args.title, args.content, normalize_project(args.project), now_iso()),
        "kind": args.kind,
        "title": clean_text(args.title),
        "content": clean_text(args.content),
        "summary": clean_text(args.content),
        "changes": "",
        "lessons": "",
        "next_step": "",
        "project": normalize_project(args.project),
        "confidence": args.confidence,
        "origin": "manual",
        "created_at": now_iso(),
        "ts": now_ts(),
    }
    stored_note, created = store_note(note)
    refresh_derived_data(load_query_entries(), task=stored_note["title"], project=stored_note["project"])
    if created:
        print(f"added note: {stored_note['id']}")
    else:
        print(f"existing note: {stored_note['id']}")


def command_close_task(args):
    ensure_layout()
    normalized_project = normalize_project(args.project)
    title = clean_text(args.title) or summarize_text(args.task, limit=60)
    summary = clean_text(args.summary)
    changes = clean_text(args.changes)
    lessons = clean_text(args.lessons)
    next_step = clean_text(args.next_step)

    content_parts = [
        f"task={clean_text(args.task)}",
        f"result={args.result}",
        f"summary={summary}",
    ]
    if changes:
        content_parts.append(f"changes={changes}")
    if lessons:
        content_parts.append(f"lessons={lessons}")
    if next_step:
        content_parts.append(f"next_step={next_step}")

    note = {
        "id": stable_id("task-close", title, summary, normalized_project, args.result, now_iso()),
        "kind": "reflection",
        "title": title,
        "content": " | ".join(content_parts),
        "summary": summary,
        "changes": changes,
        "lessons": lessons,
        "next_step": next_step,
        "project": normalized_project,
        "confidence": args.confidence,
        "origin": "task-close",
        "created_at": now_iso(),
        "ts": now_ts(),
    }
    stored_note, created = store_note(note)
    refresh_derived_data(load_query_entries(), task=args.task, project=normalized_project)
    if created:
        print(f"added task reflection: {stored_note['id']}")
    else:
        print(f"existing task reflection: {stored_note['id']}")


def build_parser():
    parser = argparse.ArgumentParser(description="Persistent memory helper for local Codex workflows.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    refresh = subparsers.add_parser("refresh", help="Rebuild structured memory from ~/.codex/history.jsonl")
    refresh.add_argument("--max-entries", type=int, default=None)
    refresh.add_argument("--task", default="")
    refresh.add_argument("--project", default="")
    refresh.set_defaults(func=command_refresh)

    brief = subparsers.add_parser("brief", help="Generate and print the current memory brief")
    brief.add_argument("--task", default="")
    brief.add_argument("--project", default="")
    brief.set_defaults(func=command_brief)

    search = subparsers.add_parser("search", help="Run semantic memory retrieval with project-aware scoring")
    search.add_argument("--task", default="")
    search.add_argument("--project", default="")
    search.add_argument("--limit", type=int, default=8)
    search.set_defaults(func=command_search)

    add = subparsers.add_parser("add", help="Append a manual preference, project note, or reflection")
    add.add_argument("--kind", choices=["preference", "project", "reflection"], required=True)
    add.add_argument("--title", required=True)
    add.add_argument("--content", required=True)
    add.add_argument("--project", default="")
    add.add_argument("--confidence", choices=["low", "medium", "high"], default="high")
    add.set_defaults(func=command_add)

    close_task = subparsers.add_parser("close-task", help="Record a task-end reflection and refresh retrieval artifacts")
    close_task.add_argument("--task", required=True)
    close_task.add_argument("--summary", required=True)
    close_task.add_argument("--result", choices=["success", "partial", "fail"], required=True)
    close_task.add_argument("--title", default="")
    close_task.add_argument("--project", default="")
    close_task.add_argument("--changes", default="")
    close_task.add_argument("--lessons", default="")
    close_task.add_argument("--next-step", default="")
    close_task.add_argument("--confidence", choices=["low", "medium", "high"], default="high")
    close_task.set_defaults(func=command_close_task)

    return parser


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
