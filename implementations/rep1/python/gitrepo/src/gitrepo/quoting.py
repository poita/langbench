"""Git's default C-style path quoting."""

from __future__ import annotations

_ESCAPES = {
    0x07: b"\\a", 0x08: b"\\b", 0x09: b"\\t", 0x0A: b"\\n",
    0x0B: b"\\v", 0x0C: b"\\f", 0x0D: b"\\r", 0x22: b'\\"', 0x5C: b"\\\\",
}


def quote_path(name: bytes) -> bytes:
    """Quote *name* the way ``git`` prints paths by default.

    Names made only of printable ASCII other than ``"`` and ``\\`` are returned
    unchanged; anything else is wrapped in double quotes with C-style escapes.
    """
    if all(0x20 <= b <= 0x7E and b != 0x22 and b != 0x5C for b in name):
        return name
    out = bytearray(b'"')
    for b in name:
        esc = _ESCAPES.get(b)
        if esc is not None:
            out += esc
        elif b < 0x20 or b >= 0x7F:
            out += b"\\%03o" % b
        else:
            out.append(b)
    out += b'"'
    return bytes(out)
