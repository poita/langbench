"""Applying edit scripts."""

from __future__ import annotations

from collections.abc import Sequence

from .script import DELETE, INSERT, KEEP, Edit


class PatchError(ValueError):
    """The script does not match the file it is applied to."""


def patch(a: Sequence[str], script: Sequence[Edit], *, strict: bool = True) -> list[str]:
    """Apply *script* to the lines *a* and return the resulting lines.

    With ``strict`` (the default) every keep/delete must match the next
    unconsumed line of *a* and the script must consume all of *a*; otherwise
    :class:`PatchError` is raised.  With ``strict=False`` the script text is
    trusted and *a* is only used for position.
    """
    out: list[str] = []
    pos = 0
    n = len(a)
    for e in script:
        tag = e.tag
        if tag == INSERT:
            out.append(e.text)
            continue
        if tag != KEEP and tag != DELETE:
            raise PatchError(f"unknown tag {tag!r}")
        if pos >= n:
            raise PatchError("script consumes more lines than the file has")
        if strict and a[pos] != e.text:
            raise PatchError(f"line {pos + 1} does not match the script")
        if tag == KEEP:
            out.append(a[pos])
        pos += 1
    if strict and pos != n:
        raise PatchError("script does not consume the whole file")
    return out
