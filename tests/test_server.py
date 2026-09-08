"""server.py -- the Phase 2 chunked-upload API, via FastAPI's TestClient.

Never talks to YouTube (this process never does at all -- main.py run still
owns that). Focus: auth, dedupe, chunk idempotency/gaps, and that a `files`
row only appears once the assembled bytes re-hash to what the client claimed.
"""

import hashlib

import pytest
from fastapi.testclient import TestClient

import server as srv
from db import Db, QUEUED, VERIFIED

TOKEN = "test-shared-secret"
HEADERS = {"X-Nightshift-Token": TOKEN}


@pytest.fixture
def client(tmp_path, monkeypatch):
    watch = tmp_path / "watch"
    watch.mkdir()
    cfg = {
        "_dir": tmp_path,
        "database": "archive.db",
        "watch_folders": [str(watch)],
        "server_token": TOKEN,
    }
    monkeypatch.setattr(srv, "load_config", lambda *a, **k: cfg)
    with TestClient(srv.app) as c:
        yield c, cfg, watch


def db_at(cfg):
    d = Db(cfg["_dir"] / cfg["database"])
    return d


def sha_of(data):
    return hashlib.sha256(data).hexdigest()


def do_upload(client, filename, data, headers=HEADERS, captured_at=None,
             chunk_size=None):
    """Full init -> chunk(s) -> complete cycle. Returns the /complete response."""
    digest = sha_of(data)
    r = client.post("/upload/init", json={
        "filename": filename, "size_bytes": len(data), "sha256": digest,
        "captured_at": captured_at,
    }, headers=headers)
    if r.status_code != 200:
        return r
    upload_id = r.json()["upload_id"]

    chunk_size = chunk_size or len(data)
    for start in range(0, len(data), chunk_size):
        chunk = data[start:start + chunk_size]
        end = start + len(chunk) - 1
        r = client.put(f"/upload/{upload_id}/chunk", content=chunk, headers={
            **headers, "Content-Range": f"bytes {start}-{end}/{len(data)}",
        })
        assert r.status_code == 200, r.text

    return client.post(f"/upload/{upload_id}/complete", headers=headers)


# ---------------------------------------------------------------- auth

def test_missing_token_rejected(client):
    c, cfg, watch = client
    r = c.get("/status")
    assert r.status_code == 401


def test_wrong_token_rejected(client):
    c, cfg, watch = client
    r = c.get("/status", headers={"X-Nightshift-Token": "nope"})
    assert r.status_code == 401


def test_correct_token_accepted(client):
    c, cfg, watch = client
    r = c.get("/status", headers=HEADERS)
    assert r.status_code == 200


# ---------------------------------------------------------------- init

def test_init_rejects_bad_sha256(client):
    c, cfg, watch = client
    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": 10, "sha256": "not-hex",
    }, headers=HEADERS)
    assert r.status_code == 400


def test_init_rejects_zero_size(client):
    c, cfg, watch = client
    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": 0, "sha256": "a" * 64,
    }, headers=HEADERS)
    assert r.status_code == 400


def test_init_dedupes_against_existing_archive(client):
    """Free dedupe from the phone side, per PLAN.md -- already-archived
    content shouldn't be re-transferred at all."""
    c, cfg, watch = client
    d = db_at(cfg)
    d.add_file("/elsewhere/a.mp4", "b" * 64, 1000, "2026-01-01T00:00:00")
    d.close()

    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": 1000, "sha256": "b" * 64,
    }, headers=HEADERS)

    assert r.status_code == 409
    assert r.json()["detail"]["error"] == "duplicate"


# ---------------------------------------------------------------- chunk

def test_chunk_unknown_upload_id(client):
    c, cfg, watch = client
    r = c.put("/upload/bogus/chunk", content=b"x", headers={
        **HEADERS, "Content-Range": "bytes 0-0/1",
    })
    assert r.status_code == 404


