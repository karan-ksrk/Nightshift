"""main.captured_at_for -- prefers ffprobe's creation_time tag over mtime,
since copying a file (phone sync, drive transfer) destroys mtime and FIFO
order in selector.py depends on this field. Falls back to mtime whenever
ffprobe is missing, times out, or the tag isn't there."""

import subprocess
from datetime import datetime

import pytest

import main


@pytest.fixture(autouse=True)
def reset_ffprobe_cache():
    """captured_at_for caches whether ffprobe is on PATH at module scope."""
    main._ffprobe_available = None
    yield
    main._ffprobe_available = None


@pytest.fixture
def video_file(tmp_path):
    p = tmp_path / "clip.mp4"
    p.write_bytes(b"not a real video")
    return p


def fake_run(stdout_json):
    def _run(*args, **kwargs):
        return subprocess.CompletedProcess(args, 0, stdout=stdout_json, stderr="")
    return _run


def test_uses_format_tags_creation_time(monkeypatch, video_file):
    monkeypatch.setattr(main.shutil, "which", lambda name: "/usr/bin/ffprobe")
    monkeypatch.setattr(main.subprocess, "run", fake_run(
        '{"format": {"tags": {"creation_time": "2020-05-01T10:00:00.000000Z"}}}'))

    result = main.captured_at_for(video_file)

    # Compare via parsed datetime, not the string: the function converts UTC
    # to local time, so the literal offset in the result depends on the
    # machine running the test.
    expected = datetime.fromisoformat("2020-05-01T10:00:00+00:00").astimezone()
    assert datetime.fromisoformat(result) == expected


def test_falls_back_to_stream_tags_when_format_tags_missing(monkeypatch, video_file):
    monkeypatch.setattr(main.shutil, "which", lambda name: "/usr/bin/ffprobe")
    monkeypatch.setattr(main.subprocess, "run", fake_run(
        '{"format": {"tags": {}}, '
        '"streams": [{"tags": {}}, {"tags": {"creation_time": '
        '"2021-06-15T00:00:00.000000Z"}}]}'))

    result = main.captured_at_for(video_file)

    expected = datetime.fromisoformat("2021-06-15T00:00:00+00:00").astimezone()
    assert datetime.fromisoformat(result) == expected


def test_falls_back_to_mtime_when_ffprobe_missing(monkeypatch, video_file):
    monkeypatch.setattr(main.shutil, "which", lambda name: None)
    called = []
    monkeypatch.setattr(main.subprocess, "run",
                         lambda *a, **k: called.append(1) or fake_run("{}")())

    result = main.captured_at_for(video_file)

    assert not called  # ffprobe never invoked once "which" says it's absent
    expected_mtime = datetime.fromtimestamp(
        video_file.stat().st_mtime).isoformat(timespec="seconds")
    assert result == expected_mtime


def test_falls_back_to_mtime_when_no_creation_time_tag(monkeypatch, video_file):
    monkeypatch.setattr(main.shutil, "which", lambda name: "/usr/bin/ffprobe")
    monkeypatch.setattr(main.subprocess, "run", fake_run(
        '{"format": {"tags": {}}, "streams": [{"tags": {}}]}'))

    result = main.captured_at_for(video_file)

    expected_mtime = datetime.fromtimestamp(
        video_file.stat().st_mtime).isoformat(timespec="seconds")
    assert result == expected_mtime


def test_falls_back_to_mtime_on_ffprobe_failure(monkeypatch, video_file):
    monkeypatch.setattr(main.shutil, "which", lambda name: "/usr/bin/ffprobe")

    def raise_it(*a, **k):
        raise subprocess.CalledProcessError(1, "ffprobe")
    monkeypatch.setattr(main.subprocess, "run", raise_it)

    result = main.captured_at_for(video_file)

    expected_mtime = datetime.fromtimestamp(
        video_file.stat().st_mtime).isoformat(timespec="seconds")
    assert result == expected_mtime


def test_falls_back_to_mtime_on_malformed_json(monkeypatch, video_file):
    monkeypatch.setattr(main.shutil, "which", lambda name: "/usr/bin/ffprobe")
    monkeypatch.setattr(main.subprocess, "run", fake_run("not json"))

    result = main.captured_at_for(video_file)

    expected_mtime = datetime.fromtimestamp(
        video_file.stat().st_mtime).isoformat(timespec="seconds")
    assert result == expected_mtime


def test_ffprobe_presence_check_cached(monkeypatch, video_file):
    """shutil.which is only consulted once per process, not once per file --
    scanning a folder of hundreds of clips shouldn't re-probe PATH each time."""
    calls = []
    monkeypatch.setattr(main.shutil, "which",
                         lambda name: calls.append(1) or None)
    monkeypatch.setattr(main.subprocess, "run",
                         lambda *a, **k: (_ for _ in ()).throw(AssertionError(
                             "ffprobe should not run when unavailable")))

    main.captured_at_for(video_file)
    main.captured_at_for(video_file)

    assert len(calls) == 1
