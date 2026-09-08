"""main.cmd_reconcile -- catches videos that silently vanished from the
channel. Read-only: it must never rewind a row, since the state machine is
forward-only and a human decides what to do about a missing video."""

import logging

import pytest

import main
from db import Db, DELETED, VERIFIED


@pytest.fixture
def conn(tmp_path):
    d = Db(tmp_path / "archive.db")
    yield d
    d.close()


class FakeYouTube:
    """yt.videos().list(part=..., id=...).execute() over a known id set."""

    def __init__(self, known_ids):
        self.known = set(known_ids)

    def videos(self):
        return self

    def list(self, part, id):
        self._asked = id.split(",")
        return self

    def execute(self):
        return {"items": [{"id": v} for v in self._asked if v in self.known]}


def uploaded(conn, path, sha, yt_id, state=VERIFIED):
    fid = conn.add_file(path, sha, 1000, "2026-01-01T00:00:00")
    conn.set_state(fid, VERIFIED, youtube_id=yt_id, verified_at="2026-01-01")
    if state == DELETED:
        conn.set_state(fid, DELETED, deleted_at="2026-01-01")
    return fid


def test_all_present_reports_nothing_missing(conn, caplog):
    uploaded(conn, "/v/a.mp4", "h1", "yt1")
    uploaded(conn, "/v/b.mp4", "h2", "yt2", state=DELETED)
    yt = FakeYouTube({"yt1", "yt2"})

    with caplog.at_level(logging.INFO, logger="nightshift.main"):
        main.cmd_reconcile({}, conn, None, yt=yt)

    assert "2 checked, 2 still on YouTube, 0 missing" in caplog.text
    assert "MISSING" not in caplog.text


def test_missing_video_for_deleted_row_is_flagged_as_loss(conn, caplog):
    """Gone from YouTube and already deleted locally -- unrecoverable, and
    the loudest thing this command can find."""
    uploaded(conn, "/v/gone.mp4", "h1", "yt-gone", state=DELETED)
    yt = FakeYouTube(set())

    with caplog.at_level(logging.INFO, logger="nightshift.main"):
        main.cmd_reconcile({}, conn, None, yt=yt)

    assert "MISSING and local copy already deleted" in caplog.text
    assert "yt-gone" in caplog.text
    assert "1 missing" in caplog.text


def test_missing_video_for_verified_row_notes_local_copy(conn, tmp_path, caplog):
    """Still VERIFIED means prune hasn't run, so the file may be re-uploadable
    -- worth saying so rather than just reporting it gone."""
    local = tmp_path / "still-here.mp4"
    local.write_bytes(b"x")
    uploaded(conn, local, "h1", "yt-gone")
    yt = FakeYouTube(set())

    with caplog.at_level(logging.INFO, logger="nightshift.main"):
        main.cmd_reconcile({}, conn, None, yt=yt)

    assert "still on disk -- can be re-uploaded" in caplog.text


def test_reconcile_does_not_change_any_state(conn):
    """The forward-only invariant: reporting a missing video must not rewind
    VERIFIED/DELETED rows or mark them FAILED."""
    fid_v = uploaded(conn, "/v/a.mp4", "h1", "yt-gone")
    fid_d = uploaded(conn, "/v/b.mp4", "h2", "yt-gone2", state=DELETED)
    yt = FakeYouTube(set())

    main.cmd_reconcile({}, conn, None, yt=yt)

    assert conn.get(fid_v)["state"] == VERIFIED
    assert conn.get(fid_d)["state"] == DELETED
    assert conn.get(fid_v)["attempts"] == 0


def test_nothing_uploaded_yet_makes_no_api_call(conn, caplog):
    """A fresh queue shouldn't spend quota or need credentials at all."""
    conn.add_file("/v/queued.mp4", "h1", 1000, "2026-01-01T00:00:00")

    def explode():
        raise AssertionError("must not build a YouTube service")

    with caplog.at_level(logging.INFO, logger="nightshift.main"):
        main.cmd_reconcile({}, conn, None, yt=None)

    assert "nothing uploaded yet" in caplog.text


def test_rows_without_a_youtube_id_are_skipped(conn):
    """Belt and braces: a VERIFIED row with no id can't be checked, and must
    not turn into an empty-string lookup."""
    fid = conn.add_file("/v/a.mp4", "h1", 1000, "2026-01-01T00:00:00")
    conn.set_state(fid, VERIFIED, verified_at="2026-01-01")  # no youtube_id

    asked = []

    class Recorder(FakeYouTube):
        def list(self, part, id):
            asked.append(id)
            return super().list(part, id)

    main.cmd_reconcile({}, conn, None, yt=Recorder(set()))

    assert asked == []
