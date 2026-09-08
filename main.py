"""YouTube archive uploader -- Phase 1.

  python main.py auth      one-time OAuth, run on a machine with a browser
  python main.py scan      hash new files in the watch folders, queue them
  python main.py run       scan + upload within the window + verify + prune
  python main.py verify    poll processing state of uploaded videos
  python main.py prune     delete local files that are confirmed VERIFIED
  python main.py status    what is where
  python main.py reconcile check every uploaded video still exists on YouTube

Nothing is ever deleted unless it reached VERIFIED, and prune only runs at all
when delete_after_verify is true in config.json. Leave it false until you have
watched the pipeline work end to end.

  --limit N   on `run`, cap files attempted this run (e.g. --limit 3 for a
              first real run you want to watch closely)
"""

import argparse
import hashlib
import json
import logging
import shutil
import subprocess
import sys
from datetime import datetime, time as dtime, timedelta
from logging.handlers import RotatingFileHandler
from pathlib import Path

import db as dbmod
import selector
import ytclient
from db import (Db, DELETED, FAILED, PROCESSING, QUEUED, UPLOADING, VERIFIED,
                now_iso, pacific_date)

HERE = Path(__file__).parent
VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".avi", ".m4v", ".mts", ".m2ts", ".wmv",
              ".flv", ".webm", ".3gp", ".mpg", ".mpeg"}

log = logging.getLogger("nightshift.main")


# ---------------------------------------------------------------- config

def load_config(path=None):
    path = Path(path or HERE / "config.json")
    if not path.exists():
        sys.exit(f"No config at {path}. Copy config.example.json and edit it.")
    cfg = json.loads(path.read_text(encoding="utf-8"))
    cfg["_dir"] = path.parent
    return cfg


def resolve(cfg, key, default=None):
    """Config paths are relative to the config file unless absolute."""
    p = Path(cfg.get(key, default) if default is not None else cfg[key]).expanduser()
    return p if p.is_absolute() else (cfg["_dir"] / p)


# ---------------------------------------------------------------- logging

def setup_logging(cfg):
    """Rotating file handler so the Pi has a record when a file vanishes
    unattended, plus a console handler so interactive runs still see output.
    db.py logs every state transition with file id, hash, and bytes; this
    just wires up where those lines (and the pipeline's own) end up."""
    log_path = resolve(cfg, "log_file", default="nightshift.log")
    log_path.parent.mkdir(parents=True, exist_ok=True)

    file_handler = RotatingFileHandler(
        log_path, maxBytes=10 * 1024 * 1024, backupCount=5, encoding="utf-8")
    file_handler.setFormatter(logging.Formatter(
        "%(asctime)s %(levelname)-7s %(name)s: %(message)s"))

    console_handler = logging.StreamHandler()
    console_handler.setFormatter(logging.Formatter("%(message)s"))

    root = logging.getLogger("nightshift")
    root.setLevel(logging.INFO)
    root.addHandler(file_handler)
    root.addHandler(console_handler)
    return root


# ---------------------------------------------------------------- window

def parse_hhmm(s):
    h, m = s.split(":")
    return dtime(int(h), int(m))


def in_window(now, start, end):
    if start <= end:
        return start <= now <= end
    return now >= start or now <= end  # wraps past midnight


def seconds_left_in_window(now_dt, start, end):
    today = now_dt.date()
    end_dt = datetime.combine(today, end)
    if start > end and now_dt.time() >= start:
        end_dt += timedelta(days=1)  # window wraps; end is tomorrow
    return max(0, (end_dt - now_dt).total_seconds())


def window_length_seconds(start, end):
    base = datetime(2000, 1, 1)
    s, e = datetime.combine(base, start), datetime.combine(base, end)
    if e <= s:
        e += timedelta(days=1)
    return (e - s).total_seconds()


# ---------------------------------------------------------------- scan

def sha256_file(path, buf=4 * 1024 * 1024):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while chunk := fh.read(buf):
            h.update(chunk)
    return h.hexdigest()


_ffprobe_available = None


def _have_ffprobe():
    global _ffprobe_available
    if _ffprobe_available is None:
        _ffprobe_available = shutil.which("ffprobe") is not None
        if not _ffprobe_available:
            log.info("ffprobe not on PATH; captured_at will fall back to file mtime")
    return _ffprobe_available