def test_chunk_gap_rejected(client):
    """A chunk starting past what's on disk would leave a hole that
    /complete's hash check would silently treat as zero bytes."""
    c, cfg, watch = client
    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": 100, "sha256": "c" * 64,
    }, headers=HEADERS)
    upload_id = r.json()["upload_id"]

    r = c.put(f"/upload/{upload_id}/chunk", content=b"x" * 10, headers={
        **HEADERS, "Content-Range": "bytes 50-59/100",
    })

    assert r.status_code == 416
    assert r.json()["detail"]["offset"] == 0


def test_chunk_retry_at_same_offset_is_idempotent(client):
    c, cfg, watch = client
    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": 10, "sha256": "d" * 64,
    }, headers=HEADERS)
    upload_id = r.json()["upload_id"]
    headers = {**HEADERS, "Content-Range": "bytes 0-4/10"}

    r1 = c.put(f"/upload/{upload_id}/chunk", content=b"hello", headers=headers)
    r2 = c.put(f"/upload/{upload_id}/chunk", content=b"hello", headers=headers)

    assert r1.status_code == r2.status_code == 200
    assert r1.json()["received"] == r2.json()["received"] == 5


def test_chunk_body_length_mismatch_rejected(client):
    c, cfg, watch = client
    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": 10, "sha256": "e" * 64,
    }, headers=HEADERS)
    upload_id = r.json()["upload_id"]

    r = c.put(f"/upload/{upload_id}/chunk", content=b"toolong", headers={
        **HEADERS, "Content-Range": "bytes 0-2/10",  # claims 3 bytes, sent 7
    })
    assert r.status_code == 400


# ---------------------------------------------------------------- offset

def test_offset_tracks_bytes_written(client):
    c, cfg, watch = client
    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": 10, "sha256": "f" * 64,
    }, headers=HEADERS)
    upload_id = r.json()["upload_id"]
    c.put(f"/upload/{upload_id}/chunk", content=b"abcde", headers={
        **HEADERS, "Content-Range": "bytes 0-4/10",
    })

    r = c.get(f"/upload/{upload_id}/offset", headers=HEADERS)

    assert r.status_code == 200
    assert r.json()["offset"] == 5


def test_offset_unknown_upload_id(client):
    c, cfg, watch = client
    r = c.get("/upload/bogus/offset", headers=HEADERS)
    assert r.status_code == 404


# ---------------------------------------------------------------- complete

def test_full_upload_creates_queued_row_and_moves_file(client):
    c, cfg, watch = client
    data = b"video bytes" * 1000

    r = do_upload(c, "clip.mp4", data, chunk_size=1024)

    assert r.status_code == 200
    body = r.json()
    assert body["state"] == QUEUED

    d = db_at(cfg)
    row = d.get(body["file_id"])
    assert row["state"] == QUEUED
    assert row["sha256"] == sha_of(data)
    assert row["size_bytes"] == len(data)
    d.close()

    dest = watch / "clip.mp4"
    assert dest.exists()
    assert dest.read_bytes() == data
    assert not (dest.parent / f"{body['file_id']}.part").exists()


def test_complete_before_all_bytes_received_rejected(client):
    c, cfg, watch = client
    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": 10, "sha256": "1" * 64,
    }, headers=HEADERS)
    upload_id = r.json()["upload_id"]
    c.put(f"/upload/{upload_id}/chunk", content=b"abc", headers={
        **HEADERS, "Content-Range": "bytes 0-2/10",
    })

    r = c.post(f"/upload/{upload_id}/complete", headers=HEADERS)

    assert r.status_code == 400
    assert r.json()["detail"]["error"] == "incomplete"


