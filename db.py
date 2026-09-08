"""SQLite state store for the archiver.

The files table is the manifest. Rows are NEVER deleted, even after the local
file is unlinked -- it is the only record of what exists on YouTube and what
is gone from disk.
"""

import logging
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

# Google's quota buckets reset at midnight Pacific, not your local midnight.
PACIFIC = ZoneInfo("America/Los_Angeles")

log = logging.getLogger("nightshift.db")

# State machine. Forward-only.
RECEIVED = "RECEIVED"
QUEUED = "QUEUED"
UPLOADING = "UPLOADING"
PROCESSING = "PROCESSING"
VERIFIED = "VERIFIED"
DELETED = "DELETED"
FAILED = "FAILED"

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    id            INTEGER PRIMARY KEY,
    path          TEXT    NOT NULL,
    filename      TEXT    NOT NULL,
    sha256        TEXT    NOT NULL UNIQUE,
    size_bytes    INTEGER NOT NULL,
    captured_at   TEXT,
    received_at   TEXT    NOT NULL,
    state         TEXT    NOT NULL,
    attempts      INTEGER NOT NULL DEFAULT 0,
    last_error    TEXT,
    resumable_uri TEXT,
    bytes_sent    INTEGER NOT NULL DEFAULT 0,
    youtube_id    TEXT,
    uploaded_at   TEXT,
    verified_at   TEXT,
    deleted_at    TEXT
);
CREATE INDEX IF NOT EXISTS idx_files_state ON files(state);
CREATE INDEX IF NOT EXISTS idx_files_captured ON files(captured_at);

