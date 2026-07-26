# -*- coding: utf-8 -*-
"""outbox 的週期判斷測試。

備稿日與寄出日刻意分屬不同天，整套設計靠「兩天算出同一個 period key」成立，
月底與跨年跨月的邊界最容易出錯，故針對日期邏輯逐一釘住。
"""
import datetime
import importlib.util
import os
import sys

import pytest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SPEC = importlib.util.spec_from_file_location(
    "outbox", os.path.join(os.path.dirname(_HERE), "outbox.py"))
outbox = importlib.util.module_from_spec(_SPEC)
sys.modules["outbox"] = outbox
_SPEC.loader.exec_module(outbox)


def d(s: str) -> datetime.date:
    return datetime.date.fromisoformat(s)


# ── 月底判斷：不能寫死 31 號 ──────────────────────────────────
@pytest.mark.parametrize("day, last, second_last", [
    ("2026-07-30", False, True),    # 大月倒數第二天
    ("2026-07-31", True, False),    # 大月最後一天
    ("2026-06-29", False, True),    # 小月倒數第二天
    ("2026-06-30", True, False),    # 小月最後一天
    ("2026-02-27", False, True),    # 平年 2 月倒數第二天
    ("2026-02-28", True, False),    # 平年 2 月最後一天
    ("2024-02-28", False, True),    # 閏年 2 月倒數第二天
    ("2024-02-29", True, False),    # 閏年 2 月最後一天
    ("2026-12-30", False, True),    # 跨年前一天也要算對
    ("2026-12-31", True, False),
    ("2026-07-01", False, False),   # 月初兩者皆非
    ("2026-07-15", False, False),
])
def test_month_boundary(day, last, second_last):
    assert outbox.is_last_day_of_month(d(day)) is last
    assert outbox.is_second_last_day_of_month(d(day)) is second_last


# ── period key：備稿日與寄出日必須算出同一個代號 ──────────────
@pytest.mark.parametrize("kind, prep_day, send_day", [
    ("weekly", "2026-07-25", "2026-07-26"),   # 週六備 → 週日寄
    ("monthly", "2026-07-30", "2026-07-31"),  # 倒數第二天備 → 最後一天寄
    ("monthly", "2026-02-27", "2026-02-28"),  # 平年 2 月
    ("monthly", "2024-02-28", "2024-02-29"),  # 閏年 2 月
    ("monthly", "2026-12-30", "2026-12-31"),  # 跨年月
    ("daily", "2026-07-26", "2026-07-26"),    # 每日信同天備同天寄
])
def test_prep_and_send_share_period(kind, prep_day, send_day):
    assert outbox.period_key(kind, d(prep_day)) == outbox.period_key(kind, d(send_day))


def test_weekly_period_rolls_over_at_monday():
    """週日與隔天週一分屬不同 ISO 週——上週的稿不能被下週寄出。"""
    assert outbox.period_key("weekly", d("2026-07-26")) != \
           outbox.period_key("weekly", d("2026-07-27"))


def test_monthly_period_rolls_over_at_first():
    assert outbox.period_key("monthly", d("2026-07-31")) != \
           outbox.period_key("monthly", d("2026-08-01"))


# ── 該不該備 / 該不該寄 ───────────────────────────────────────
@pytest.mark.parametrize("day, weekday_name, prep, send", [
    ("2026-07-24", "週五", False, False),
    ("2026-07-25", "週六", True, False),   # 備稿日
    ("2026-07-26", "週日", True, True),    # 寄出日，同時允許補備
    ("2026-07-27", "週一", False, False),
])
def test_weekly_schedule(day, weekday_name, prep, send):
    assert outbox.is_prep_due("weekly", d(day)) is prep, weekday_name
    assert outbox.is_send_due("weekly", d(day)) is send, weekday_name


@pytest.mark.parametrize("day, prep, send", [
    ("2026-07-29", False, False),
    ("2026-07-30", True, False),   # 備稿日
    ("2026-07-31", True, True),    # 寄出日，同時允許補備
    ("2026-08-01", False, False),
])
def test_monthly_schedule(day, prep, send):
    assert outbox.is_prep_due("monthly", d(day)) is prep
    assert outbox.is_send_due("monthly", d(day)) is send


def test_daily_always_due():
    for day in ("2026-07-26", "2026-07-31", "2026-02-28"):
        assert outbox.is_prep_due("daily", d(day)) is True
        assert outbox.is_send_due("daily", d(day)) is True


# ── 存取行為 ─────────────────────────────────────────────────
@pytest.fixture
def state(tmp_path, monkeypatch):
    monkeypatch.setattr(outbox, "STATE_DIR", str(tmp_path))
    return tmp_path


def test_ready_rejects_stale_period(state, monkeypatch):
    """上一個週期備的稿不可寄，避免寄出過期內容。"""
    path = outbox.outbox_path("weekly")
    with open(path, "w", encoding="utf-8") as f:
        f.write('{"kind":"weekly","period":"2026-W29","html":"<p>舊稿</p>"}')
    monkeypatch.setattr(outbox, "_today", lambda: d("2026-07-26"))  # 2026-W30
    assert outbox.ready("weekly") == 1


def test_ready_accepts_yesterday_prepared_draft(state, monkeypatch):
    """週六備的稿，週日寄仍然算數——這是整套前一天備稿設計的前提。"""
    monkeypatch.setattr(outbox, "_today", lambda: d("2026-07-25"))  # 週六
    monkeypatch.setattr("sys.stdin", _Stdin("<p>週報</p>"))
    assert outbox.to_outbox("weekly") == 0
    monkeypatch.setattr(outbox, "_today", lambda: d("2026-07-26"))  # 週日
    assert outbox.ready("weekly") == 0


def test_kinds_do_not_collide(state, monkeypatch):
    """三種週期各存各的，備週報不會蓋掉今天的每日稿。"""
    monkeypatch.setattr(outbox, "_today", lambda: d("2026-07-25"))
    monkeypatch.setattr("sys.stdin", _Stdin("<p>每日</p>"))
    outbox.to_outbox("daily")
    monkeypatch.setattr("sys.stdin", _Stdin("<p>週報</p>"))
    outbox.to_outbox("weekly")
    assert outbox.ready("daily") == 0
    assert outbox.ready("weekly") == 0
    outbox.clear("weekly")
    assert outbox.ready("daily") == 0   # 清週報不影響每日


def test_daily_title_restamped_to_send_day():
    html = '<div>📰 每日 AI 新聞 Top 10 · 2026-07-25</div>'
    assert "2026-07-26" in outbox.restamp_send_date(html, "2026-07-26")


class _Stdin:
    def __init__(self, text):
        self._text = text

    def read(self):
        return self._text
