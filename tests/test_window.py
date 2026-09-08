"""Window maths in main.py: in_window / seconds_left_in_window /
window_length_seconds. All three have to agree on what "wraps past midnight"
means or the upload loop either stops too early or runs past the window."""

from datetime import datetime, time as dtime

from main import in_window, seconds_left_in_window, window_length_seconds


def t(hh, mm=0):
    return dtime(hh, mm)


# ---------------------------------------------------------------- in_window

def test_in_window_same_day_inside():
    assert in_window(t(3, 0), t(1, 0), t(6, 30)) is True


def test_in_window_same_day_outside():
    assert in_window(t(12, 0), t(1, 0), t(6, 30)) is False


def test_in_window_same_day_boundaries_inclusive():
    assert in_window(t(1, 0), t(1, 0), t(6, 30)) is True
    assert in_window(t(6, 30), t(1, 0), t(6, 30)) is True


def test_in_window_wraps_past_midnight_inside_before_midnight():
    # window 23:00-02:00, now 23:30 -> inside
    assert in_window(t(23, 30), t(23, 0), t(2, 0)) is True


def test_in_window_wraps_past_midnight_inside_after_midnight():
    # window 23:00-02:00, now 00:30 -> inside
    assert in_window(t(0, 30), t(23, 0), t(2, 0)) is True


def test_in_window_wraps_past_midnight_outside():
    # window 23:00-02:00, now 12:00 -> outside
    assert in_window(t(12, 0), t(23, 0), t(2, 0)) is False


# ------------------------------------------------------ seconds_left_in_window

def test_seconds_left_same_day():
    now = datetime(2026, 1, 1, 5, 0)
    left = seconds_left_in_window(now, t(1, 0), t(6, 30))
    assert left == 90 * 60  # 1.5h to 06:30


def test_seconds_left_after_window_end_same_day_is_zero():
    now = datetime(2026, 1, 1, 7, 0)
    left = seconds_left_in_window(now, t(1, 0), t(6, 30))
    assert left == 0


def test_seconds_left_wraps_past_midnight_before_midnight():
    # window 23:00-02:00, now 23:30 -> end is tomorrow 02:00 -> 2.5h left
    now = datetime(2026, 1, 1, 23, 30)
    left = seconds_left_in_window(now, t(23, 0), t(2, 0))
    assert left == 2.5 * 3600


def test_seconds_left_wraps_past_midnight_after_midnight():
    # window 23:00-02:00, now 00:30 (already past midnight, before start
    # would normally have wrapped) -> end is today 02:00 -> 1.5h left
    now = datetime(2026, 1, 2, 0, 30)
    left = seconds_left_in_window(now, t(23, 0), t(2, 0))
    assert left == 1.5 * 3600


# -------------------------------------------------------- window_length_seconds

def test_window_length_same_day():
    assert window_length_seconds(t(1, 0), t(6, 30)) == 5.5 * 3600


def test_window_length_wraps_past_midnight():
    # 23:00 -> 02:00 next day = 3h
    assert window_length_seconds(t(23, 0), t(2, 0)) == 3 * 3600


def test_window_length_equal_start_end_is_full_day():
    # e <= s branch: a zero-width window wraps to 24h rather than being empty
    assert window_length_seconds(t(1, 0), t(1, 0)) == 24 * 3600
