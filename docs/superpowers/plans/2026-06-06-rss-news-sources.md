# RSS News Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace WebSearch-based news gathering with a curated set of RSS feeds, so the daily digest pulls focused, non-repetitive headlines from high-quality outlets and never repeats a story within 7 days.

**Architecture:** A new `fetch_feeds.py` reads a user-editable `feeds.txt`, fetches each feed with `feedparser`, filters to a recent time window, drops any URL already sent in the last 7 days (tracked in `state/seen_urls.json`), and prints a candidate list. `run_ai_news.sh` injects that list into the prompt; Claude only selects/translates (no WebSearch). After a successful send, the chosen article URLs are recorded back into `seen_urls.json`.

**Tech Stack:** Python 3 (stdlib + `feedparser`), `pytest` for tests, zsh shell script, existing Gmail SMTP sender.

---

## File Structure

- Create: `feeds.txt` — user-editable feed list (`<URL> \t <display name>`, `#` comments).
- Create: `fetch_feeds.py` — feed fetching, time-window filter, dedup, candidate formatting, and a `record` mode to persist sent URLs. Pure functions are unit-tested; the network fetch is thin.
- Create: `requirements.txt` — `feedparser`.
- Create: `tests/conftest.py` — puts repo root on `sys.path`.
- Create: `tests/test_fetch_feeds.py` — unit tests for the pure functions.
- Modify: `run_ai_news.sh` — call `fetch_feeds.py collect`, inject candidates into the prompt, drop WebSearch tools, record sent URLs after success.
- Modify: `prompt.txt`, `prompt_weekly.txt`, `prompt_monthly.txt` — select-from-candidates instructions + new output order (English primary, Chinese secondary).
- Modify: `install.sh` — install the `feedparser` dependency.
- State (gitignored, not committed): `state/seen_urls.json`.

---

## Task 1: Install dependencies

**Files:**
- Create: `requirements.txt`

- [ ] **Step 1: Create `requirements.txt`**

```
feedparser>=6.0
```

- [ ] **Step 2: Install feedparser and pytest for the project's Python**

Run:
```bash
/opt/homebrew/bin/python3 -m pip install --user --break-system-packages feedparser pytest
```
Expected: ends with `Successfully installed feedparser-… pytest-…` (or "Requirement already satisfied").
Note: `--break-system-packages` is required because Homebrew's Python 3.14 is an "externally-managed" environment; `--user` keeps it in the per-user site so the same interpreter picks it up.

- [ ] **Step 3: Verify both import**

Run:
```bash
/opt/homebrew/bin/python3 -c "import feedparser, pytest; print('ok', feedparser.__version__)"
```
Expected: `ok 6.0.x`

- [ ] **Step 4: Commit**

```bash
git add requirements.txt
git commit -m "chore: 新增 feedparser 依賴 (requirements.txt)"
```

---

## Task 2: Test harness + `load_feeds()`

**Files:**
- Create: `tests/conftest.py`
- Create: `tests/test_fetch_feeds.py`
- Create: `fetch_feeds.py`

- [ ] **Step 1: Create `tests/conftest.py`**

```python
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
```

- [ ] **Step 2: Write the failing test for `load_feeds`**

Create `tests/test_fetch_feeds.py`:

```python
import fetch_feeds


def test_load_feeds_parses_tab_pipe_and_skips_comments(tmp_path):
    p = tmp_path / "feeds.txt"
    p.write_text(
        "# a comment\n"
        "\n"
        "https://a.com/feed\tSite A\n"
        "https://b.com/feed | Site B\n"
        "https://c.com/feed\n",
        encoding="utf-8",
    )
    feeds = fetch_feeds.load_feeds(str(p))
    assert feeds == [
        ("https://a.com/feed", "Site A"),
        ("https://b.com/feed", "Site B"),
        ("https://c.com/feed", ""),
    ]
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'fetch_feeds'` (or `AttributeError: load_feeds`).

