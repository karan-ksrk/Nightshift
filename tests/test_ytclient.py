"""ytclient.pump -- the resumable upload loop, with a fake request object.

Never talks to the real YouTube API (CLAUDE.md: quota is 100/day and uploads
are irreversible). The fakes below mimic googleapiclient's shapes exactly
where it matters -- in particular MediaUpload.chunksize is a *method*, which
is what the throttle path got wrong and only failed on multi-chunk files.
"""

import pytest

import ytclient


class FakeStatus:
    def __init__(self, resumable_progress):
        self.resumable_progress = resumable_progress


class FakeResumable:
    def __init__(self, chunksize=8 * 1024 * 1024, size=400):
        self._chunksize = chunksize
        self._size = size

    def chunksize(self):          # a method, exactly like MediaUpload's
        return self._chunksize

    def size(self):               # likewise a method
        return self._size


class FakeRequest:
    """Yields `chunks` progress updates, then completes with `response`."""

    def __init__(self, chunks, response=None, uri="https://upload.example/session",
                 size=400):
        self.resumable = FakeResumable(size=size)
        self.resumable_uri = uri
        self._progress = list(chunks)
        self._response = response or {"id": "vid123"}
        self.calls = 0

    def next_chunk(self):
        self.calls += 1
        if self._progress:
            return FakeStatus(self._progress.pop(0)), None
        return None, self._response


def test_multi_chunk_upload_with_throttle(monkeypatch):
    """The regression: a file spanning several chunks, with a byte-rate cap
    set, used to raise TypeError on `method / int`."""
    monkeypatch.setattr(ytclient.time, "sleep", lambda s: None)
    request = FakeRequest(chunks=[1000, 2000, 3000])

    response = ytclient.pump(request, max_bytes_per_sec=2 * 1024 * 1024)

    assert response == {"id": "vid123"}


def test_single_chunk_upload_with_throttle(monkeypatch):
    """A file smaller than one chunk completes without ever setting `status`,
    which is why it dodged the bug above. Keep both paths covered."""
    monkeypatch.setattr(ytclient.time, "sleep", lambda s: None)
    request = FakeRequest(chunks=[])

    response = ytclient.pump(request, max_bytes_per_sec=2 * 1024 * 1024)

    assert response == {"id": "vid123"}


def test_progress_reports_deltas_not_totals(monkeypatch):
    """on_progress gets bytes actually transmitted since the last call --
    db.add_bytes_sent/record_usage accumulate, so totals would double-count."""
    monkeypatch.setattr(ytclient.time, "sleep", lambda s: None)
    request = FakeRequest(chunks=[100, 250, 400], size=400)
    seen = []

    ytclient.pump(request, max_bytes_per_sec=0, on_progress=seen.append)

    assert seen == [100, 150, 150]
    assert sum(seen) == 400  # every byte of the file billed exactly once


def test_final_chunk_bytes_are_billed(monkeypatch):
    """The completing call returns (None, response), so the last chunk never
    arrives as a status. Those bytes still went on the wire and must be
    counted -- bytes_used may be an ISP data cap, not a preference."""
    monkeypatch.setattr(ytclient.time, "sleep", lambda s: None)
    request = FakeRequest(chunks=[100, 200], size=500)
    seen = []

    ytclient.pump(request, max_bytes_per_sec=0, on_progress=seen.append)

    assert sum(seen) == 500      # not 200
    assert seen[-1] == 300       # the unreported tail


def test_single_chunk_upload_bills_its_bytes(monkeypatch):
    """A file smaller than one chunk produces no status at all, so without
    the settle-up it would upload entirely for free on the ledger."""
    monkeypatch.setattr(ytclient.time, "sleep", lambda s: None)
    request = FakeRequest(chunks=[], size=4365709)
    seen = []

    ytclient.pump(request, max_bytes_per_sec=0, on_progress=seen.append)

    assert seen == [4365709]


def test_no_overbilling_when_progress_already_complete(monkeypatch):
    """If the last status already reported the full size, don't bill twice."""
    monkeypatch.setattr(ytclient.time, "sleep", lambda s: None)
    request = FakeRequest(chunks=[200, 500], size=500)
    seen = []

    ytclient.pump(request, max_bytes_per_sec=0, on_progress=seen.append)

    assert sum(seen) == 500
    assert seen == [200, 300]


def test_resumable_uri_reported_once(monkeypatch):
    """The URI is saved so a stopped upload resumes tomorrow instead of
    restarting the file; reporting it repeatedly would just churn the db."""
    monkeypatch.setattr(ytclient.time, "sleep", lambda s: None)
    request = FakeRequest(chunks=[100, 200])
    uris = []

    ytclient.pump(request, max_bytes_per_sec=0, on_uri=uris.append)

    assert uris == ["https://upload.example/session"]


def test_should_stop_pauses_before_completing(monkeypatch):
    """Window badly overrun: pump returns None so the caller can requeue and
    resume from the saved URI rather than losing the transfer."""
    monkeypatch.setattr(ytclient.time, "sleep", lambda s: None)
    request = FakeRequest(chunks=[100, 200, 300])

    response = ytclient.pump(request, max_bytes_per_sec=0,
                             should_stop=lambda: request.calls >= 2)

    assert response is None
    assert request.calls == 2  # stopped, did not drain the whole file


def test_throttle_sleeps_by_chunksize_over_rate(monkeypatch):
    """Pacing is chunk_size / max_bytes_per_sec per chunk."""
    slept = []
    monkeypatch.setattr(ytclient.time, "sleep", slept.append)
    request = FakeRequest(chunks=[100])
    request.resumable = FakeResumable(chunksize=4 * 1024 * 1024)

    ytclient.pump(request, max_bytes_per_sec=1024 * 1024)

    # 4 MB chunk at 1 MB/s = 4s target, minus ~0 elapsed in the fake.
    assert len(slept) == 1
    assert slept[0] == pytest.approx(4.0, abs=0.5)
