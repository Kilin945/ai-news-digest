#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AI 新聞 outbox：本機備稿的存放處，雲端寄出前來這裡取。

三種週期都走同一條路——本機只備稿、雲端只寄出，本機不再直接寄任何信：

    週期    備稿日                寄出日（雲端 14:00）   outbox 檔
    daily   當天                  當天                   outbox-daily.json
    weekly  週六（週日可補備）    週日                   outbox-weekly.json
    monthly 當月倒數第二天        當月最後一天           outbox-monthly.json
            （最後一天可補備）

備稿與寄出分屬不同天，所以「這份稿還算不算數」不能比日期，要比**週期代號**
（period key）：daily 比日期、weekly 比 ISO 週、monthly 比年月。備稿日與寄出日
刻意落在同一個週期內，所以前一天備的稿在隔天寄仍然有效；但上一個週期的舊稿
（例如上週六備了卻一直沒寄成）代號對不上，一律拒寄，不會寄出過期內容。

state 目錄來源：環境變數 AI_NEWS_STATE_DIR，預設同目錄 state/
（本機由 run_ai_news.sh 指向 ../ai-news-state/state；雲端靠 symlink 用預設值）。

用法：
  print html | python3 outbox.py --to-outbox KIND   # 存稿（蓋上本週期代號）
  python3 outbox.py --ready      KIND               # 本週期的稿備妥了？(exit 0/1)
  python3 outbox.py --html       KIND               # 取稿（daily 會把標題日期蓋成今天）
  python3 outbox.py --urls       KIND               # 列出稿內文章連結（記已寄用）
  python3 outbox.py --clear      KIND               # 寄出後清除
  python3 outbox.py --prep-due   KIND               # 今天該備這種稿嗎？(exit 0/1)
  python3 outbox.py --send-due   KIND               # 今天該寄這種稿嗎？(exit 0/1)
  python3 outbox.py --due-kinds                     # 印出今天該寄的所有週期
  python3 outbox.py --period-key KIND               # 印出本週期代號
"""
import datetime
import json
import os
import re
import sys

KINDS = ("daily", "weekly", "monthly")

STATE_DIR = os.environ.get("AI_NEWS_STATE_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "state")

# 只有每日信的標題寫死日期，寄出時蓋成寄出當天（備稿與寄出同一天，純粹防補跑跨日）。
# 週報標題是日期區間、月報標題是月份，都由 claude 依備稿日產生，前一天備的仍然正確。
_TITLE_DATE = re.compile(r"(每日 AI 新聞 Top 10 · )\d{4}-\d{2}-\d{2}")
_HREF = re.compile(r"href=['\"](https?://[^'\"]+)['\"]")


def outbox_path(kind: str) -> str:
    return os.path.join(STATE_DIR, f"outbox-{kind}.json")


# ── 日期判斷 ──────────────────────────────────────────────────
# 「當月最後一天」沒辦法用固定日期表示（31 號在小月不存在、2 月更短），
# 一律用「明天是不是 1 號」來判斷，任何月份長度都成立。

def is_last_day_of_month(d: datetime.date) -> bool:
    return (d + datetime.timedelta(days=1)).day == 1


def is_second_last_day_of_month(d: datetime.date) -> bool:
    return (d + datetime.timedelta(days=2)).day == 1


def period_key(kind: str, d: datetime.date) -> str:
    """本週期的代號。備稿日與寄出日算出來必須一致，稿才算數。"""
    if kind == "weekly":
        return d.strftime("%G-W%V")      # ISO 週：週一起算，故週六與週日同週
    if kind == "monthly":
        return d.strftime("%Y-%m")       # 倒數第二天與最後一天必定同月
    return d.isoformat()


def is_prep_due(kind: str, d: datetime.date) -> bool:
    """今天該備這種稿嗎？寄出日當天也允許補備，讓失敗的週期還有第二次機會。"""
    if kind == "weekly":
        return d.weekday() in (5, 6)     # 週六備、週日補備
    if kind == "monthly":
        return is_second_last_day_of_month(d) or is_last_day_of_month(d)
    return True


def is_send_due(kind: str, d: datetime.date) -> bool:
    """今天該寄這種稿嗎？寄在週期的最後一天，內容才涵蓋完整週期。"""
    if kind == "weekly":
        return d.weekday() == 6          # 週日
    if kind == "monthly":
        return is_last_day_of_month(d)
    return True


# ── outbox 存取 ───────────────────────────────────────────────

def _today() -> datetime.date:
    return datetime.date.today()


def _load(kind: str) -> dict:
    try:
        with open(outbox_path(kind), encoding="utf-8") as f:
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


def to_outbox(kind: str) -> int:
    html = _strip_fence(sys.stdin.read())
    if "<" not in html:
        print("ERROR: stdin 不像 HTML，拒絕寫入 outbox。", file=sys.stderr)
        return 1
    os.makedirs(STATE_DIR, exist_ok=True)
    today = _today()
    data = {
        "kind": kind,
        "period": period_key(kind, today),
        "prepared_on": today.isoformat(),
        "html": html,
    }
    with open(outbox_path(kind), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    print(f"OK: {kind} outbox 已備妥（週期 {data['period']}，{len(html)} 字元）。")
    return 0


def ready(kind: str) -> int:
    box = _load(kind)
    if not box.get("html"):
        print(f"{kind} outbox 不存在或無內容。", file=sys.stderr)
        return 1
    want = period_key(kind, _today())
    if box.get("period") != want:
        print(f"{kind} outbox 是週期 {box.get('period')} 的過期稿"
              f"（本週期 {want}），不可寄。", file=sys.stderr)
        return 1
    return 0


def restamp_send_date(html: str, today: str) -> str:
    return _TITLE_DATE.sub(lambda m: m.group(1) + today, html, count=1)


def emit_html(kind: str) -> int:
    box = _load(kind)
    if not box.get("html"):
        print(f"ERROR: {kind} outbox 無內容。", file=sys.stderr)
        return 1
    html = box["html"]
    if kind == "daily":
        html = restamp_send_date(html, _today().isoformat())
    sys.stdout.write(html)
    return 0


def emit_urls(kind: str) -> int:
    for url in _HREF.findall(_load(kind).get("html", "")):
        print(url)
    return 0


def clear(kind: str) -> int:
    try:
        os.remove(outbox_path(kind))
    except FileNotFoundError:
        pass
    print(f"OK: {kind} outbox 已清除。")
    return 0


def prep_due(kind: str) -> int:
    return 0 if is_prep_due(kind, _today()) else 1


def send_due(kind: str) -> int:
    return 0 if is_send_due(kind, _today()) else 1


def due_kinds() -> int:
    today = _today()
    for kind in KINDS:
        if is_send_due(kind, today):
            print(kind)
    return 0


def show_period_key(kind: str) -> int:
    print(period_key(kind, _today()))
    return 0


def main() -> int:
    with_kind = {
        "--to-outbox": to_outbox,
        "--ready": ready,
        "--html": emit_html,
        "--urls": emit_urls,
        "--clear": clear,
        "--prep-due": prep_due,
        "--send-due": send_due,
        "--period-key": show_period_key,
    }
    argv = sys.argv[1:]
    if argv == ["--due-kinds"]:
        return due_kinds()
    if len(argv) != 2 or argv[0] not in with_kind or argv[1] not in KINDS:
        print(__doc__, file=sys.stderr)
        return 2
    return with_kind[argv[0]](argv[1])


if __name__ == "__main__":
    sys.exit(main())
