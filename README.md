# yt-archiver — Phase 1

Uploads a folder of videos to YouTube as **private**, verifies each one finished
processing, and only then deletes the local copy. Runs on Windows now, moves to
the Pi unchanged later.

## Setup

```bash
pip install -r requirements.txt
cp config.example.json config.json     # then edit watch_folders
```

### Google Cloud, in this order

1. New project → enable **YouTube Data API v3**.
2. **OAuth consent screen** → External → **set publishing status to "In production"**.
   Do this *before* step 4. A token minted while the project is in "Testing"
   expires 7 days after consent and stays on that clock even if you flip the
   setting later. You do not need verification — personal use under 100 users
   just clicks through the "unverified app" warning once.
3. Credentials → **OAuth client ID** → type **Desktop app** → download JSON,
   save it next to `config.json` as `client_secret.json`.
4. `python main.py auth` — browser opens, approve, `token.json` appears.

Copy `token.json` and `client_secret.json` to the Pi later; the refresh token is
tied to your account and OAuth client, not the machine.

## Use

```bash
python main.py scan              # hash + queue new files
python main.py run --dry-run     # show what today would upload
python main.py run               # scan, upload, verify, (prune if enabled)
python main.py status            # queue + quota ledger
```

Leave `delete_after_verify` as `false` until you have watched a few files go
all the way to VERIFIED. Then flip it on.

## Config

| Key | Notes |
|---|---|
| `daily_byte_budget` | Bytes/day. `null` = unlimited, let the window and rate limit do the work. |
| `daily_upload_budget` | 100 — the videos.insert bucket. Leave it. |
| `enforce_window` | `false` while testing on Windows during the day. |
| `window_start` / `window_end` | Local time. Wrapping past midnight is handled. |
| `max_bytes_per_sec` | Throttle between chunks. 2 MB/s ≈ 16 Mbit. |
| `delete_after_verify` | The safety catch. |

## Behaviour worth knowing

- **Dedupe is by SHA-256, not filename.** Re-scanning is free; a file that moves
  on disk updates its row rather than uploading twice.
- **Selection is FIFO with a fit check, not bin-packing.** If the next file
  doesn't fit today's remaining budget it *stops* rather than skipping ahead to
  a smaller one — skipping is what starves large files forever.
- **A file larger than a whole day's budget** gets the day to itself, and the
  overage is billed to tomorrow as `carry_debt`.
- **Interrupted uploads resume.** The resumable session URI is stored per file;
  a 6 GB video that dies at 90% picks up there next run. Session URIs last about
  a week — if one goes stale the file restarts cleanly.
- **`bytes_used` counts bytes actually transmitted**, retries included, which is
  what matters if your budget is an ISP data cap.
- **Rows are never deleted.** After the local file is gone the row remains with
  its hash and YouTube ID. That table is your manifest.

## Known limits (Phase 1)

- `captured_at` comes from file mtime. Real capture time needs EXIF/mediainfo —
  worth adding if your mtimes are unreliable after copying.
- Scan is single-threaded hashing; a large first run over 500 GB will take a
  while. It's I/O bound, and only happens once per file.
- Videos are locked private because the API project is unverified. Expected.
