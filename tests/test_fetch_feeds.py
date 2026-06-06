import fetch_feeds
import time
import json
from datetime import datetime, timezone


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


def test_normalize_url_strips_fragment_trailing_slash_and_space():
    assert fetch_feeds.normalize_url("  https://x.com/a/  ") == "https://x.com/a"
    assert fetch_feeds.normalize_url("https://x.com/a#section") == "https://x.com/a"
    assert fetch_feeds.normalize_url("https://x.com/a") == "https://x.com/a"


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


def test_load_seen_corrupted_file_returns_empty(tmp_path):
    p = tmp_path / "seen.json"
    p.write_text("{not valid json", encoding="utf-8")
    assert fetch_feeds.load_seen(str(p)) == {}


def test_save_seen_merges_normalizes_and_prunes(tmp_path):
    p = tmp_path / "seen.json"
    now = datetime(2026, 6, 6, 0, 0, 0, tzinfo=timezone.utc)
    existing = {"https://old.com/a": "2026-05-01"}
    fetch_feeds.save_seen(
        str(p), ["https://new.com/b/", "https://new.com/b#frag"],
        today="2026-06-06", existing=existing, retention_days=7, now=now,
    )
    data = json.loads(p.read_text(encoding="utf-8"))
    assert data == {"https://new.com/b": "2026-06-06"}


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


def test_strip_html_removes_tags_collapses_space_and_truncates():
    assert fetch_feeds.strip_html("<p>Hello   <b>world</b></p>") == "Hello world"
    assert fetch_feeds.strip_html("") == ""
    assert len(fetch_feeds.strip_html("x" * 500)) == 300


def test_main_collect_prints_candidates_without_network(tmp_path, monkeypatch, capsys):
    from datetime import datetime, timezone
    feeds = tmp_path / "feeds.txt"
    feeds.write_text("https://x.com/feed\tX\n", encoding="utf-8")
    seen = tmp_path / "seen.json"

    def fake_gather(feeds_arg, hours, now, fetch=None):
        return [{"title": "T", "link": "https://x.com/a", "source": "X",
                 "summary": "s",
                 "published": datetime(2026, 6, 6, 10, 0, tzinfo=timezone.utc)}]

    monkeypatch.setattr(fetch_feeds, "gather_candidates", fake_gather)
    fetch_feeds.main(["collect", "--feeds", str(feeds), "--seen", str(seen),
                      "--hours", "48", "--widen", "72", "--min", "1"])
    out = capsys.readouterr().out
    assert "[1]" in out and "title: T" in out and "link: https://x.com/a" in out


def test_palette_offset_advances_by_one_each_day():
    base = datetime(2026, 1, 1, tzinfo=timezone.utc)   # day-of-year 1
    nextday = datetime(2026, 1, 2, tzinfo=timezone.utc)  # day-of-year 2
    assert fetch_feeds.palette_offset(nextday) == (fetch_feeds.palette_offset(base) + 1) % 10


def test_rotate_palette_shifts_and_keeps_all_colors():
    rotated = fetch_feeds.rotate_palette(1)
    assert rotated[0] == fetch_feeds.PALETTE[1]          # 整體往前一格
    assert rotated[-1] == fetch_feeds.PALETTE[0]          # 尾端繞回開頭
    assert sorted(rotated) == sorted(fetch_feeds.PALETTE)  # 10 色都還在，沒重複沒少


def test_format_palette_numbers_rows():
    text = fetch_feeds.format_palette(fetch_feeds.PALETTE)
    lines = text.splitlines()
    assert len(lines) == 10
    assert lines[0].startswith("1 BG:")
    assert lines[9].startswith("10 BG:")
