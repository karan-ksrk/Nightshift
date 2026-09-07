"""YouTube archive uploader -- Phase 1.

  python main.py auth      one-time OAuth, run on a machine with a browser
  python main.py scan      hash new files in the watch folders, queue them
  python main.py run       scan + upload within the window + verify + prune
  python main.py verify    poll processing state of uploaded videos
  python main.py prune     delete local files that are confirmed VERIFIED
  python main.py status    what is where

Nothing is ever deleted unless it reached VERIFIED, and prune only runs at all
when delete_after_verify is true in config.json. Leave it false until you have
watched the pipeline work end to end.
"""

import argparse
import hashlib
import json
import sys
from datetime import datetime, time as dtime, timedelta
from pathlib import Path

import db as dbmod
import selector
import ytclient
from db import (Db, DELETED, FAILED, PROCESSING, QUEUED, UPLOADING, VERIFIED,
                now_iso, pacific_date)

HERE = Path(__file__).parent
VIDEO_EXTS = {".mp4", ".mov", ".mkv", ".avi", ".m4v", ".mts", ".m2ts", ".wmv",
              ".flv", ".webm", ".3gp", ".mpg", ".mpeg"}


# ---------------------------------------------------------------- config

def load_config(path=None):
    path = Path(path or HERE / "config.json")
    if not path.exists():
        sys.exit(f"No config at {path}. Copy config.example.json and edit it.")
    cfg = json.loads(path.read_text(encoding="utf-8"))
    cfg["_dir"] = path.parent
    return cfg


def resolve(cfg, key):
    """Config paths are relative to the config file unless absolute."""
    p = Path(cfg[key]).expanduser()
    return p if p.is_absolute() else (cfg["_dir"] / p)


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


def cmd_scan(cfg, conn, args):
    folders = [Path(f).expanduser() for f in cfg["watch_folders"]]
    min_size = cfg.get("min_size_bytes", 1024 * 1024)
    added = skipped = 0

    for folder in folders:
        if not folder.exists():
            print(f"  ! missing folder {folder}")
            continue
        for p in sorted(folder.rglob("*")):
            if not p.is_file() or p.suffix.lower() not in VIDEO_EXTS:
                continue
            if p.stat().st_size < min_size:
                continue

            # Skip files still being written to.
            size1 = p.stat().st_size
            if size1 == 0:
                continue

            digest = sha256_file(p)
            seen = conn.seen_hash(digest)
            if seen:
                if str(p) != conn.get(seen["id"])["path"]:
                    conn.update_path(seen["id"], p)
                skipped += 1
                continue

            captured = datetime.fromtimestamp(p.stat().st_mtime).isoformat(
                timespec="seconds")
            conn.add_file(p, digest, size1, captured)
            added += 1
            print(f"  + {p.name}  ({size1 / 1e9:.2f} GB)")

    print(f"scan: {added} queued, {skipped} already known")


# ---------------------------------------------------------------- upload