- [ ] **Step 4: Create `fetch_feeds.py` with imports and `load_feeds`**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""從 feeds.txt 抓 RSS/Atom，過濾時間窗、對已寄 URL 去重，輸出候選新聞清單。
另有 record 模式：把實際寄出的 URL 記入 state/seen_urls.json。
"""
import os
import re
import sys
import json
import socket
import argparse
from datetime import datetime, timezone, timedelta

import feedparser


def load_feeds(path):
    """讀 feeds.txt，每行 `<URL>` 後接 tab 或 | 與顯示名稱；# 開頭與空行略過。"""
    feeds = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "\t" in line:
                url, _, name = line.partition("\t")
            elif "|" in line:
                url, _, name = line.partition("|")
            else:
                url, name = line, ""
            feeds.append((url.strip(), name.strip()))
    return feeds
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add fetch_feeds.py tests/conftest.py tests/test_fetch_feeds.py
git commit -m "feat: fetch_feeds 解析 feeds.txt (load_feeds)"
```

---

## Task 3: `normalize_url()`

**Files:**
- Modify: `fetch_feeds.py`
- Test: `tests/test_fetch_feeds.py`

- [ ] **Step 1: Add the failing test**

Append to `tests/test_fetch_feeds.py`:

```python
def test_normalize_url_strips_fragment_trailing_slash_and_space():
    assert fetch_feeds.normalize_url("  https://x.com/a/  ") == "https://x.com/a"
    assert fetch_feeds.normalize_url("https://x.com/a#section") == "https://x.com/a"
    assert fetch_feeds.normalize_url("https://x.com/a") == "https://x.com/a"
```

- [ ] **Step 2: Run to confirm it fails**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py::test_normalize_url_strips_fragment_trailing_slash_and_space -v`
Expected: FAIL — `AttributeError: module 'fetch_feeds' has no attribute 'normalize_url'`.

- [ ] **Step 3: Implement `normalize_url`**

Add to `fetch_feeds.py`:

```python
def normalize_url(url):
    """去重用的 URL 正規化：去頭尾空白、去 #fragment、去尾端斜線。"""
    url = url.strip().split("#", 1)[0]
    if url.endswith("/"):
        url = url[:-1]
    return url
```

- [ ] **Step 4: Run to confirm it passes**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -v`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add fetch_feeds.py tests/test_fetch_feeds.py
git commit -m "feat: fetch_feeds 新增 normalize_url 去重正規化"
```

---

## Task 4: Time helpers — `entry_datetime()` and `within_window()`

**Files:**
- Modify: `fetch_feeds.py`
- Test: `tests/test_fetch_feeds.py`

- [ ] **Step 1: Add failing tests**

Append to `tests/test_fetch_feeds.py`:

```python
import time
from datetime import datetime, timezone


def test_entry_datetime_from_published_parsed():
    st = time.strptime("2026-06-06 10:00:00", "%Y-%m-%d %H:%M:%S")
    entry = {"published_parsed": st}
    dt = fetch_feeds.entry_datetime(entry)
    assert dt == datetime(2026, 6, 6, 10, 0, 0, tzinfo=timezone.utc)


def test_entry_datetime_none_when_missing():
    assert fetch_feeds.entry_datetime({}) is None


def test_within_window_true_inside_and_for_none():
    now = datetime(2026, 6, 6, 12, 0, 0, tzinfo=timezone.utc)
    inside = datetime(2026, 6, 5, 13, 0, 0, tzinfo=timezone.utc)   # 23h ago
    outside = datetime(2026, 6, 3, 12, 0, 0, tzinfo=timezone.utc)  # 72h ago
    assert fetch_feeds.within_window(inside, now, 48) is True
    assert fetch_feeds.within_window(outside, now, 48) is False
    assert fetch_feeds.within_window(None, now, 48) is True
```

- [ ] **Step 2: Run to confirm they fail**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -k "entry_datetime or within_window" -v`
Expected: FAIL — attributes not defined.

- [ ] **Step 3: Implement the helpers**

Add to `fetch_feeds.py`:

```python
def entry_datetime(entry):
    """從 feedparser entry 取發布時間（UTC）。沒有時間回傳 None。"""
    t = entry.get("published_parsed") or entry.get("updated_parsed")
    if not t:
        return None
    return datetime(*t[:6], tzinfo=timezone.utc)


def within_window(published, now, hours):
    """published 是否落在 now 往前 hours 小時內。published 為 None 視為符合。"""
    if published is None:
        return True
    return published >= now - timedelta(hours=hours)
```

- [ ] **Step 4: Run to confirm they pass**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -v`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add fetch_feeds.py tests/test_fetch_feeds.py
git commit -m "feat: fetch_feeds 新增時間解析與時間窗判斷"
```

---

## Task 5: Seen store — `load_seen()` and `save_seen()`

**Files:**
- Modify: `fetch_feeds.py`
- Test: `tests/test_fetch_feeds.py`

- [ ] **Step 1: Add failing tests**

Append to `tests/test_fetch_feeds.py`:

```python
import json


