"""db.Db invariants: rows are never deleted, identity is the sha256 not the
path, and carry-debt arithmetic is what lets an oversized file survive
selector.py's day-alone carve-out without jamming the queue forever."""

import sqlite3

import pytest

from db import Db, QUEUED, VERIFIED, DELETED


@pytest.fixture
def conn(tmp_path):
    d = Db(tmp_path / "archive.db")
    yield d
    d.close()


# ---------------------------------------------------------------- dedupe

def test_seen_hash_finds_existing_row(conn):
    fid = conn.add_file("/videos/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00")
    row = conn.seen_hash("deadbeef")
    assert row["id"] == fid
    assert row["state"] == QUEUED


def test_seen_hash_missing_returns_none(conn):
    assert conn.seen_hash("nope") is None


def test_duplicate_hash_rejected_at_db_level(conn):
    """sha256 is UNIQUE -- identity is content, not path. main.py relies on
    this as the backstop even though cmd_scan also checks seen_hash first."""
    conn.add_file("/videos/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00")
    with pytest.raises(sqlite3.IntegrityError):
        conn.add_file("/videos/b.mp4", "deadbeef", 1000, "2026-01-01T00:00:00")


# ---------------------------------------------------------------- path update

def test_moved_file_updates_path_not_identity(conn):
    fid = conn.add_file("/old/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00")
    conn.update_path(fid, "/new/renamed.mp4")

    row = conn.get(fid)
    assert row["path"] == "/new/renamed.mp4"
    assert row["filename"] == "renamed.mp4"
    assert row["sha256"] == "deadbeef"  # identity unchanged
    assert conn.seen_hash("deadbeef")["id"] == fid  # still the same row


# ---------------------------------------------------------------- carry-debt

def test_carry_debt_forward_zero_when_under_budget(conn):
    conn.record_usage(sent_bytes=5, pt_date="2026-01-01")
    debt = conn.carry_debt_forward(byte_budget=10, pt_date="2026-01-01")
    assert debt == 0
    assert conn.usage("2026-01-02")["carry_debt"] == 0


def test_carry_debt_forward_bills_tomorrow_for_overage(conn):
    """An oversized file (selector's day-alone carve-out) is allowed to blow
    through today's budget. The overage must be billed to tomorrow so the
    budget doesn't just silently grow."""
    conn.record_usage(sent_bytes=15, pt_date="2026-01-01")
    debt = conn.carry_debt_forward(byte_budget=10, pt_date="2026-01-01")
    assert debt == 5
    assert conn.usage("2026-01-02")["carry_debt"] == 5


def test_carry_debt_compounds_across_days(conn):
    """Day 2's effective budget is reduced by day 1's debt; if day 2 also
    overspends against that reduced budget, the new debt (not the raw
    overage) is what carries to day 3."""
    conn.record_usage(sent_bytes=15, pt_date="2026-01-01")
    conn.carry_debt_forward(byte_budget=10, pt_date="2026-01-01")
    assert conn.usage("2026-01-02")["carry_debt"] == 5

    # Day 2: effective budget is 10 - 5 = 5. Spend 8 -> 3 over.
    conn.record_usage(sent_bytes=8, pt_date="2026-01-02")
    debt = conn.carry_debt_forward(byte_budget=10, pt_date="2026-01-02")
    assert debt == 3
    assert conn.usage("2026-01-03")["carry_debt"] == 3


def test_carry_debt_forward_noop_when_budget_unset(conn):
    conn.record_usage(sent_bytes=999, pt_date="2026-01-01")
    assert conn.carry_debt_forward(byte_budget=None, pt_date="2026-01-01") == 0
    assert conn.carry_debt_forward(byte_budget=0, pt_date="2026-01-01") == 0


# ---------------------------------------------------------------- manifest survives delete

def test_row_survives_state_transitions_to_deleted(conn):
    """The files table is the only record of what's on YouTube and what's
    gone from disk. set_state(DELETED) must never remove the row."""
    fid = conn.add_file("/videos/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00")
    conn.set_state(fid, VERIFIED, youtube_id="yt123", verified_at="2026-01-01T00:00:00")
    conn.set_state(fid, DELETED, deleted_at="2026-01-01T00:00:00")

    row = conn.get(fid)
    assert row is not None
    assert row["state"] == DELETED
    assert row["youtube_id"] == "yt123"  # manifest data intact
    assert row["sha256"] == "deadbeef"


def test_no_delete_method_exists_on_db():
    """There is deliberately no way to remove a row from files. If someone
    adds one, this test is the tripwire."""
    assert not hasattr(Db, "delete_file")
    assert not hasattr(Db, "delete")