def captured_at_for(path):
    """When the video was actually shot, not when this copy of the file was
    made. FIFO order in selector.py depends on this being right, and
    copying a file (phone sync, drive transfer) destroys mtime -- so prefer
    the container's own creation_time tag via ffprobe, falling back to mtime
    only when ffprobe is missing, the tag is absent, or it fails to parse."""
    if _have_ffprobe():
        try:
            out = subprocess.run(
                ["ffprobe", "-v", "quiet", "-print_format", "json",
                 "-show_entries",
                 "format_tags=creation_time:stream_tags=creation_time",
                 str(path)],
                capture_output=True, text=True, timeout=10, check=True,
            )
            data = json.loads(out.stdout)
            raw = data.get("format", {}).get("tags", {}).get("creation_time")
            if not raw:
                for stream in data.get("streams", []):
                    raw = stream.get("tags", {}).get("creation_time")
                    if raw:
                        break
            if raw:
                # ffprobe reports UTC, e.g. "2026-01-01T12:34:56.000000Z".
                dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
                return dt.astimezone().isoformat(timespec="seconds")
        except (subprocess.SubprocessError, json.JSONDecodeError,
                ValueError, OSError) as exc:
            log.debug("ffprobe creation_time lookup failed for %s: %s", path, exc)

    return datetime.fromtimestamp(path.stat().st_mtime).isoformat(timespec="seconds")


def cmd_scan(cfg, conn, args):
    folders = [Path(f).expanduser() for f in cfg["watch_folders"]]
    min_size = cfg.get("min_size_bytes", 1024 * 1024)
    added = skipped = unchanged = 0

    for folder in folders:
        if not folder.exists():
            log.warning("missing watch folder %s", folder)
            continue
        for p in sorted(folder.rglob("*")):
            if not p.is_file() or p.suffix.lower() not in VIDEO_EXTS:
                continue

            st = p.stat()
            size1 = st.st_size
            if size1 < min_size or size1 == 0:  # too small, or still being written
                continue

            # Hashing means reading every byte, which on a card reader full of
            # drone footage is the whole cost of a scan. A file already on
            # record at this exact path, size and mtime cannot have changed
            # content, so skip it -- rescans of a settled folder do no I/O.
            if conn.unchanged_at_path(p, size1, st.st_mtime):
                unchanged += 1
                continue

            digest = sha256_file(p)
            seen = conn.seen_hash(digest)
            if seen:
                if str(p) != conn.get(seen["id"])["path"]:
                    conn.update_path(seen["id"], p, st.st_mtime)
                else:
                    # Same path, same content -- just record the mtime so the
                    # next scan takes the no-I/O path above.
                    conn.set_mtime(seen["id"], st.st_mtime)
                skipped += 1
                continue

            captured = captured_at_for(p)
            conn.add_file(p, digest, size1, captured,  # logs the QUEUED row
                          mtime=st.st_mtime)
            added += 1

    log.info("scan: %s queued, %s already known, %s unchanged (not re-hashed)",
              added, skipped, unchanged)


# ---------------------------------------------------------------- upload

def cmd_run(cfg, conn, args):
    cmd_scan(cfg, conn, args)

    start = parse_hhmm(cfg["window_start"])
    end = parse_hhmm(cfg["window_end"])
    enforce_window = cfg.get("enforce_window", True)
    now = datetime.now()

    if enforce_window and not in_window(now.time(), start, end):
        log.info("outside window %s-%s, nothing to do",
                  cfg['window_start'], cfg['window_end'])
        return

    byte_budget = cfg.get("daily_byte_budget")  # null = unlimited
    count_budget = cfg.get("daily_upload_budget", 100)
    if args.limit is not None:
        # Caps what selector.py is allowed to hand back, same as the daily
        # count budget would -- so a capped first run still gets FIFO order,
        # the oversized-file carve-out, etc. for free instead of a second
        # code path that slices the picks list after the fact.
        count_budget = min(count_budget, args.limit)
        log.info("--limit %s in effect", args.limit)
    rate = cfg.get("max_bytes_per_sec") or 0
    chunk = cfg.get("chunk_size_bytes", 8 * 1024 * 1024)

    usage = conn.usage()
    effective_budget = None
    if byte_budget:
        effective_budget = byte_budget - usage["carry_debt"]
        if usage["carry_debt"]:
            log.info("carrying %.2f GB debt from yesterday",
                      usage['carry_debt'] / 1e9)

    picks = selector.select_for_today(
        conn.queued(), effective_budget, count_budget,
        bytes_used=usage["bytes_used"], uploads_used=usage["uploads_used"])

    if not picks:
        log.info("nothing selected for today")
        return

    total = sum(f["size_bytes"] for f in picks)
    log.info("selected %s file(s), %.2f GB", len(picks), total / 1e9)

    if args.dry_run:
        for f in picks:
            log.info("would upload %s  %.2f GB", f['filename'], f['size_bytes'] / 1e9)
        return

    yt = ytclient.service(resolve(cfg, "client_secret"), resolve(cfg, "token"))
    full_window = window_length_seconds(start, end)

    for f in picks:
        now = datetime.now()
        if enforce_window and not in_window(now.time(), start, end):
            log.info("window closed, stopping between files")
            break

        remaining = f["size_bytes"] - f["bytes_sent"]
        if enforce_window and rate:
            est = remaining / rate
            left = seconds_left_in_window(now, start, end)
            if est > left:
                if est > full_window:
                    # Can never fit a whole window. Run it anyway or it jams
                    # the queue forever; it will overrun into the morning.
                    log.warning("%s needs %.1fh, longer than the window -- "
                                 "running it anyway", f['filename'], est / 3600)
                else:
                    log.info("deferring %s, needs %.1fh and %.1fh left",
                              f['filename'], est / 3600, left / 3600)
                    continue

        upload_one(cfg, conn, yt, f, chunk, rate, start, end, enforce_window)

    conn.carry_debt_forward(byte_budget)
    cmd_verify(cfg, conn, args, yt=yt)
    if cfg.get("delete_after_verify"):
        cmd_prune(cfg, conn, args)