def test_load_seen_prunes_entries_older_than_retention(tmp_path):
    p = tmp_path / "seen.json"
    p.write_text(json.dumps({
        "https://old.com/a": "2026-05-01",
        "https://new.com/b": "2026-06-05",
    }), encoding="utf-8")
    now = datetime(2026, 6, 6, 0, 0, 0, tzinfo=timezone.utc)
    seen = fetch_feeds.load_seen(str(p), now=now, retention_days=7)
    assert seen == {"https://new.com/b": "2026-06-05"}


def test_load_seen_missing_file_returns_empty(tmp_path):
    assert fetch_feeds.load_seen(str(tmp_path / "nope.json")) == {}


def test_save_seen_merges_normalizes_and_prunes(tmp_path):
    p = tmp_path / "seen.json"
    now = datetime(2026, 6, 6, 0, 0, 0, tzinfo=timezone.utc)
    existing = {"https://old.com/a": "2026-05-01"}
    fetch_feeds.save_seen(
        str(p), ["https://new.com/b/", "https://new.com/b#frag"],
        today="2026-06-06", existing=existing, retention_days=7, now=now,
    )
    data = json.loads(p.read_text(encoding="utf-8"))
    # old pruned, new normalized to a single key
    assert data == {"https://new.com/b": "2026-06-06"}
```

- [ ] **Step 2: Run to confirm they fail**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -k "seen" -v`
Expected: FAIL — attributes not defined.

- [ ] **Step 3: Implement the seen store**

Add to `fetch_feeds.py`:

```python
def _prune(data, now, retention_days):
    cutoff = (now - timedelta(days=retention_days)).date().isoformat()
    return {u: d for u, d in data.items() if d >= cutoff}


def load_seen(path, now=None, retention_days=7):
    """讀 seen_urls.json（{url: 'YYYY-MM-DD'}）。給 now 時順手清掉過期項目。"""
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if now is None:
        return data
    return _prune(data, now, retention_days)


def save_seen(path, urls, today, existing=None, retention_days=7, now=None):
    """把 urls（正規化後）以日期 today 併入既有資料，給 now 時清掉過期項目並寫檔。"""
    data = dict(existing or {})
    for u in urls:
        data[normalize_url(u)] = today
    if now is not None:
        data = _prune(data, now, retention_days)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=0)
    return data
```

- [ ] **Step 4: Run to confirm they pass**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -v`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add fetch_feeds.py tests/test_fetch_feeds.py
git commit -m "feat: fetch_feeds 新增已寄 URL 狀態存取與過期清理"
```

---

## Task 6: `dedup_candidates()` and `format_candidates()`

**Files:**
- Modify: `fetch_feeds.py`
- Test: `tests/test_fetch_feeds.py`

- [ ] **Step 1: Add failing tests**

Append to `tests/test_fetch_feeds.py`:

```python
def _cand(title, link, source="Src", published=None, summary="s"):
    return {"title": title, "link": link, "source": source,
            "published": published, "summary": summary}


def test_dedup_candidates_removes_seen_by_normalized_url():
    seen = {"https://x.com/a": "2026-06-05"}
    cands = [_cand("A", "https://x.com/a/"), _cand("B", "https://x.com/b")]
    out = fetch_feeds.dedup_candidates(cands, seen)
    assert [c["title"] for c in out] == ["B"]


def test_format_candidates_numbers_and_includes_fields():
    cands = [_cand("Hello", "https://x.com/a",
                   published=datetime(2026, 6, 6, 10, 0, tzinfo=timezone.utc))]
    text = fetch_feeds.format_candidates(cands)
    assert "[1]" in text
    assert "title: Hello" in text
    assert "link: https://x.com/a" in text
    assert "Src" in text
```

- [ ] **Step 2: Run to confirm they fail**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -k "dedup or format" -v`
Expected: FAIL — attributes not defined.

- [ ] **Step 3: Implement both**

Add to `fetch_feeds.py`:

```python
def dedup_candidates(candidates, seen):
    """去掉 link 已出現在 seen（已寄 URL）的候選。"""
    seen_norm = {normalize_url(u) for u in seen}
    return [c for c in candidates if normalize_url(c["link"]) not in seen_norm]


def format_candidates(candidates):
    """把候選清單轉成餵給 Claude 的純文字區塊。"""
    lines = []
    for i, c in enumerate(candidates, 1):
        pub = c["published"].isoformat() if c.get("published") else "unknown"
        lines.append(f"[{i}] source={c['source']} published={pub}")
        lines.append(f"title: {c['title']}")
        summary = (c.get("summary") or "").strip()
        if summary:
            lines.append(f"summary: {summary}")
        lines.append(f"link: {c['link']}")
        lines.append("")
    return "\n".join(lines).strip()
