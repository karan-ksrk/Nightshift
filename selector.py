"""Which files go today.

Deliberately NOT bin-packing. Packing to fill the budget starves large files:
a 6 GB video never gets picked because two 4 GB videos always fit better, and
it sits in the queue forever. FIFO by capture date with a fit check keeps the
archive in order and guarantees head-of-line files eventually go.

The break-instead-of-continue below is the whole point. Skipping ahead to find
a smaller file that fits is exactly the starvation bug.
"""


def select_for_today(queued, byte_budget, count_budget, bytes_used=0, uploads_used=0):
    """
    queued        rows, oldest capture first
    byte_budget   effective bytes for today, or None for unlimited
    count_budget  videos.insert calls available today
    Returns the list of rows to attempt, in order.
    """
    remaining_count = count_budget - uploads_used
    if remaining_count <= 0:
        return []

    if byte_budget is None:
        return list(queued)[:remaining_count]

    remaining_bytes = byte_budget - bytes_used
    if remaining_bytes <= 0:
        return []

    selected = []
    for f in queued:
        if len(selected) >= remaining_count:
            break

        # Bigger than an entire day's budget. It can never fit, so give it the
        # day to itself and let carry_debt_forward() bill tomorrow for the
        # overage. Only when nothing else is already going.
        if f["size_bytes"] > byte_budget:
            if not selected:
                return [f]
            break

        if f["size_bytes"] > remaining_bytes:
            break  # NOT continue

        selected.append(f)
        remaining_bytes -= f["size_bytes"]

    return selected
