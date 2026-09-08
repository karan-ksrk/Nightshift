"""Phase 2 -- Pi HTTP server.

Wraps the existing pipeline in an API so the phone can feed it. The state
machine and selector are untouched; this only adds a way for a `files` row
to come into being from a network upload instead of `scan` finding it on
disk. `main.py run` (unchanged) still does the actual selecting, uploading,
verifying and pruning -- this process never talks to YouTube.

  uvicorn server:app --host 0.0.0.0 --port 8000

LAN/Tailscale only. Every request needs the shared-secret header:

  X-Nightshift-Token: <config["server_token"]>

Endpoints:
  POST /upload/init            {filename, size_bytes, sha256, captured_at}
                                -> {upload_id}  (409 if sha256 already known)
  PUT  /upload/{id}/chunk      Content-Range: bytes start-end/total, raw body
  GET  /upload/{id}/offset     -> {offset}  (resume point after a dropped
                                connection)
  POST /upload/{id}/complete   re-hashes the assembled file; only on a match
                                does it become a QUEUED `files` row
  GET  /status                 counts by state + today's ledger
  GET  /files?state=&limit=&offset=   paginated, for list screens
"""

import hashlib
import re
import uuid
from pathlib import Path

from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse

import db as dbmod
from db import DELETED, FAILED, PROCESSING, QUEUED, UPLOADING, VERIFIED, pacific_date
from main import HERE, captured_at_for, load_config, resolve

CONTENT_RANGE_RE = re.compile(r"^bytes (\d+)-(\d+)/(\d+)$")


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.cfg = load_config()
    yield


app = FastAPI(title="nightshift", lifespan=lifespan)


# ---------------------------------------------------------------- wiring

def get_config():
    return app.state.cfg


def get_db():
    """A fresh connection per request. sqlite3 connections aren't safe to
    share across threads, and FastAPI's sync `def` endpoints each run in
    their own thread pool thread -- one shared global Db would need its own
    locking to be correct. Db.__init__ is cheap; opening one per request
    isn't."""
    conn = dbmod.Db(resolve(get_config(), "database"), check_same_thread=False)
    try:
        yield conn
    finally:
        conn.close()


def require_token(x_nightshift_token: str = Header(default=None)):
    expected = get_config().get("server_token")
    if not expected:
        # Misconfiguration, not an auth failure -- fail loud rather than
        # silently accepting every request because the config forgot a token.
        raise HTTPException(500, "server_token not set in config")
    if x_nightshift_token != expected:
        raise HTTPException(401, "bad or missing X-Nightshift-Token")


def incoming_dir(cfg):
    """Where assembled uploads land before /complete moves them into the
    real watch folder. Its own directory, not the watch folder itself, so a
    half-received .part file is never mistaken for a real video by `scan`."""
    d = resolve(cfg, "database").parent / "incoming"
    d.mkdir(parents=True, exist_ok=True)
    return d


def watch_dir(cfg):
    folders = cfg["watch_folders"]
    return Path(folders[0]).expanduser()


# ---------------------------------------------------------------- upload

@app.post("/upload/init", dependencies=[Depends(require_token)])
def upload_init(body: dict, conn=Depends(get_db)):
    filename = body.get("filename")
    size_bytes = body.get("size_bytes")
    sha256 = body.get("sha256", "")
    captured_at = body.get("captured_at")

    if not filename or not isinstance(size_bytes, int) or size_bytes <= 0:
        raise HTTPException(400, "filename and a positive size_bytes are required")
    if not re.fullmatch(r"[0-9a-f]{64}", sha256 or ""):
        raise HTTPException(400, "sha256 must be a 64-char hex digest")

    # Free dedupe from the phone side: if this content is already archived,
    # tell the caller instead of accepting bytes we're going to throw away.
    seen = conn.seen_hash(sha256)
    if seen:
        raise HTTPException(409, detail={
            "error": "duplicate", "file_id": seen["id"], "state": seen["state"],
        })

    upload_id = uuid.uuid4().hex
    part_path = incoming_dir(get_config()) / f"{upload_id}.part"
    part_path.touch()
    conn.create_upload(upload_id, filename, size_bytes, sha256, captured_at,
                       part_path)
    return {"upload_id": upload_id}


