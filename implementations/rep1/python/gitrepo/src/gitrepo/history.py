"""Commit history walking (``log``)."""

from __future__ import annotations

import heapq
from typing import Iterator

from .objects import Commit
from .repository import Repository


def walk(repo: Repository, start: str, limit: int | None = None) -> Iterator[tuple[str, Commit]]:
    """Yield ``(id, commit)`` from *start* in git's default log order.

    Order is reverse chronological by committer date; ties go to the commit
    discovered first.  At most *limit* commits are produced, and no commit is
    read beyond those the walk needs to reach that limit.  A missing or damaged
    commit raises :class:`~gitrepo.errors.GitRepoError` when the walk reaches it.
    """
    if limit == 0:
        return
    seen = {start}
    counter = 0
    heap: list[tuple[int, int, str]] = [(-repo.commit(start).committer_time, 0, start)]
    emitted = 0
    while heap:
        _, _, oid = heapq.heappop(heap)
        commit = repo.commit(oid)
        yield oid, commit
        emitted += 1
        if limit is not None and emitted >= limit:
            return
        for parent in commit.parents:
            if parent not in seen:
                seen.add(parent)
                counter += 1
                heapq.heappush(heap, (-repo.commit(parent).committer_time, counter, parent))
