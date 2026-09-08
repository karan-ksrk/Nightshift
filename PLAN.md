# PLAN.md

Roadmap. Phase 1 is done. Work top to bottom — each phase assumes the one below
it is boring and proven.

Rule of thumb: **don't start a phase until the previous one has run unattended
for a week without you touching it.** Every phase adds a place for videos to get
lost, and the last step of the pipeline deletes originals.

---

## Phase 1 — Pi→YouTube uploader (DONE, needs hardening)

Working CLI. Scans folders, hashes, queues, uploads within a time window at a
throttled rate, verifies processing, optionally deletes.

### Remaining work

- [x] **Port the ad-hoc checks into `pytest`.** See CLAUDE.md § Testing.
- [x] **Structured logging** to a rotating file, not `print()`. The Pi runs this
      unattended; when a file vanishes you need to know why. Log every state
      transition with file id, hash, and bytes.
- [x] **`--limit N` flag** on `run`, so a first real run can be capped at 2–3
      files while you watch it.
- [ ] **Handle disk-full on the Pi** during Phase 2 receive. Currently unhandled.
- [x] **`captured_at` from metadata** rather than mtime — `ffprobe`
      creation_time, fall back to mtime. Matters because FIFO ordering is by
      this field, and copying files destroys mtime.
- [ ] **`reconcile` command**: for every row in VERIFIED/DELETED, confirm the
      YouTube ID still exists. Catches silent removals. Cheap — `videos.list`
      batches 50 IDs for 1 unit.

### Acceptance before moving on

Runs nightly from Task Scheduler (or systemd timer) for a week, `delete_after_verify`
on, no manual intervention, `status` reconciles with what's on the channel.

---

## Phase 2 — Pi HTTP server

Wrap the existing pipeline in an API so the phone can feed it. The state machine
and selector carry over unchanged.

### Tasks

- [ ] FastAPI app, uvicorn behind systemd. Bind to LAN only.
- [ ] `POST /upload/init` → returns an upload id; body carries filename, size,
      client-computed SHA-256, captured_at. **Reject if the hash is already
      known** — that's free dedupe from the phone side.
- [ ] `PUT /upload/{id}/chunk` with a `Content-Range` header. Append to a
      `.part` file. Idempotent per offset so a retried chunk is harmless.
- [ ] `POST /upload/{id}/complete` → server re-hashes the assembled file,
      compares to the client's hash, and only then moves it into the watch
      folder and inserts a QUEUED row. Mismatch = 409 and the phone re-sends.
- [ ] `GET /upload/{id}/offset` → resume point after the phone dies mid-transfer.
- [ ] `GET /status` → counts by state, today's ledger, estimated days to drain.
- [ ] `GET /files?state=` → paginated, for the app's list views.
- [ ] Shared-secret auth header. This is LAN-only, so a static token in config is
      proportionate — don't build user accounts.
- [ ] Tailscale for access from outside the house. Free tier, no port forwarding.

### Acceptance

`curl` a 4 GB file up in chunks, kill it halfway, resume, complete, and watch it
appear in the queue and upload overnight.

---

## Phase 3 — Flutter app, manual mode

No background work at all. Prove the transport before adding Android's
scheduling problems on top.

### Tasks

- [ ] Server config screen: host, port, token. Persist it.
- [ ] Manual file picker → select videos → upload with a visible progress bar.
- [ ] Chunked upload against the Phase 2 endpoints, with resume.
- [ ] Local SQLite mirroring what's been sent (hash, server upload id, state).
- [ ] Status screen polling `GET /status`. Pull to refresh.
- [ ] Verify-then-delete on the phone side too: only unlink after the server
      confirms the hash matched.

### Acceptance

Send 10 videos from the phone over WiFi, see them appear on the Pi, watch them
reach VERIFIED overnight.

---

## Phase 4 — Background automation

The hardest phase. Android actively fights long-running background work.

### Tasks

- [ ] Folder selection via Storage Access Framework, multiple folders, with
      persisted URI permissions. (`MANAGE_EXTERNAL_STORAGE` is simpler but Play
      Store rejects it — fine if sideloading, decide deliberately.)
- [ ] `WorkManager` periodic scan (~15 min minimum, that's the platform floor),
      constrained to **unmetered network + charging**. On wake, diff the folder
      against local SQLite.
- [ ] **Foreground service** for the actual transfer with an ongoing
      notification, or Android kills it mid-upload.
- [ ] Battery-optimisation exemption prompt, with an explanation screen. Without
      it, aggressive OEM skins (Xiaomi, Oppo, OnePlus) will kill the worker
      silently.
- [ ] Auto-delete from phone after server-confirmed hash match, behind a setting
      that defaults **off**.
- [ ] Daily summary notification. Poll on WorkManager wake — FCM only if you
      genuinely want push when the app is closed.

### Acceptance

Drop a video in the watched folder, plug the phone in, walk away. It's on
YouTube by morning and gone from the phone.

---

## Explicitly out of scope

- Making videos unlisted or public. Not possible via API here — see CLAUDE.md.
- Browser automation to bypass the API. Against YouTube's ToS.
- Multi-user, cloud hosting, or a public web UI. This is one person's archive.
- Re-encoding before upload. YouTube re-encodes anyway; doing it twice is worse.

## Open questions

- **Is YouTube actually the right destination?** It re-encodes everything, the
  originals don't come back, and a channel termination takes the whole archive.
  Worth revisiting once the pipeline works — the manifest table makes switching
  destinations tractable, since you'd know exactly what needs re-homing.
- Is 10 GB/day an ISP cap or a bandwidth preference? Decides whether
  `daily_byte_budget` stays set or goes `null` with the window doing the work.
  Log `bytes_used` for a week before deciding.
