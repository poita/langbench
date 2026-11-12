"""Checkpointing: copying the log overlay into the main file (SPEC §15.6)."""

from __future__ import annotations

from .constants import PAGE_SIZE
from .pager import Pager


def checkpoint(pager: Pager) -> int:
    """Copy every overlay image into the main file and empty the log.

    Returns the number of pages copied. No transaction may be open.
    """
    assert not pager.in_txn
    overlay = pager.overlay
    n = len(overlay)
    main = pager.main
    size = pager.header.page_count * PAGE_SIZE
    if len(main) < size:
        main.extend(bytes(size - len(main)))
    elif len(main) > size:
        del main[size:]
    for page_no in sorted(overlay):
        off = (page_no - 1) * PAGE_SIZE
        main[off:off + PAGE_SIZE] = overlay[page_no]
    overlay.clear()
    pager.wal.reset()
    return n