```

- [ ] **Step 4: Run to confirm they pass**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -v`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add fetch_feeds.py tests/test_fetch_feeds.py
git commit -m "feat: fetch_feeds 新增候選去重與格式化輸出"
```

---

## Task 7: Network fetch, `gather_candidates()`, and CLI (`collect`/`record`)

**Files:**
- Modify: `fetch_feeds.py`
- Test: `tests/test_fetch_feeds.py`

- [ ] **Step 1: Add failing test for `gather_candidates` (with injected fetch, no network)**

Append to `tests/test_fetch_feeds.py`:

```python
def test_gather_candidates_filters_window_and_skips_failed_feeds():
    now = datetime(2026, 6, 6, 12, 0, 0, tzinfo=timezone.utc)
    fresh = _cand("fresh", "https://x.com/fresh",
                  published=datetime(2026, 6, 6, 6, 0, tzinfo=timezone.utc))
    stale = _cand("stale", "https://x.com/stale",
                  published=datetime(2026, 6, 1, 6, 0, tzinfo=timezone.utc))

    def fake_fetch(url, name):
        if url == "https://boom.com/feed":
            raise RuntimeError("down")
        return [fresh, stale]

    feeds = [("https://x.com/feed", "X"), ("https://boom.com/feed", "Boom")]
    out = fetch_feeds.gather_candidates(feeds, hours=48, now=now, fetch=fake_fetch)
    assert [c["title"] for c in out] == ["fresh"]
```

- [ ] **Step 2: Run to confirm it fails**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -k "gather" -v`
Expected: FAIL — `gather_candidates` not defined.

- [ ] **Step 3: Implement fetch + gather + helpers**

Add to `fetch_feeds.py`:

```python
_TAG_RE = re.compile(r"<[^>]+>")


def strip_html(text, limit=300):
    """把 RSS summary 的 HTML 標籤拿掉、壓掉多餘空白、截斷。"""
    text = _TAG_RE.sub("", text or "")
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def fetch_feed(url, name, timeout=15):
    """抓單一 feed，回傳候選 dict 清單。網路/解析錯誤由呼叫端 try/except 處理。"""
    socket.setdefaulttimeout(timeout)
    parsed = feedparser.parse(url)
    source = name or parsed.feed.get("title", url)
    items = []
    for e in parsed.entries:
        link = (e.get("link") or "").strip()
        title = (e.get("title") or "").strip()
        if not link or not title:
            continue
        items.append({
            "title": title,
            "link": link,
            "summary": strip_html(e.get("summary") or e.get("description") or ""),
            "published": entry_datetime(e),
            "source": source,
        })
    return items


def gather_candidates(feeds, hours, now, fetch=fetch_feed):
    """抓所有 feed、過濾時間窗；單一 feed 失敗只記 log 並跳過。"""
    items = []
    for url, name in feeds:
        try:
            items.extend(fetch(url, name))
        except Exception as e:  # noqa: BLE001 - 任一 feed 壞掉都不該中斷整批
            print(f"WARN: feed 失敗 {url}: {e!r}", file=sys.stderr)
    return [c for c in items if within_window(c.get("published"), now, hours)]
```

- [ ] **Step 4: Run to confirm it passes**

Run: `/opt/homebrew/bin/python3 -m pytest tests/test_fetch_feeds.py -v`
Expected: PASS (11 tests).

- [ ] **Step 5: Add the CLI (`collect` default + `record`)**

Add to the end of `fetch_feeds.py`:

```python
def cmd_collect(args):
    now = datetime.now(timezone.utc)
    feeds = load_feeds(args.feeds)
    seen = load_seen(args.seen, now=now, retention_days=args.retention_days)

    cands = dedup_candidates(gather_candidates(feeds, args.hours, now), seen)
    if len(cands) < args.min:
        print(f"INFO: 時間窗 {args.hours}h 僅 {len(cands)} 則 < {args.min}，"
              f"放寬到 {args.widen}h。", file=sys.stderr)
        cands = dedup_candidates(gather_candidates(feeds, args.widen, now), seen)

    cands.sort(key=lambda c: c.get("published") or now, reverse=True)
    if not cands:
        print("ERROR: 去重後沒有任何候選新聞。", file=sys.stderr)
        sys.exit(3)
    print(format_candidates(cands))


def cmd_record(args):
    now = datetime.now(timezone.utc)
    today = now.date().isoformat()
    urls = [ln.strip() for ln in sys.stdin if ln.strip()]
    existing = load_seen(args.seen)
    save_seen(args.seen, urls, today, existing=existing,
              retention_days=args.retention_days, now=now)
    print(f"INFO: 已記錄 {len(urls)} 筆已寄 URL 到 {args.seen}", file=sys.stderr)


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="RSS 候選新聞抓取/已寄記錄")
    ap.add_argument("mode", nargs="?", default="collect",
                    choices=["collect", "record"])
    ap.add_argument("--feeds", default=os.path.join(here, "feeds.txt"))
    ap.add_argument("--seen", default=os.path.join(here, "state", "seen_urls.json"))
    ap.add_argument("--hours", type=int, default=48)
    ap.add_argument("--widen", type=int, default=72)
    ap.add_argument("--min", type=int, default=10)
    ap.add_argument("--retention-days", type=int, default=7)
    args = ap.parse_args(argv)
    (cmd_record if args.mode == "record" else cmd_collect)(args)


if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Smoke-test the CLI end to end with a tiny temp feed list (uses a real, stable feed)**

Run:
```bash
printf 'https://techcrunch.com/category/artificial-intelligence/feed/\tTechCrunch\n' > /tmp/feeds_smoke.txt
/opt/homebrew/bin/python3 fetch_feeds.py collect --feeds /tmp/feeds_smoke.txt --seen /tmp/seen_smoke.json --hours 168 --min 1
```
Expected: a numbered candidate list (`[1] source=TechCrunch …`). If the feed URL is dead, note it and pick the working replacement during Task 8.

- [ ] **Step 7: Commit**

```bash
git add fetch_feeds.py tests/test_fetch_feeds.py
git commit -m "feat: fetch_feeds 完成抓取、彙整與 collect/record CLI"
```

---

## Task 8: Build and verify `feeds.txt`

**Files:**
- Create: `feeds.txt`

- [ ] **Step 1: Create `feeds.txt` with the agreed sources**

```
# AI News Digest 來源清單（一行一個）：<URL> <tab 或 |> 顯示名稱；# 為註解。
# 增減來源直接改這個檔，不用動程式。

# ── 主流科技新聞 ──
https://techcrunch.com/category/artificial-intelligence/feed/	TechCrunch
https://www.theverge.com/rss/ai-artificial-intelligence/index.xml	The Verge
https://venturebeat.com/category/ai/feed/	VentureBeat

# ── 深度科技媒體 ──
https://feeds.arstechnica.com/arstechnica/index	Ars Technica
https://www.wired.com/feed/tag/ai/latest/rss	Wired
https://www.technologyreview.com/feed/	MIT Technology Review

# ── 官方源頭 ──
https://openai.com/news/rss.xml	OpenAI
https://www.anthropic.com/rss.xml	Anthropic
https://deepmind.google/blog/rss.xml	Google DeepMind