def upload_one(cfg, conn, yt, f, chunk, rate, start, end, enforce_window):
    path = Path(f["path"])
    if not path.exists():
        conn.set_state(f["id"], FAILED)
        conn.note_error(f["id"], "file missing at upload time")
        return

    title = path.stem[:100]
    description = cfg.get("description_template", "Archived: {name}\nSHA256: {sha}") \
        .format(name=path.name, sha=f["sha256"], captured=f["captured_at"] or "")

    conn.set_state(f["id"], UPLOADING)
    log.info("uploading %s (%.2f GB)", f['filename'], f['size_bytes'] / 1e9)

    def stop():
        # Only stops mid-file if the window is badly overrun; a saved
        # resumable URI means tomorrow picks up where this left off.
        if not enforce_window:
            return False
        grace = cfg.get("window_overrun_grace_minutes", 90)
        limit = (datetime.combine(datetime.now().date(), end)
                 + timedelta(minutes=grace))
        return datetime.now() > limit

    try:
        request = ytclient.start_upload(
            yt, path, title, description, cfg.get("category_id", 22), chunk,
            resumable_uri=f["resumable_uri"])
        response = ytclient.pump(
            request, rate,
            on_progress=lambda d: (conn.add_bytes_sent(f["id"], d),
                                   conn.record_usage(sent_bytes=d)),
            on_uri=lambda u: conn.set_resumable_uri(f["id"], u),
            should_stop=stop)
    except Exception as exc:                      # noqa: BLE001
        conn.note_error(f["id"], exc)
        if f["resumable_uri"]:
            conn.set_resumable_uri(f["id"], None)  # stale session, clean restart
        conn.set_state(f["id"], QUEUED if ytclient.is_retriable(exc) else FAILED)
        return

    if response is None:
        conn.set_state(f["id"], QUEUED)
        log.info("%s paused, will resume next run", f['filename'])
        return

    conn.set_state(f["id"], PROCESSING,
                   youtube_id=response["id"], uploaded_at=now_iso(),
                   resumable_uri=None)
    conn.record_usage(uploads=1)


# ---------------------------------------------------------------- verify

def cmd_verify(cfg, conn, args, yt=None):
    pending = conn.in_state(PROCESSING)
    if not pending:
        return
    yt = yt or ytclient.service(resolve(cfg, "client_secret"), resolve(cfg, "token"))

    for f in pending:
        try:
            proc, upload = ytclient.processing_state(yt, f["youtube_id"])
        except Exception as exc:                  # noqa: BLE001
            conn.note_error(f["id"], exc)
            continue

        if proc == "succeeded":
            conn.set_state(f["id"], VERIFIED, verified_at=now_iso())
        elif proc == "failed" or upload in {"failed", "rejected"}:
            conn.set_state(f["id"], FAILED)
            conn.note_error(f["id"], f"processing {proc} / upload {upload}")
        else:
            log.info("%s still processing (%s)", f['filename'], proc)


# ---------------------------------------------------------------- prune

