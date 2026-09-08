# CLAUDE.md

Context for Claude Code working on this repo. Read before changing anything.

## What this is

A personal video archiver. Videos pile up on a PC and a phone; disk fills. This
pipeline uploads them to YouTube as private videos, verifies each finished
processing, and only then deletes the local copy.

Three tiers, built in order:

```
Phone (Flutter)  ──WiFi──>  Pi (FastAPI + SQLite + 500GB SSD)  ──>  YouTube
   watch folders               queue + scheduler + verifier
   chunked upload              delete only after confirmed
   poll status                 status API back to phone
```

Phase 1 (the Pi→YouTube leg, CLI only) is built and working. Phases 2–4 are not
started. See PLAN.md.

## Hard constraints — do not re-litigate these

These were researched and decided. If a change seems to require breaking one,
stop and ask rather than working around it.

**Uploads: 100/day, free.** `videos.insert` costs 1 unit in its own "Video
Uploads" bucket since June 2026, capped at 100 calls/day. It does *not* draw on
the shared 10,000-unit pool. Any code comment or doc claiming 1,600 units and
6 uploads/day is from before December 2025 and is wrong.

**Videos are locked private, permanently.** Uploads via `videos.insert` from an
unverified API project are restricted to private viewing mode. This cannot be
changed to unlisted or public afterwards, and there is no appeal. Lifting it
needs a compliance audit that personal projects don't pass. **This is accepted,
not a bug.** Do not add a `privacyStatus` config option; do not attempt
workarounds involving browser automation (against YouTube's ToS).

**OAuth consent screen must be "In production".** Projects in "Testing" issue
authorizations that expire 7 days after consent, taking the refresh token with
them. Fatal on an unattended Pi. No verification needed — personal use under
100 users clicks through the unverified-app warning once.

**Never delete before verification.** A file is unlinked only after
`videos.list` reports `processingDetails.processingStatus == "succeeded"`. The
`delete_after_verify` config flag is a second safety catch on top of that.

## Invariants

- **Rows in `files` are never deleted.** After the local file is gone the row
  remains with its hash, size and YouTube ID. That table is the only manifest of
  what exists on YouTube and what is gone from disk.
- **Identity is SHA-256, not filename or path.** Re-scanning must be idempotent.
  A file that moves updates `path` on the existing row.
- **Selection is FIFO with a fit check, never bin-packing.** When the next file
  doesn't fit the remaining budget, `break` — do not `continue`. Skipping ahead
  to a smaller file that fits is what starves large files forever. There is a
  test for this; if you "optimise" the selector you will break it.
- **`bytes_used` counts bytes actually transmitted**, retries included, because
  the budget may be an ISP data cap rather than a preference.
- **Quota days are Pacific**, not local. `daily_usage` is keyed by PT date.
- State machine is forward-only:
  `QUEUED → UPLOADING → PROCESSING → VERIFIED → DELETED`, with `FAILED` as a
  sink. Retriable errors return a file to `QUEUED`.

## Conventions

- Python 3.11+, stdlib-first. Current deps are only the Google client libs.
- `pathlib.Path` everywhere. Never string-concatenate paths. This runs on both
  Windows and Linux and must stay portable.
- All paths, budgets and windows come from `config.json`. Nothing hardcoded.
- No ORM, no migrations framework. `CREATE TABLE IF NOT EXISTS` in `db.py`; add
  columns with an explicit `ALTER TABLE` guard if needed.
- Comments explain *why*, especially where the non-obvious choice was
  deliberate. Don't strip the rationale comments in `selector.py`.

## Files

| File | Role |
|---|---|
| `main.py` | CLI: `auth`, `scan`, `run`, `verify`, `prune`, `status`. Window logic lives here. |
| `db.py` | Schema, state transitions, daily usage ledger, carry-debt. |
| `selector.py` | Which files go today. Small and deliberate — read the docstring. |
| `ytclient.py` | OAuth, resumable throttled upload, processing check. |
| `config.example.json` | Template. Real `config.json` is gitignored. |

## Testing

There is no test suite yet — **adding one is the first task in PLAN.md.** The
logic was verified ad-hoc; port those checks into `pytest`. Priorities:

- selector: no-skip on non-fit, oversized file gets the day alone, count cap,
  exhausted budget
- window maths: wrapping past midnight, seconds remaining, window length
- db: hash dedupe, path update, carry-debt arithmetic, manifest survives delete

Never test against the real YouTube API — mock `ytclient`. Quota is 100/day and
uploads are irreversible.

## Gotchas

- `tzdata` is needed on Windows for `zoneinfo`.
- Resumable session URIs last about a week. If one is stale, clear it and
  restart the file cleanly rather than retrying the URI.
- `captured_at` comes from the container's `creation_time` tag via `ffprobe`
  (`main.py:captured_at_for`), falling back to file mtime when `ffprobe` isn't
  on PATH or the tag is missing/unparsable. mtime alone was wrong because
  copying (phone sync, drive transfer) destroys it, and FIFO order depends on
  this field. `ffprobe` is a soft dependency -- not in requirements.txt, no
  hard failure if absent, just a quieter fallback to mtime.
- Don't add an artificial delay between files. The rate limit and time window
  already pace uploads; a fixed gap just wastes window time.