# ── 中文 / 亞洲 AI 源 ──
https://www.jiqizhixin.com/rss	機器之心
https://www.ithome.com.tw/rss	iThome
```

- [ ] **Step 2: Verify each feed actually fetches; comment out any dead ones**

Run:
```bash
/opt/homebrew/bin/python3 - <<'PY'
import feedparser, socket
socket.setdefaulttimeout(15)
with open("feeds.txt", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        url = line.replace("|", "\t").split("\t", 1)[0].strip()
        d = feedparser.parse(url)
        print(f"{len(d.entries):>3} entries  bozo={int(bool(d.bozo))}  {url}")
PY
```
Expected: each line shows a positive entry count and `bozo=0`. For any feed showing `0 entries` or `bozo=1` (404/parse error), prefix that line in `feeds.txt` with `# DEAD: ` and, if a known-good replacement exists, add it. Do not leave dead feeds active.

- [ ] **Step 3: Confirm the full list collects candidates**

Run:
```bash
/opt/homebrew/bin/python3 fetch_feeds.py collect --feeds feeds.txt --seen /tmp/seen_check.json --hours 72 --min 1 | head -30
```
Expected: a numbered candidate list spanning multiple sources.

- [ ] **Step 4: Commit**

```bash
git add feeds.txt
git commit -m "feat: 新增 feeds.txt 來源清單（已驗證可抓）"
```

---

## Task 9: Rewrite the prompts (select-from-candidates + new output order)

**Files:**
- Modify: `prompt.txt`
- Modify: `prompt_weekly.txt`
- Modify: `prompt_monthly.txt`

- [ ] **Step 1: Replace `prompt.txt` contents**

```
你是 AI 新聞簡報產生器。本提示之後會附上一份「候選新聞清單」——那是從多家可信媒體 RSS 直接抓來的最新項目（含來源 source、發布時間 published、原文標題 title、原文簡介 summary、連結 link）。請「只輸出最終 HTML 內文」，不要輸出任何解說、前言、結語或 markdown 圍欄（不要 ```html）。

【步驟 1：挑選】
只能從候選清單中挑出「最相關、最重要」的 10 則：
- 主題多元，避免 10 則都同一家公司或同一則事件；同一事件只留最具代表性的一則
- 依重要性排序，較新的優先
- 嚴禁自行編造或加入清單以外的新聞；連結一律使用候選項目提供的 link
- 若候選不足 10 則，就有幾則做幾則

【步驟 2：輸出 HTML】
只輸出一段 HTML 內文（從 <div> 開始即可，不需要 <html>/<head>）。最上方放一行日期標題。每則新聞編號，順序為「英文主、中文副」：
- English title（粗體、主視覺）
- 繁體中文標題（小字、灰色）
- English summary（1～2 句）
- 繁體中文摘要（1～2 句，小字）
- 來源名稱與原文連結（<a href>）

排版用簡潔的 inline style，確保在 Gmail 中可讀。再次強調：輸出內容只能是 HTML 本身，開頭就是 HTML 標籤，不要有任何其他文字。
```

- [ ] **Step 2: Replace `prompt_weekly.txt` contents**

```
你是 AI 新聞「每週回顧」簡報產生器。本提示之後會附上一份「候選新聞清單」——那是從多家可信媒體 RSS 抓來的近一週項目（含來源 source、發布時間 published、原文標題 title、原文簡介 summary、連結 link）。請「只輸出最終 HTML 內文」，不要任何解說、前言、結語或 markdown 圍欄。

【步驟 1：挑選】
只能從候選清單中挑出本週「最重要、最具代表性」的 10 則：
- 主題多元，避免集中在同一家公司或同一事件；同一事件只留最具代表性的一則
- 依重要性排序
- 嚴禁自行編造或加入清單以外的新聞；連結一律使用候選項目提供的 link
- 若候選不足 10 則，就有幾則做幾則

【步驟 2：輸出 HTML】
只輸出一段 HTML 內文（從 <div> 開始）。最上方放一行「本週 AI 新聞回顧」與日期區間標題。每則編號，順序為「英文主、中文副」：
- English title（粗體、主視覺）
- 繁體中文標題（小字、灰色）
- English summary（1～2 句）
- 繁體中文摘要（1～2 句，小字）
- 來源名稱與原文連結（<a href>）

排版用簡潔 inline style，確保 Gmail 可讀。輸出只能是 HTML 本身，開頭就是 HTML 標籤。
```

- [ ] **Step 3: Replace `prompt_monthly.txt` contents**

```
你是 AI 新聞「每月回顧」簡報產生器。本提示之後會附上一份「候選新聞清單」——那是從多家可信媒體 RSS 抓來的近一個月項目（含來源 source、發布時間 published、原文標題 title、原文簡介 summary、連結 link）。請「只輸出最終 HTML 內文」，不要任何解說、前言、結語或 markdown 圍欄。

【步驟 1：挑選】
只能從候選清單中挑出本月「最重要、最具里程碑意義」的 10 則：
- 主題多元，避免集中在同一家公司或同一事件；同一事件只留最具代表性的一則
- 依重要性排序
- 嚴禁自行編造或加入清單以外的新聞；連結一律使用候選項目提供的 link
- 若候選不足 10 則，就有幾則做幾則

【步驟 2：輸出 HTML】
只輸出一段 HTML 內文（從 <div> 開始）。最上方放一行「本月 AI 新聞回顧」與月份標題。每則編號，順序為「英文主、中文副」：
- English title（粗體、主視覺）
- 繁體中文標題（小字、灰色）
- English summary（1～2 句）
- 繁體中文摘要（1～2 句，小字）
- 來源名稱與原文連結（<a href>）

排版用簡潔 inline style，確保 Gmail 可讀。輸出只能是 HTML 本身，開頭就是 HTML 標籤。
```

- [ ] **Step 4: Commit**

```bash
git add prompt.txt prompt_weekly.txt prompt_monthly.txt
git commit -m "change: prompt 改為從 RSS 候選清單挑選，英文主中文副排版"
```

---

## Task 10: Wire `run_ai_news.sh` to feeds + record sent URLs

**Files:**
- Modify: `run_ai_news.sh`

- [ ] **Step 1: Add feed/seen paths and a per-KIND time window**

In `run_ai_news.sh`, after the existing line `KIND="${3:-daily}"` (currently line 32), insert:

```bash
# ── RSS 來源與已寄狀態 ──
FEEDS_FILE="$DIR/feeds.txt"
SEEN_FILE="$STATE_DIR/seen_urls.json"
case "$KIND" in
  weekly)  FEED_HOURS=168;  FEED_WIDEN=240 ;;   # 7 天 → 放寬 10 天
  monthly) FEED_HOURS=720;  FEED_WIDEN=1080 ;;  # 30 天 → 放寬 45 天
  *)       FEED_HOURS=48;   FEED_WIDEN=72 ;;     # 每日 48h → 放寬 72h