def cmd_prune(cfg, conn, args):
    if not cfg.get("delete_after_verify"):
        log.info("delete_after_verify is false; nothing deleted")
        return

    freed = 0
    for f in conn.in_state(VERIFIED):
        path = Path(f["path"])
        if not f["youtube_id"] or not f["verified_at"]:
            continue  # belt and braces
        if path.exists():
            if args.dry_run:
                log.info("would delete %s", path)
                continue
            path.unlink()
            freed += f["size_bytes"]
        conn.set_state(f["id"], DELETED, deleted_at=now_iso())
    if freed:
        log.info("freed %.2f GB", freed / 1e9)


# ---------------------------------------------------------------- reconcile

def cmd_reconcile(cfg, conn, args, yt=None):
    """Confirm every video we believe is on YouTube is still there.

    Read-only by design. A DELETED row whose video has vanished is
    unrecoverable -- the local copy is already gone -- and a VERIFIED row
    that vanished may still have its file on disk. Which of those to act on
    is a human's call, and the state machine is forward-only anyway, so
    nothing here rewinds a row. It reports; you decide.
    """
    rows = [r for r in list(conn.in_state(VERIFIED)) + list(conn.in_state(DELETED))
            if r["youtube_id"]]
    if not rows:
        log.info("reconcile: nothing uploaded yet, nothing to check")
        return

    yt = yt or ytclient.service(resolve(cfg, "client_secret"), resolve(cfg, "token"))
    found = ytclient.existing_video_ids(yt, [r["youtube_id"] for r in rows])

    gone_deleted = [r for r in rows
                    if r["youtube_id"] not in found and r["state"] == DELETED]
    gone_verified = [r for r in rows
                     if r["youtube_id"] not in found and r["state"] == VERIFIED]

    for r in gone_deleted:
        # Worst case: nothing on YouTube, nothing on disk.
        log.error("MISSING and local copy already deleted: id=%s %s hash=%s "
                  "youtube_id=%s", r["id"], r["filename"], r["sha256"],
                  r["youtube_id"])
    for r in gone_verified:
        on_disk = Path(r["path"]).exists()
        log.error("MISSING from YouTube: id=%s %s youtube_id=%s "
                  "(local copy %s)", r["id"], r["filename"], r["youtube_id"],
                  "still on disk -- can be re-uploaded" if on_disk
                  else "also gone from disk")

    log.info("reconcile: %s checked, %s still on YouTube, %s missing",
             len(rows), len(found), len(gone_deleted) + len(gone_verified))


# ---------------------------------------------------------------- status

def cmd_status(cfg, conn, args):
    # Kept as print(), not logging: this is a human report run on demand,
    # not part of the unattended pipeline -- a timestamp/level prefix on
    # every row of the table would just be noise.
    counts = conn.counts()
    order = [QUEUED, UPLOADING, PROCESSING, VERIFIED, DELETED, FAILED]
    print(f"{'state':<12}{'files':>8}{'size':>12}")
    for state in order:
        n, b = counts.get(state, (0, 0))
        print(f"{state:<12}{n:>8}{b / 1e9:>10.2f} GB")

    u = conn.usage()
    budget = cfg.get("daily_byte_budget")
    print(f"\npacific day {pacific_date()}")
    print(f"  uploads used {u['uploads_used']}/{cfg.get('daily_upload_budget', 100)}")
    if budget:
        print(f"  bytes sent   {u['bytes_used'] / 1e9:.2f} / "
              f"{(budget - u['carry_debt']) / 1e9:.2f} GB")
        if u["carry_debt"]:
            print(f"  carry debt   {u['carry_debt'] / 1e9:.2f} GB")
    else:
        print(f"  bytes sent   {u['bytes_used'] / 1e9:.2f} GB (no cap)")


def cmd_auth(cfg, conn, args):
    ytclient.authorize(resolve(cfg, "client_secret"), resolve(cfg, "token"))
    log.info("token written to %s", resolve(cfg, 'token'))


# ---------------------------------------------------------------- cli

COMMANDS = {"auth": cmd_auth, "scan": cmd_scan, "run": cmd_run,
            "verify": cmd_verify, "prune": cmd_prune, "status": cmd_status,
            "reconcile": cmd_reconcile}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("command", choices=COMMANDS)
    ap.add_argument("--config", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--limit", type=int, default=None,
                     help="run: cap the number of files attempted this run, "
                          "on top of the daily count budget. For watching a "
                          "first real run closely.")
    args = ap.parse_args()

    cfg = load_config(args.config)
    setup_logging(cfg)
    conn = Db(resolve(cfg, "database"))
    try:
        COMMANDS[args.command](cfg, conn, args)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
