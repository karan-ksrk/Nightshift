"""selector.select_for_today -- see selector.py's docstring before touching
this file. The point of these tests is to fail loudly if someone "optimises"
the FIFO fit-check into bin-packing.
"""

import selector


def f(size_bytes, name="f"):
    return {"size_bytes": size_bytes, "filename": name}


def test_no_skip_on_non_fit():
    """A file that doesn't fit *today's remaining* budget must stop the
    selection (break), not be skipped in favour of a smaller file later in
    the queue (continue). Skipping ahead is the starvation bug this file
    exists to prevent. "big" fits the full daily budget on its own (so it
    isn't the oversized carve-out) but not what's left after bytes_used."""
    queued = [f(8, "big"), f(1, "small")]
    picks = selector.select_for_today(
        queued, byte_budget=10, count_budget=100, bytes_used=5)
    assert picks == []  # "big" doesn't fit the remaining 5 -> stop


def test_fifo_order_preserved_when_everything_fits():
    queued = [f(1, "a"), f(2, "b"), f(1, "c")]
    picks = selector.select_for_today(queued, byte_budget=10, count_budget=100)
    assert [p["filename"] for p in picks] == ["a", "b", "c"]


def test_oversized_file_gets_the_day_alone():
    """A file bigger than the whole daily budget can never fit. It gets
    the day to itself (debt carries forward via carry_debt_forward)."""
    queued = [f(100, "huge")]
    picks = selector.select_for_today(queued, byte_budget=10, count_budget=100)
    assert [p["filename"] for p in picks] == ["huge"]


def test_oversized_file_not_picked_if_something_already_selected():
    """The oversized carve-out only applies when it would be the day's only
    upload -- it must not preempt files already queued ahead of it."""
    queued = [f(5, "normal"), f(100, "huge")]
    picks = selector.select_for_today(queued, byte_budget=10, count_budget=100)
    assert [p["filename"] for p in picks] == ["normal"]


def test_count_cap():
    queued = [f(1, "a"), f(1, "b"), f(1, "c")]
    picks = selector.select_for_today(queued, byte_budget=None, count_budget=2)
    assert [p["filename"] for p in picks] == ["a", "b"]


def test_count_cap_accounts_for_uploads_already_used_today():
    queued = [f(1, "a"), f(1, "b")]
    picks = selector.select_for_today(
        queued, byte_budget=None, count_budget=2, uploads_used=2)
    assert picks == []


def test_exhausted_byte_budget_returns_nothing():
    queued = [f(1, "a")]
    picks = selector.select_for_today(
        queued, byte_budget=10, count_budget=100, bytes_used=10)
    assert picks == []


def test_exhausted_count_budget_returns_nothing():
    queued = [f(1, "a")]
    picks = selector.select_for_today(
        queued, byte_budget=None, count_budget=1, uploads_used=1)
    assert picks == []


def test_unlimited_byte_budget_is_bounded_only_by_count():
    queued = [f(10 ** 12, "a"), f(10 ** 12, "b"), f(10 ** 12, "c")]
    picks = selector.select_for_today(queued, byte_budget=None, count_budget=2)
    assert [p["filename"] for p in picks] == ["a", "b"]


def test_empty_queue():
    assert selector.select_for_today([], byte_budget=10, count_budget=10) == []