CREATE TABLE IF NOT EXISTS daily_usage (
    pt_date      TEXT PRIMARY KEY,
    bytes_used   INTEGER NOT NULL DEFAULT 0,
    uploads_used INTEGER NOT NULL DEFAULT 0,
    carry_debt   INTEGER NOT NULL DEFAULT 0
);
"""


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def pacific_date(when=None):
    """The quota day a moment belongs to."""
    when = when or datetime.now(timezone.utc)
    return when.astimezone(PACIFIC).date().isoformat()


def next_pacific_date(pt_date):
    d = datetime.fromisoformat(pt_date).date() + timedelta(days=1)
    return d.isoformat()


class Db:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(self.path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.executescript(SCHEMA)
        self.conn.commit()

    def close(self):
        self.conn.close()

    # ---------- intake ----------

    def seen_hash(self, sha256):
        row = self.conn.execute(
            "SELECT id, state FROM files WHERE sha256 = ?", (sha256,)
        ).fetchone()
        return row

    def add_file(self, path, sha256, size_bytes, captured_at):
        path = Path(path)
        cur = self.conn.execute(
            """INSERT INTO files
               (path, filename, sha256, size_bytes, captured_at, received_at, state)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (str(path), path.name, sha256, size_bytes,
             captured_at, now_iso(), QUEUED),
        )
        self.conn.commit()
        log.info("queued id=%s hash=%s size=%s path=%s",
                  cur.lastrowid, sha256, size_bytes, path)
        return cur.lastrowid

    def update_path(self, file_id, path):
        """Same content, moved on disk. Keep the row, fix the pointer."""
        self.conn.execute(
            "UPDATE files SET path = ?, filename = ? WHERE id = ?",
            (str(path), Path(path).name, file_id),
        )
        self.conn.commit()
        log.info("path updated id=%s new_path=%s", file_id, path)

    # ---------- queue ----------

    def queued(self):
        """Oldest capture first. FIFO is the point -- see selector.py."""
        return self.conn.execute(
            """SELECT * FROM files
               WHERE state IN (?, ?)
               ORDER BY COALESCE(captured_at, received_at) ASC, id ASC""",
            (QUEUED, UPLOADING),
        ).fetchall()

    def in_state(self, state):
        return self.conn.execute(
            "SELECT * FROM files WHERE state = ? ORDER BY id", (state,)
        ).fetchall()

    def get(self, file_id):
        return self.conn.execute(
            "SELECT * FROM files WHERE id = ?", (file_id,)
        ).fetchone()

    def set_state(self, file_id, state, **fields):
        # Fetched before the write so the log line always carries hash and
        # size even if this is the last thing recorded about the row (e.g.
        # DELETED) -- that's the whole point of logging every transition.
        before = self.get(file_id)

        cols = ", ".join(f"{k} = ?" for k in fields)
        sql = f"UPDATE files SET state = ?{', ' + cols if cols else ''} WHERE id = ?"
        self.conn.execute(sql, (state, *fields.values(), file_id))
        self.conn.commit()

        extra = " ".join(f"{k}={v}" for k, v in fields.items())
        log.info("id=%s hash=%s size=%s state %s -> %s%s",
                  file_id,
                  before["sha256"] if before else "?",
                  before["size_bytes"] if before else "?",
                  before["state"] if before else "?",
                  state,
                  f" ({extra})" if extra else "")

    def note_error(self, file_id, message):
        row = self.get(file_id)
        self.conn.execute(
            "UPDATE files SET attempts = attempts + 1, last_error = ? WHERE id = ?",
            (str(message)[:500], file_id),
        )
        self.conn.commit()
        log.warning("id=%s hash=%s error: %s",
                     file_id, row["sha256"] if row else "?", message)

    def set_resumable_uri(self, file_id, uri):
        self.conn.execute(
            "UPDATE files SET resumable_uri = ? WHERE id = ?", (uri, file_id)
        )
        self.conn.commit()

    def add_bytes_sent(self, file_id, delta):
        """Bytes actually put on the wire, retries included."""
        self.conn.execute(
            "UPDATE files SET bytes_sent = bytes_sent + ? WHERE id = ?",
            (int(delta), file_id),
        )
        self.conn.commit()

    # ---------- daily ledger ----------

    def usage(self, pt_date=None):
        pt_date = pt_date or pacific_date()
        row = self.conn.execute(
            "SELECT * FROM daily_usage WHERE pt_date = ?", (pt_date,)
        ).fetchone()
        if row is None:
            self.conn.execute(
                "INSERT INTO daily_usage (pt_date) VALUES (?)", (pt_date,)
            )
            self.conn.commit()
            row = self.conn.execute(
                "SELECT * FROM daily_usage WHERE pt_date = ?", (pt_date,)
            ).fetchone()
        return row

    def record_usage(self, sent_bytes=0, uploads=0, pt_date=None):
        pt_date = pt_date or pacific_date()
        self.usage(pt_date)
        self.conn.execute(
            """UPDATE daily_usage
               SET bytes_used = bytes_used + ?, uploads_used = uploads_used + ?
               WHERE pt_date = ?""",
            (int(sent_bytes), int(uploads), pt_date),
        )
        self.conn.commit()

    def carry_debt_forward(self, byte_budget, pt_date=None):
        """An oversized file is allowed to blow through today's budget.
        Tomorrow pays it back. Without this, files larger than the daily
        budget jam the queue permanently."""
        if not byte_budget:
            return 0
        pt_date = pt_date or pacific_date()
        u = self.usage(pt_date)
        effective = byte_budget - u["carry_debt"]
        debt = max(0, u["bytes_used"] - effective)
        if debt:
            tomorrow = next_pacific_date(pt_date)
            self.usage(tomorrow)
            self.conn.execute(
                "UPDATE daily_usage SET carry_debt = ? WHERE pt_date = ?",
                (debt, tomorrow),
            )
            self.conn.commit()
        return debt

    def counts(self):
        rows = self.conn.execute(
            "SELECT state, COUNT(*) n, SUM(size_bytes) b FROM files GROUP BY state"
        ).fetchall()
        return {r["state"]: (r["n"], r["b"] or 0) for r in rows}
