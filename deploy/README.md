# Pi deployment

The Pi is the only machine that talks to YouTube. The quota (100 uploads/day)
belongs to the Google Cloud project, not the machine, so two pipelines running
independently would each think they had the full 100 and blow past the real
shared limit. One uploader, one `archive.db`, one ledger.

## Layout

```
/home/ksrk/nightshift/          repo clone
  venv/                         python3 -m venv venv
  config.json                   gitignored; see config.example.json
  client_secret.json            gitignored; copied from the machine that ran `auth`
  token.json                    gitignored; ditto -- the refresh token works from anywhere
  archive.db                    the manifest; migrated, not regenerated
  incoming/                     watch folder (also where server.py lands uploads)
  nightshift.log                rotating, 10MB x 5
```

## Units

| Unit | What |
|---|---|
| `nightshift-run.service` | oneshot: `main.py run` — scan, upload, verify, prune |
| `nightshift-run.timer` | fires it at 01:05 daily, inside the config's upload window. `Persistent=true` so a missed run (Pi off) fires on next boot |
| `nightshift-server.service` | uvicorn serving `server.py` on :8000 for phone uploads |

```sh
sudo cp deploy/*.service deploy/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nightshift-server.service
sudo systemctl enable --now nightshift-run.timer
```

Check: `systemctl list-timers nightshift-run.timer`, `journalctl -u nightshift-server -f`,
and `nightshift.log` for the pipeline's own record of every state transition.

## Don't enable the timer before the footage is actually here

Rows whose `path` points at a machine the Pi can't see log a warning and stay
`QUEUED` (they are not sunk into `FAILED` — see CLAUDE.md), but there is no
point running against an archive that isn't local yet.

Files can arrive in any order: identity is the SHA-256, so `main.py scan`
re-links a moved file to its new path automatically instead of re-queueing it.
The copy also doesn't need to finish first — the pipeline only consumes
`daily_byte_budget` per day, which any working link outruns comfortably.

## Network note

The Pi's 2.4GHz WiFi measured ~1.1 MB/s to the desktop. `eth0` reports a
gigabit carrier; putting the Pi on wired ethernet is worth roughly two orders
of magnitude on bulk transfers.