def test_complete_hash_mismatch_keeps_session_open_for_retry(client):
    """A corrupted transfer must not become a `files` row -- and the session
    survives so the client can re-send rather than starting over."""
    c, cfg, watch = client
    data = b"x" * 20
    wrong_hash = sha_of(b"not the same bytes!!")
    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": len(data), "sha256": wrong_hash,
    }, headers=HEADERS)
    upload_id = r.json()["upload_id"]
    c.put(f"/upload/{upload_id}/chunk", content=data, headers={
        **HEADERS, "Content-Range": f"bytes 0-{len(data)-1}/{len(data)}",
    })

    r = c.post(f"/upload/{upload_id}/complete", headers=HEADERS)
    assert r.status_code == 409
    assert r.json()["detail"]["error"] == "hash_mismatch"

    # Session still exists -- offset still queryable, no orphaned zombie.
    r2 = c.get(f"/upload/{upload_id}/offset", headers=HEADERS)
    assert r2.status_code == 200

    d = db_at(cfg)
    assert d.seen_hash(wrong_hash) is None  # never entered the manifest
    d.close()


def test_complete_races_a_concurrent_duplicate(client):
    """Same content finished uploading (or was scanned in) while this
    session was still in flight -- must dedupe, not violate the sha256
    UNIQUE constraint on files."""
    c, cfg, watch = client
    data = b"duplicate content" * 50
    digest = sha_of(data)

    r = c.post("/upload/init", json={
        "filename": "a.mp4", "size_bytes": len(data), "sha256": digest,
    }, headers=HEADERS)
    upload_id = r.json()["upload_id"]
    c.put(f"/upload/{upload_id}/chunk", content=data, headers={
        **HEADERS, "Content-Range": f"bytes 0-{len(data)-1}/{len(data)}",
    })

    # Another path (e.g. a nightly `scan`) already archived this content.
    d = db_at(cfg)
    fid = d.add_file("/elsewhere/dup.mp4", digest, len(data), "2026-01-01T00:00:00")
    d.set_state(fid, VERIFIED, verified_at="2026-01-01T00:00:00")
    d.close()

    r = c.post(f"/upload/{upload_id}/complete", headers=HEADERS)

    assert r.status_code == 200
    assert r.json()["duplicate"] is True
    assert r.json()["file_id"] == fid
    assert not (watch / "a.mp4").exists()  # never moved into the watch folder


def test_complete_unknown_upload_id(client):
    c, cfg, watch = client
    r = c.post("/upload/bogus/complete", headers=HEADERS)
    assert r.status_code == 404


# ---------------------------------------------------------------- status / files

def test_status_reflects_db_state(client):
    c, cfg, watch = client
    d = db_at(cfg)
    d.add_file("/v/a.mp4", "a" * 64, 1000, "2026-01-01T00:00:00")
    d.close()

    r = c.get("/status", headers=HEADERS)

    assert r.status_code == 200
    body = r.json()
    assert body["counts"][QUEUED]["files"] == 1
    assert body["counts"][QUEUED]["bytes"] == 1000


def test_status_estimates_days_to_drain(client, monkeypatch):
    c, cfg, watch = client
    cfg["daily_byte_budget"] = 1000
    d = db_at(cfg)
    d.add_file("/v/a.mp4", "a" * 64, 2500, "2026-01-01T00:00:00")
    d.close()

    r = c.get("/status", headers=HEADERS)

    assert r.json()["queued_bytes"] == 2500
    assert r.json()["estimated_days_to_drain"] == pytest.approx(2.5)


def test_status_days_to_drain_null_when_budget_unset(client):
    c, cfg, watch = client
    r = c.get("/status", headers=HEADERS)
    assert r.json()["estimated_days_to_drain"] is None


def test_files_filters_by_state_and_paginates(client):
    c, cfg, watch = client
    d = db_at(cfg)
    for i in range(5):
        d.add_file(f"/v/{i}.mp4", f"{i}" * 64, 1000, "2026-01-01T00:00:00")
    d.close()

    r = c.get("/files", params={"state": QUEUED, "limit": 2}, headers=HEADERS)

    assert r.status_code == 200
    body = r.json()
    assert body["total"] == 5
    assert len(body["files"]) == 2


def test_files_rejects_invalid_state(client):
    c, cfg, watch = client
    r = c.get("/files", params={"state": "NOT_A_STATE"}, headers=HEADERS)
    assert r.status_code == 400
