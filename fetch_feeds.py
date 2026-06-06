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

FETCH_TIMEOUT = 15
_OLDEST = datetime(1970, 1, 1, tzinfo=timezone.utc)


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


def normalize_url(url):
    """去重用的 URL 正規化：去頭尾空白、去 #fragment、去尾端斜線。"""
    url = url.strip().split("#", 1)[0]
    if url.endswith("/"):
        url = url[:-1]
    return url


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


def _prune(data, now, retention_days):
    cutoff = (now - timedelta(days=retention_days)).date().isoformat()
    return {u: d for u, d in data.items() if d >= cutoff}


def load_seen(path, now=None, retention_days=7):
    """讀 seen_urls.json（{url: 'YYYY-MM-DD'}）。給 now 時順手清掉過期項目。"""
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, ValueError, OSError) as e:
        print(f"WARN: 讀取 {path} 失敗（視為空）：{e!r}", file=sys.stderr)
        return {}
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


_TAG_RE = re.compile(r"<[^>]+>")


def strip_html(text, limit=300):
    """把 RSS summary 的 HTML 標籤拿掉、壓掉多餘空白、截斷。"""
    text = _TAG_RE.sub("", text or "")
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit]


def fetch_feed(url, name):
    """抓單一 feed，回傳候選 dict 清單。網路/解析錯誤由呼叫端 try/except 處理。"""
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


def cmd_collect(args):
    now = datetime.now(timezone.utc)
    feeds = load_feeds(args.feeds)
    seen = load_seen(args.seen, now=now, retention_days=args.retention_days)

    wide = dedup_candidates(gather_candidates(feeds, args.widen, now), seen)
    narrow = [c for c in wide if within_window(c.get("published"), now, args.hours)]
    if len(narrow) < args.min:
        print(f"INFO: 時間窗 {args.hours}h 僅 {len(narrow)} 則 < {args.min}，"
              f"放寬到 {args.widen}h。", file=sys.stderr)
        cands = wide
    else:
        cands = narrow

    cands.sort(key=lambda c: c.get("published") or _OLDEST, reverse=True)
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
    socket.setdefaulttimeout(FETCH_TIMEOUT)
    (cmd_record if args.mode == "record" else cmd_collect)(args)


if __name__ == "__main__":
    main()