def cmd_run(cfg, conn, args):
    cmd_scan(cfg, conn, args)

    start = parse_hhmm(cfg["window_start"])
    end = parse_hhmm(cfg["window_end"])
    enforce_window = cfg.get("enforce_window", True)
    now = datetime.now()

    if enforce_window and not in_window(now.time(), start, end):
        print(f"outside window {cfg['window_start']}-{cfg['window_end']}, nothing to do")
        return

    byte_budget = cfg.get("daily_byte_budget")  # null = unlimited
    count_budget = cfg.get("daily_upload_budget", 100)
    rate = cfg.get("max_bytes_per_sec") or 0
    chunk = cfg.get("chunk_size_bytes", 8 * 1024 * 1024)

    usage = conn.usage()
    effective_budget = None
    if byte_budget:
        effective_budget = byte_budget - usage["carry_debt"]
        if usage["carry_debt"]:
            print(f"  carrying {usage['carry_debt'] / 1e9:.2f} GB debt from yesterday")

    picks = selector.select_for_today(
        conn.queued(), effective_budget, count_budget,
        bytes_used=usage["bytes_used"], uploads_used=usage["uploads_used"])

    if not picks:
        print("nothing selected for today")
        return

    total = sum(f["size_bytes"] for f in picks)
    print(f"selected {len(picks)} file(s), {total / 1e9:.2f} GB")

    if args.dry_run:
        for f in picks:
            print(f"  would upload {f['filename']}  {f['size_bytes'] / 1e9:.2f} GB")
        return

    yt = ytclient.service(resolve(cfg, "client_secret"), resolve(cfg, "token"))
    full_window = window_length_seconds(start, end)

    for f in picks:
        now = datetime.now()
        if enforce_window and not in_window(now.time(), start, end):
            print("window closed, stopping between files")
            break

        remaining = f["size_bytes"] - f["bytes_sent"]
        if enforce_window and rate:
            est = remaining / rate
            left = seconds_left_in_window(now, start, end)
            if est > left:
                if est > full_window:
                    # Can never fit a whole window. Run it anyway or it jams
                    # the queue forever; it will overrun into the morning.
                    print(f"  ! {f['filename']} needs {est / 3600:.1f}h, longer "
                          f"than the window -- running it anyway")
                else:
                    print(f"  - deferring {f['filename']}, needs "
                          f"{est / 3600:.1f}h and {left / 3600:.1f}h left")
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
        print(f"  ! {f['filename']} no longer on disk")
        return

    title = path.stem[:100]
    description = cfg.get("description_template", "Archived: {name}\nSHA256: {sha}") \
        .format(name=path.name, sha=f["sha256"], captured=f["captured_at"] or "")

    conn.set_state(f["id"], UPLOADING)
    print(f"  > {f['filename']} ({f['size_bytes'] / 1e9:.2f} GB)")

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
        print(f"  ! failed: {exc}")
        return

    if response is None:
        conn.set_state(f["id"], QUEUED)
        print("  - paused, will resume next run")
        return

    conn.set_state(f["id"], PROCESSING,
                   youtube_id=response["id"], uploaded_at=now_iso(),
                   resumable_uri=None)
    conn.record_usage(uploads=1)
    print(f"  ok {response['id']}")


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
            print(f"  verified {f['filename']} -> {f['youtube_id']}")
        elif proc == "failed" or upload in {"failed", "rejected"}:
            conn.set_state(f["id"], FAILED)
            conn.note_error(f["id"], f"processing {proc} / upload {upload}")
            print(f"  ! rejected {f['filename']}")
        else:
            print(f"  ... {f['filename']} still processing ({proc})")


# ---------------------------------------------------------------- prune

def cmd_prune(cfg, conn, args):
    if not cfg.get("delete_after_verify"):
        print("delete_after_verify is false; nothing deleted")
        return

    freed = 0
    for f in conn.in_state(VERIFIED):
        path = Path(f["path"])
        if not f["youtube_id"] or not f["verified_at"]:
            continue  # belt and braces
        if path.exists():
            if args.dry_run:
                print(f"  would delete {path}")
                continue
            path.unlink()
            freed += f["size_bytes"]
        conn.set_state(f["id"], DELETED, deleted_at=now_iso())
        print(f"  deleted {f['filename']}")
    if freed:
        print(f"freed {freed / 1e9:.2f} GB")


# ---------------------------------------------------------------- status

def cmd_status(cfg, conn, args):
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
    print(f"token written to {resolve(cfg, 'token')}")


# ---------------------------------------------------------------- cli

COMMANDS = {"auth": cmd_auth, "scan": cmd_scan, "run": cmd_run,
            "verify": cmd_verify, "prune": cmd_prune, "status": cmd_status}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("command", choices=COMMANDS)
    ap.add_argument("--config", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    cfg = load_config(args.config)
    conn = Db(resolve(cfg, "database"))
    try:
        COMMANDS[args.command](cfg, conn, args)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
