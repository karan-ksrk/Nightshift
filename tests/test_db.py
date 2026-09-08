"""db.Db invariants: rows are never deleted, identity is the sha256 not the
path, and carry-debt arithmetic is what lets an oversized file survive
selector.py's day-alone carve-out without jamming the queue forever."""

import sqlite3
from pathlib import Path

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
    # Paths are stored normalised through pathlib, so the separator is the
    # platform's -- compare the same way rather than hardcoding "/".
    assert row["path"] == str(Path("/new/renamed.mp4"))
    assert row["filename"] == "renamed.mp4"
    assert row["sha256"] == "deadbeef"  # identity unchanged
    assert conn.seen_hash("deadbeef")["id"] == fid  # still the same row


# ---------------------------------------------------------------- rescan fast path

def test_unchanged_at_path_true_for_same_path_size_mtime(conn):
    conn.add_file("/videos/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00",
                  mtime=1234.5)
    assert conn.unchanged_at_path("/videos/a.mp4", 1000, 1234.5) is True


def test_unchanged_at_path_false_when_size_differs(conn):
    conn.add_file("/videos/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00",
                  mtime=1234.5)
    assert conn.unchanged_at_path("/videos/a.mp4", 999, 1234.5) is False


def test_unchanged_at_path_false_when_mtime_differs(conn):
    conn.add_file("/videos/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00",
                  mtime=1234.5)
    assert conn.unchanged_at_path("/videos/a.mp4", 1000, 9999.9) is False


def test_unchanged_at_path_false_for_unknown_path(conn):
    assert conn.unchanged_at_path("/videos/never-seen.mp4", 1000, 1234.5) is False


def test_unchanged_at_path_false_when_mtime_never_recorded(conn):
    """Rows written before the mtime column existed must fall through to a
    real hash rather than being trusted blindly."""
    conn.add_file("/videos/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00")
    assert conn.unchanged_at_path("/videos/a.mp4", 1000, 1234.5) is False


def test_set_mtime_backfills_and_enables_fast_path(conn):
    fid = conn.add_file("/videos/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00")
    assert conn.unchanged_at_path("/videos/a.mp4", 1000, 1234.5) is False

    conn.set_mtime(fid, 1234.5)

    assert conn.unchanged_at_path("/videos/a.mp4", 1000, 1234.5) is True


def test_update_path_carries_mtime_to_the_new_location(conn):
    fid = conn.add_file("/old/a.mp4", "deadbeef", 1000, "2026-01-01T00:00:00",
                        mtime=1.0)
    conn.update_path(fid, "/new/a.mp4", mtime=2.0)

    assert conn.unchanged_at_path("/new/a.mp4", 1000, 2.0) is True
    assert conn.unchanged_at_path("/old/a.mp4", 1000, 1.0) is False


def test_migration_adds_mtime_to_a_preexisting_db(tmp_path):
    """A db created before the mtime column existed must open and work."""
    import sqlite3 as sq
    dbfile = tmp_path / "old.db"
    old = sq.connect(dbfile)
    old.executescript("""
        CREATE TABLE files (
            id INTEGER PRIMARY KEY, path TEXT NOT NULL, filename TEXT NOT NULL,
            sha256 TEXT NOT NULL UNIQUE, size_bytes INTEGER NOT NULL,
            captured_at TEXT, received_at TEXT NOT NULL, state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
            resumable_uri TEXT, bytes_sent INTEGER NOT NULL DEFAULT 0,
            youtube_id TEXT, uploaded_at TEXT, verified_at TEXT, deleted_at TEXT
        );
        INSERT INTO files (path, filename, sha256, size_bytes, received_at, state)
        VALUES ('/videos/a.mp4', 'a.mp4', 'deadbeef', 1000, '2026-01-01', 'QUEUED');
    """)
    old.commit()
    old.close()

    d = Db(dbfile)
    try:
        cols = {r["name"] for r in d.conn.execute("PRAGMA table_info(files)")}
        assert "mtime" in cols
        # Existing row survived and falls through to a real hash.
        assert d.seen_hash("deadbeef") is not None
        assert d.unchanged_at_path("/videos/a.mp4", 1000, 1234.5) is False
    finally:
        d.close()


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