esac
```

- [ ] **Step 2: Drop WebSearch from `run_claude`**

In `run_ai_news.sh`, the `run_claude` function currently runs (around lines 82-86):

```bash
  "$CLAUDE" -p "$PROMPT" \
    --model "$MODEL" \
    --allowedTools WebSearch WebFetch \
    --permission-mode default \
    --output-format text > "$outfile" 2>>"$LOG" &
```

Replace with (remove the `--allowedTools` line — Claude now only selects from the injected candidates):

```bash
  "$CLAUDE" -p "$PROMPT" \
    --model "$MODEL" \
    --permission-mode default \
    --output-format text > "$outfile" 2>>"$LOG" &
```

- [ ] **Step 3: Fetch candidates and inject them into the prompt inside the retry loop**

In `run_ai_news.sh`, the base prompt is currently read once before the loop (line 107: `PROMPT="$(cat "$DIR/$PROMPT_FILE")"`). Change it so the base prompt is read once, but candidates are fetched each attempt (after network is confirmed) and appended.

Replace line 107:

```bash
PROMPT="$(cat "$DIR/$PROMPT_FILE")"
```

with:

```bash
BASE_PROMPT="$(cat "$DIR/$PROMPT_FILE")"
```

Then inside the `while` loop, right after the `if ! wait_for_network; then break; fi` line (currently line 113), insert:

```bash
  CANDIDATES="$("$PYTHON" "$DIR/fetch_feeds.py" collect \
      --feeds "$FEEDS_FILE" --seen "$SEEN_FILE" \
      --hours "$FEED_HOURS" --widen "$FEED_WIDEN" --min 10 2>>"$LOG")"
  if [ $? -ne 0 ] || [ -z "$CANDIDATES" ]; then
    log "WARN: 第 $attempt/$MAX_TRIES 次抓 RSS 候選失敗或為空，30s 後重試。"
    attempt=$((attempt+1)); [ $attempt -le $MAX_TRIES ] && sleep 30
    continue
  fi
  PROMPT="$BASE_PROMPT"$'\n\n=== 候選新聞清單（只能從這裡面挑）===\n'"$CANDIDATES"
```

(The existing `run_claude "$TMP_OUT"; crc=$?` line and everything after it stays as-is; `run_claude` still reads the global `$PROMPT`.)

- [ ] **Step 4: Record the sent article URLs after a successful send**

In `run_ai_news.sh`, the success branch currently is (around lines 137-139):

```bash
if [ $RC -eq 0 ]; then
  date '+%Y-%m-%d %H:%M:%S' > "$MARKER"
  log "INFO: 已寄出並標記 $(basename "$MARKER")。"
```

Insert the URL-recording step immediately after the `date ... > "$MARKER"` line, before the `log` line:

```bash
  # 把這次信中實際出現的文章連結記入已寄清單，供跨日去重
  print -r -- "$HTML" \
    | grep -oE 'href="https?://[^"]+"' \
    | sed -E 's/^href="//; s/"$//' \
    | "$PYTHON" "$DIR/fetch_feeds.py" record --seen "$SEEN_FILE" 2>>"$LOG"
```

- [ ] **Step 5: Lint the script for syntax**

Run: `zsh -n run_ai_news.sh`
Expected: no output (exit 0). If `zsh -n` reports an error, fix the edited block before continuing.

- [ ] **Step 6: Commit**

```bash
git add run_ai_news.sh
git commit -m "feat: run 腳本改用 RSS 候選清單並寄後記錄已寄 URL 去重"
```

---

## Task 11: Install dependency in `install.sh`

**Files:**
- Modify: `install.sh`

- [ ] **Step 1: Add a feedparser install step after Python detection**

In `install.sh`, after the line `say "python3 -> ${PYTHON_BIN:-未偵測到}"` (currently line 27), insert:

```bash

