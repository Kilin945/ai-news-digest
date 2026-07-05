#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""每日 AI 新聞的 outbox 存取（state 分支上的「有稿待寄」憑證）。

本機 prepare 產稿後寫入 outbox，雲端 daily-send.yml 寄出前驗證、寄出後清除。
outbox 帶產稿日期：ai-news 是「當天抓當天寄」，只有今天的稿才算備妥，
過期稿（昨天備了但一直沒寄成）一律視為不可寄，避免寄舊聞。

state 目錄來源：環境變數 AI_NEWS_STATE_DIR，預設同目錄 state/
（本機由 run_ai_news.sh 指向 ../ai-news-state/state；雲端靠 symlink 用預設值）。

用法：
  print html | python3 outbox.py --to-outbox   # 存稿（蓋今天日期）
  python3 outbox.py --ready                    # 今天的稿備妥了？(exit 0/1)
  python3 outbox.py --html                     # 取稿，標題日期蓋成今天
  python3 outbox.py --urls                     # 列出稿內文章連結（記已寄用）
  python3 outbox.py --clear                    # 寄出後清除
"""
import datetime
import json
import os
import re
import sys

STATE_DIR = os.environ.get("AI_NEWS_STATE_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "state")
OUTBOX = os.path.join(STATE_DIR, "outbox.json")

# 稿通常當天早上備、緊接著寄，但補寄班次可能跨到中午；寄出時一律蓋成寄出當天。
_TITLE_DATE = re.compile(r"(每日 AI 新聞 Top 10 · )\d{4}-\d{2}-\d{2}")
_HREF = re.compile(r"href=['\"](https?://[^'\"]+)['\"]")


def _today() -> str:
    return datetime.date.today().isoformat()


def _load() -> dict:
    try:
        with open(OUTBOX, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _strip_fence(text: str) -> str:
    """去掉 claude 偶爾包的 ```html ... ``` 圍欄。"""
    stripped = text.strip()
    if not stripped.startswith("```"):
        return text
    lines = stripped.splitlines()
    if lines and lines[0].startswith("```"):
        lines = lines[1:]
    if lines and lines[-1].strip().startswith("```"):
        lines = lines[:-1]
    return "\n".join(lines)


def to_outbox() -> int:
    html = _strip_fence(sys.stdin.read())
    if "<" not in html:
        print("ERROR: stdin 不像 HTML，拒絕寫入 outbox。", file=sys.stderr)
        return 1
    os.makedirs(STATE_DIR, exist_ok=True)
    data = {"kind": "daily", "date": _today(), "html": html}
    with open(OUTBOX, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    print(f"OK: outbox 已備妥（{data['date']}，{len(html)} 字元）。")
    return 0


def ready() -> int:
    box = _load()
    if not box.get("html"):
        print("outbox 不存在或無內容。", file=sys.stderr)
        return 1
    if box.get("date") != _today():
        print(f"outbox 是 {box.get('date')} 的過期稿，不可寄。", file=sys.stderr)
        return 1
    return 0


def restamp_send_date(html: str, today: str) -> str:
    return _TITLE_DATE.sub(lambda m: m.group(1) + today, html, count=1)


def emit_html() -> int:
    box = _load()
    if not box.get("html"):
        print("ERROR: outbox 無內容。", file=sys.stderr)
        return 1
    sys.stdout.write(restamp_send_date(box["html"], _today()))
    return 0


def emit_urls() -> int:
    box = _load()
    for url in _HREF.findall(box.get("html", "")):
        print(url)
    return 0


def clear() -> int:
    try:
        os.remove(OUTBOX)
    except FileNotFoundError:
        pass
    print("OK: outbox 已清除。")
    return 0


def main() -> int:
    actions = {
        "--to-outbox": to_outbox,
        "--ready": ready,
        "--html": emit_html,
        "--urls": emit_urls,
        "--clear": clear,
    }
    if len(sys.argv) != 2 or sys.argv[1] not in actions:
        print(__doc__, file=sys.stderr)
        return 2
    return actions[sys.argv[1]]()


if __name__ == "__main__":
    sys.exit(main())