@app.put("/upload/{upload_id}/chunk", dependencies=[Depends(require_token)])
async def upload_chunk(upload_id: str, request: Request, conn=Depends(get_db)):
    session = conn.get_upload(upload_id)
    if not session:
        raise HTTPException(404, "unknown upload_id")

    content_range = request.headers.get("content-range", "")
    m = CONTENT_RANGE_RE.match(content_range)
    if not m:
        raise HTTPException(400, "Content-Range: bytes <start>-<end>/<total> required")
    start, end, total = (int(g) for g in m.groups())

    part_path = Path(session["part_path"])
    current = part_path.stat().st_size

    # No gaps allowed -- a chunk starting past what we've got would leave a
    # hole `complete`'s hash check would silently include as zero bytes.
    # Starting at or before `current` is fine and idempotent: seeking and
    # overwriting a retried (or partially-received) chunk is harmless.
    if start > current:
        raise HTTPException(416, detail={"error": "gap", "offset": current})

    body = await request.body()
    if len(body) != end - start + 1:
        raise HTTPException(400, "body length doesn't match Content-Range")

    with open(part_path, "r+b") as fh:
        fh.seek(start)
        fh.write(body)

    return {"received": part_path.stat().st_size}


@app.get("/upload/{upload_id}/offset", dependencies=[Depends(require_token)])
def upload_offset(upload_id: str, conn=Depends(get_db)):
    session = conn.get_upload(upload_id)
    if not session:
        raise HTTPException(404, "unknown upload_id")
    return {"offset": Path(session["part_path"]).stat().st_size}


@app.post("/upload/{upload_id}/complete", dependencies=[Depends(require_token)])
def upload_complete(upload_id: str, conn=Depends(get_db)):
    session = conn.get_upload(upload_id)
    if not session:
        raise HTTPException(404, "unknown upload_id")

    part_path = Path(session["part_path"])
    actual_size = part_path.stat().st_size
    if actual_size != session["size_bytes"]:
        raise HTTPException(400, detail={
            "error": "incomplete", "received": actual_size,
            "expected": session["size_bytes"],
        })

    # Trust nothing the client said about the content -- re-hash the bytes
    # that actually landed on disk. A mismatch means a corrupted or
    # tampered transfer; the session stays open so the client can re-send.
    digest = hashlib.sha256(part_path.read_bytes()).hexdigest()
    if digest != session["sha256"]:
        raise HTTPException(409, detail={"error": "hash_mismatch"})

    # Someone else finished uploading the same content while this session
    # was in flight -- dedupe rather than violate the sha256 UNIQUE
    # constraint on `files`.
    seen = conn.seen_hash(digest)
    if seen:
        part_path.unlink(missing_ok=True)
        conn.delete_upload(upload_id)
        return JSONResponse(status_code=200, content={
            "file_id": seen["id"], "state": seen["state"], "duplicate": True,
        })

    dest = watch_dir(get_config()) / session["filename"]
    dest.parent.mkdir(parents=True, exist_ok=True)
    part_path.rename(dest)

    captured_at = session["captured_at"] or captured_at_for(dest)
    file_id = conn.add_file(dest, digest, actual_size, captured_at,
                            mtime=dest.stat().st_mtime)
    conn.delete_upload(upload_id)
    return {"file_id": file_id, "state": QUEUED}


# ---------------------------------------------------------------- status

@app.get("/status", dependencies=[Depends(require_token)])
def status(conn=Depends(get_db)):
    counts = conn.counts()
    u = conn.usage()
    cfg = get_config()
    byte_budget = cfg.get("daily_byte_budget")

    queued_bytes = sum(b for state, (_, b) in counts.items()
                       if state in (QUEUED, UPLOADING))
    days_to_drain = None
    if byte_budget:
        # Whole remaining queue over the budget, not just what's left today
        # (that's what `run` picks next) -- this is meant to answer "at this
        # rate, when am I done", which is a queue-wide question.
        days_to_drain = queued_bytes / byte_budget

    return {
        "counts": {state: {"files": n, "bytes": b}
                   for state, (n, b) in counts.items()},
        "pacific_day": pacific_date(),
        "uploads_used": u["uploads_used"],
        "daily_upload_budget": cfg.get("daily_upload_budget", 100),
        "bytes_used": u["bytes_used"],
        "daily_byte_budget": byte_budget,
        "carry_debt": u["carry_debt"],
        "queued_bytes": queued_bytes,
        "estimated_days_to_drain": days_to_drain,
    }


@app.get("/files", dependencies=[Depends(require_token)])
def files(state: str = None, limit: int = 50, offset: int = 0, conn=Depends(get_db)):
    valid = {QUEUED, UPLOADING, PROCESSING, VERIFIED, DELETED, FAILED}
    if state and state not in valid:
        raise HTTPException(400, f"state must be one of {sorted(valid)}")
    limit = max(1, min(limit, 200))
    rows, total = conn.list_files(state=state, limit=limit, offset=offset)
    return {
        "total": total,
        "files": [dict(r) for r in rows],
    }