# ── 1b. 安裝 Python 依賴（feedparser）──
if [ -n "$PYTHON_BIN" ]; then
  if "$PYTHON_BIN" -c "import feedparser" >/dev/null 2>&1; then
    ok "feedparser 已安裝"
  else
    say "安裝 feedparser…"
    "$PYTHON_BIN" -m pip install --user --break-system-packages feedparser \
      && ok "feedparser 安裝完成" \
      || warn "feedparser 安裝失敗，請手動執行：$PYTHON_BIN -m pip install --user --break-system-packages feedparser"
  fi
fi
```

- [ ] **Step 2: Lint the script**

Run: `bash -n install.sh`
Expected: no output (exit 0).

- [ ] **Step 3: Commit**

```bash
git add install.sh
git commit -m "chore: install.sh 自動安裝 feedparser 依賴"
```

---

## Task 12: End-to-end dry run (no email) + first real send

**Files:** none (verification only)

- [ ] **Step 1: Confirm the full test suite passes**

Run: `/opt/homebrew/bin/python3 -m pytest tests/ -v`
Expected: all tests PASS (11).

- [ ] **Step 2: Generate the digest HTML without sending, and eyeball it**

Run:
```bash
CANDS="$(/opt/homebrew/bin/python3 fetch_feeds.py collect --feeds feeds.txt --seen state/seen_urls.json --hours 48 --widen 72 --min 10)"
printf '%s\n\n=== 候選新聞清單（只能從這裡面挑）===\n%s\n' "$(cat prompt.txt)" "$CANDS" \
  | "$HOME/.local/bin/claude" -p --model sonnet --permission-mode default --output-format text \
  > /tmp/digest_preview.html
open /tmp/digest_preview.html
```
Expected: a 10-item digest where each item shows English title first (bold), Chinese subtitle below, both summaries, source + working link; no duplicate stories; every source appears in `feeds.txt`.

- [ ] **Step 2b: Confirm Claude only used candidate links**

Run:
```bash
grep -oE 'href="https?://[^"]+"' /tmp/digest_preview.html | sed -E 's/^href="//; s/"$//' | sort -u
```
Expected: every host belongs to a source in `feeds.txt`. If a link is from outside the list, tighten the "嚴禁自行編造" wording in `prompt.txt` and regenerate.

- [ ] **Step 3: Real run through the actual pipeline (sends an email)**

> This sends a real email and writes `state/seen_urls.json` + the daily marker. Run only when the preview looks right.

Run:
```bash
rm -f state/daily-$(date +%F)   # clear today's marker so it actually runs
./run_ai_news.sh
```
Expected in `run.log`: `INFO: 第 1 次嘗試成功` then `OK: 寄送成功`. Check the inbox for the new format.

- [ ] **Step 4: Verify dedup was recorded**

Run: `/opt/homebrew/bin/python3 -c "import json; d=json.load(open('state/seen_urls.json')); print(len(d), 'urls recorded'); [print(k) for k in list(d)[:5]]"`
Expected: ~10 URLs recorded with today's date. These will be excluded on the next run.

- [ ] **Step 5: Final commit (if any tweaks were made during verification)**

```bash
git add -A
git commit -m "test: 端到端驗證 RSS 來源信件並調整"
```

---

## Self-Review Notes

- **Spec coverage:** RSS architecture (Tasks 7-8, 10), feeds.txt user-editable list (Task 8), 48h window + widen-to-72h (Tasks 7, 10), 7-day URL dedup recorded after success (Tasks 5, 10), output format English-primary/Chinese-secondary + 1-2 sentence summaries (Task 9), per-feed failure tolerance (Task 7), empty-candidate failure handed to existing retry/補跑 (Tasks 7, 10), weekly/monthly windows (Tasks 9, 10), feedparser dependency (Tasks 1, 11), preserves marker/network/retry/notify mechanisms (Task 10 leaves them untouched). All covered.
- **Naming consistency:** `load_feeds`, `normalize_url`, `entry_datetime`, `within_window`, `load_seen`, `save_seen`, `dedup_candidates`, `format_candidates`, `gather_candidates`, `fetch_feed`, `cmd_collect`, `cmd_record` — used consistently across tasks and tests. CLI modes `collect`/`record` and flags `--feeds/--seen/--hours/--widen/--min/--retention-days` match between `fetch_feeds.py` (Task 7) and `run_ai_news.sh` (Task 10).
- **Open risk:** the exact feed URLs in Task 8 are best-effort and explicitly validated in Task 8 Step 2 (dead ones get commented out / replaced), so a stale URL won't silently break the pipeline.
