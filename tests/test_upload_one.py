"""main.upload_one -- specifically the missing-file path.

A file that isn't on disk right now is a transient condition (unmounted
drive, mid-copy, archive being migrated between machines), not a permanent
property of the content. It must not sink the row into FAILED, which the
forward-only state machine never walks back.
"""

import logging

import pytest

import main
from db import Db, FAILED, QUEUED


@pytest.fixture
def conn(tmp_path):
    d = Db(tmp_path / "archive.db")
    yield d
    d.close()


def test_missing_file_stays_queued_and_never_calls_youtube(conn, caplog):
    fid = conn.add_file("/nowhere/gone.mp4", "a" * 64, 1000, "2026-01-01T00:00:00")
    row = conn.get(fid)

    with caplog.at_level(logging.WARNING, logger="nightshift.main"):
        # yt=None is the assertion: the missing-file branch must return
        # before anything touches the YouTube service.
        main.upload_one({}, conn, None, row, chunk=1024, rate=0,
                        start=None, end=None, enforce_window=False)

    after = conn.get(fid)
    assert after["state"] == QUEUED       # not FAILED
    assert after["attempts"] == 1         # but the attempt was recorded
    assert "file missing at upload time" in (after["last_error"] or "")
    assert "not on disk" in caplog.text


def test_missing_file_can_be_retried_after_it_reappears(conn, tmp_path):
    """The point of not sinking it: once the file shows up, the row is still
    QUEUED and gets picked up normally on the next run."""
    path = tmp_path / "later.mp4"
    fid = conn.add_file(path, "b" * 64, 1000, "2026-01-01T00:00:00")

    main.upload_one({}, conn, None, conn.get(fid), chunk=1024, rate=0,
                    start=None, end=None, enforce_window=False)
    assert conn.get(fid)["state"] == QUEUED

    path.write_bytes(b"x" * 1000)         # migration finishes / drive remounts
    assert conn.get(fid)["state"] == QUEUED
    assert conn.queued()                  # still selectable, nothing lost
