"""YouTube Data API v3 wrapper: auth, resumable upload, processing check.

Quota notes (current as of the 2026 changes):
  videos.insert  -- 1 unit in its own "Video Uploads" bucket, 100 calls/day.
                    It no longer draws on the shared 10,000-unit pool.
  videos.list    -- 1 unit from the shared pool. Cheap; poll freely.

Videos uploaded from an unverified API project are locked to PRIVATE and
cannot be changed to unlisted or public afterwards. That is expected here.
"""

import time
from pathlib import Path

import googleapiclient.errors
import httplib2
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

SCOPES = ["https://www.googleapis.com/auth/youtube.upload",
          "https://www.googleapis.com/auth/youtube.readonly"]

# Errors worth retrying on a later run rather than burning attempts now.
RETRIABLE_STATUS = {500, 502, 503, 504}


def authorize(client_secret_path, token_path):
    """Run once interactively on a machine with a browser.

    Set the OAuth consent screen to 'In production' BEFORE doing this. A token
    minted while the project is in 'Testing' expires 7 days after consent and
    stays on that clock even if you flip the setting afterwards.
    """
    token_path = Path(token_path)
    creds = None
    if token_path.exists():
        creds = Credentials.from_authorized_user_file(str(token_path), SCOPES)

    if creds and creds.valid:
        return creds
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    else:
        flow = InstalledAppFlow.from_client_secrets_file(
            str(client_secret_path), SCOPES)
        creds = flow.run_local_server(port=0)

    token_path.parent.mkdir(parents=True, exist_ok=True)
    token_path.write_text(creds.to_json(), encoding="utf-8")
    return creds


def service(client_secret_path, token_path):
    creds = authorize(client_secret_path, token_path)
    return build("youtube", "v3", credentials=creds, cache_discovery=False)


def start_upload(yt, path, title, description, category_id, chunk_size,
                 resumable_uri=None):
    """Build the insert request. If resumable_uri is supplied, the transfer
    picks up where the last run stopped instead of restarting the file."""
    media = MediaFileUpload(str(path), chunksize=chunk_size, resumable=True)
    body = {
        "snippet": {
            "title": title[:100],
            "description": description[:5000],
            "categoryId": str(category_id),
        },
        "status": {
            "privacyStatus": "private",
            "selfDeclaredMadeForKids": False,
        },
    }
    request = yt.videos().insert(part="snippet,status", body=body, media_body=media)
    if resumable_uri:
        # Session URIs are valid about a week. If it has expired the first
        # next_chunk() raises and the caller clears it for a clean restart.
        request.resumable_uri = resumable_uri
    return request


def pump(request, max_bytes_per_sec, on_progress=None, on_uri=None,
         should_stop=None):
    """Drive the resumable upload to completion, throttled between chunks.

    on_progress(delta_bytes) is called with bytes actually transmitted, so
    retried chunks are counted twice -- which is what you want if the budget
    is a data cap.
    """
    response = None
    last_progress = 0
    uri_reported = False

    while response is None:
        if should_stop and should_stop():
            return None  # caller can resume later from the saved URI

        t0 = time.monotonic()
        status, response = request.next_chunk()

        if not uri_reported and on_uri and getattr(request, "resumable_uri", None):
            on_uri(request.resumable_uri)
            uri_reported = True

        if status:
            delta = status.resumable_progress - last_progress
            last_progress = status.resumable_progress
            if delta > 0 and on_progress:
                on_progress(delta)

        if max_bytes_per_sec and status:
            # chunksize() is a method on MediaUpload, not a property. Reading
            # it without the call gives a bound method and the division below
            # raises TypeError -- which only ever bit multi-chunk uploads,
            # since a file smaller than one chunk never sets `status`.
            chunk = request.resumable.chunksize()
            target = chunk / max_bytes_per_sec
            elapsed = time.monotonic() - t0
            if elapsed < target:
                time.sleep(target - elapsed)

    # The call that completes the upload returns (None, response), so the
    # final chunk never arrives as a status and its bytes would go unbilled --
    # a file smaller than one chunk would report nothing at all. Settle up
    # against the declared size so bytes_used really is what went on the wire.
    if on_progress:
        total = request.resumable.size() if request.resumable else None
        if total and total > last_progress:
            on_progress(total - last_progress)

    return response


def processing_state(yt, video_id):
    """Returns (processing_status, upload_status).

    Delete the local file only when processing_status == 'succeeded'.
    """
    resp = yt.videos().list(part="status,processingDetails", id=video_id).execute()
    items = resp.get("items", [])
    if not items:
        return None, None
    item = items[0]
    return (
        item.get("processingDetails", {}).get("processingStatus"),
        item.get("status", {}).get("uploadStatus"),
    )


def existing_video_ids(yt, video_ids):
    """Which of these IDs YouTube still returns.

    videos.list takes up to 50 ids per call for 1 unit from the shared pool,
    so checking a whole archive costs single-digit units. Anything absent
    from the response no longer exists on the channel.
    """
    ids = list(video_ids)
    found = set()
    for i in range(0, len(ids), 50):
        resp = yt.videos().list(part="id", id=",".join(ids[i:i + 50])).execute()
        for item in resp.get("items", []):
            found.add(item["id"])
    return found


def is_retriable(exc):
    if isinstance(exc, googleapiclient.errors.HttpError):
        return exc.resp.status in RETRIABLE_STATUS
    # DNS resolution failures come from httplib2 (the transport googleapiclient
    # actually uses) as httplib2.ServerNotFoundError, "Unable to find the
    # server at <host>" -- a subclass of HttpLib2Error/Exception, NOT of
    # OSError, ConnectionError or socket.gaierror despite being exactly that
    # class of transient network failure. Found the hard way: a DNS hiccup
    # (here, a Tailscale MagicDNS blip -- resolv.conf points solely at
    # 100.100.100.100 with no fallback) sank 7 files straight to FAILED after
    # a single attempt each, when every one of them was retriable.
    if isinstance(exc, httplib2.ServerNotFoundError):
        return True
    return isinstance(exc, (ConnectionError, TimeoutError, OSError))
