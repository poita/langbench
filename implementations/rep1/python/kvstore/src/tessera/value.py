"""The document value model (SPEC §4).

Documents are plain Python values:

========  ===========================================
Python    Tessera kind
========  ===========================================
None      null
bool      bool
int       int (signed 64-bit)
str       string
list      list (a ``tuple`` is accepted on input too)
dict      object (``str`` field names)
========  ===========================================

Careful: ``bool`` is a subclass of ``int`` in Python, so the functions here
always dispatch on the exact type, never with ``==`` on mixed kinds.
"""

from __future__ import annotations

import re
import struct
from typing import Any

from .constants import INT_MAX, INT_MIN, MAX_PATH, MAX_PATH_SEGMENTS
from .errors import TesseraError

#: Result of resolving a path that is not present in a document.
MISSING: Any = type("Missing", (), {"__repr__": lambda self: "MISSING"})()

_U32 = struct.Struct(">I")
_I64 = struct.Struct(">q")


def rank(v: Any) -> int:
    """Type rank of a value: null 0, bool 1, int 2, string 3, list 4, object 5."""
    if v is None:
        return 0
    t = type(v)
    if t is bool:
        return 1
    if t is int:
        return 2
    if t is str:
        return 3
    if t is list or t is tuple:
        return 4
    if t is dict:
        return 5
    raise TypeError(f"not a Tessera value: {v!r}")


def depth(v: Any) -> int:
    """Nesting depth of a value (SPEC §4.1): 1 for scalars and empty containers."""
    best = 1
    stack = [(v, 1)]
    while stack:
        cur, d = stack.pop()
        if d > best:
            best = d
        t = type(cur)
        if t is list or t is tuple:
            stack.extend((x, d + 1) for x in cur)
        elif t is dict:
            stack.extend((x, d + 1) for x in cur.values())
    return best



# --------------------------------------------------------------------------
# Serialisation (SPEC §4.2) and deserialisation (§4.3)
# --------------------------------------------------------------------------

def _ser(v: Any, out: bytearray) -> None:
    if v is None:
        out.append(0)
        return
    t = type(v)
    if t is bool:
        out.append(2 if v else 1)
    elif t is int:
        if not INT_MIN <= v <= INT_MAX:
            raise TesseraError("int-range", str(v))
        out.append(3)
        out += _I64.pack(v)
    elif t is str:
        try:
            raw = v.encode("utf-8")
        except UnicodeEncodeError:
            raise TesseraError("bad-utf8", "unpaired surrogate") from None
        out.append(4)
        out += _U32.pack(len(raw))
        out += raw
    elif t is list or t is tuple:
        out.append(5)
        out += _U32.pack(len(v))
        for x in v:
            _ser(x, out)
    elif t is dict:
        out.append(6)
        out += _U32.pack(len(v))
        for name in sorted(v):
            if type(name) is not str:
                raise TypeError(f"object field names must be str, not {name!r}")
            try:
                raw = name.encode("utf-8")
            except UnicodeEncodeError:
                raise TesseraError("bad-utf8", "unpaired surrogate") from None
            out += _U32.pack(len(raw))
            out += raw
            _ser(v[name], out)
    else:
        raise TypeError(f"not a Tessera value: {v!r}")


def serialize(v: Any) -> bytes:
    """Stored form of a document (``ser(v)`` of SPEC §4.2).

    The caller is responsible for the depth limit; see :func:`depth`.
    """
    out = bytearray()
    _ser(v, out)
    return bytes(out)


def _de(data: bytes, pos: int) -> tuple[Any, int]:
    tag = data[pos]
    pos += 1
    if tag == 0:
        return None, pos
    if tag == 1:
        return False, pos
    if tag == 2:
        return True, pos
    if tag == 3:
        return _I64.unpack_from(data, pos)[0], pos + 8
    if tag == 4:
        n = _U32.unpack_from(data, pos)[0]
        pos += 4
        return data[pos:pos + n].decode("utf-8"), pos + n
    if tag == 5:
        n = _U32.unpack_from(data, pos)[0]
        pos += 4
        items = []
        for _ in range(n):
            x, pos = _de(data, pos)
            items.append(x)
        return items, pos
    if tag == 6:
        n = _U32.unpack_from(data, pos)[0]
        pos += 4
        obj = {}
        for _ in range(n):
            ln = _U32.unpack_from(data, pos)[0]
            pos += 4
            name = data[pos:pos + ln].decode("utf-8")
            pos += ln
            obj[name], pos = _de(data, pos)
        return obj, pos
    raise ValueError(f"bad document tag {tag}")


def deserialize(data: bytes) -> Any:
    """Inverse of :func:`serialize`."""
    return _de(data, 0)[0]


# --------------------------------------------------------------------------
# Rendering (SPEC §4.4, §4.5)
# --------------------------------------------------------------------------

_ESCAPES = {0x22: '\\"', 0x5C: "\\\\", 0x08: "\\b", 0x09: "\\t", 0x0A: "\\n",
            0x0C: "\\f", 0x0D: "\\r"}
for _c in list(range(0x20)) + [0x7F]:
    _ESCAPES.setdefault(_c, "\\u%04x" % _c)
_NEEDS_ESCAPE = re.compile('[\\x00-\\x1f"\\\\\\x7f]')


def render_string(s: str) -> str:
    """A string as written in ``results.txt``, with its quotes."""
    if _NEEDS_ESCAPE.search(s):
        s = s.translate(_ESCAPES)
    return '"' + s + '"'


def render(v: Any) -> str:
    """Canonical one-line rendering of a value."""
    if v is None:
        return "null"
    t = type(v)
    if t is bool:
        return "true" if v else "false"
    if t is int:
        return str(v)
    if t is str:
        return render_string(v)
    if t is list or t is tuple:
        return "[" + ",".join([render(x) for x in v]) + "]"
    if t is dict:
        return "{" + ",".join([render_string(k) + ":" + render(v[k]) for k in sorted(v)]) + "}"
    raise TypeError(f"not a Tessera value: {v!r}")


# --------------------------------------------------------------------------
# Comparison (SPEC §17.2)
# --------------------------------------------------------------------------

def deep_equal(a: Any, b: Any) -> bool:
    """Deep equality of two values, never equating different kinds."""
    ra = rank(a)
    if ra != rank(b):
        return False
    if ra < 4:
        return a == b
    if ra == 4:
        return len(a) == len(b) and all(deep_equal(x, y) for x, y in zip(a, b))
    if len(a) != len(b):
        return False
    for k, x in a.items():
        y = b.get(k, MISSING)
        if y is MISSING or not deep_equal(x, y):
            return False
    return True


# --------------------------------------------------------------------------
# Paths (SPEC §6.4)
# --------------------------------------------------------------------------

_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


def normalize_path(path: Any) -> tuple[str, ...]:
    """Turn ``"a.b"`` or ``("a", "b")`` into a validated tuple of segments."""
    segs = tuple(path.split(".")) if isinstance(path, str) else tuple(path)
    if not segs or len(segs) > MAX_PATH_SEGMENTS or len(".".join(segs)) > MAX_PATH:
        raise TesseraError("bad-path", ".".join(segs))
    for s in segs:
        if not _WORD.match(s):
            raise TesseraError("bad-path", ".".join(segs))
    return segs


def get_path(doc: Any, segs: tuple[str, ...]) -> Any:
    """Resolve a path; returns :data:`MISSING` when it is not present."""
    cur = doc
    for s in segs:
        if type(cur) is not dict:
            return MISSING
        cur = cur.get(s, MISSING)
        if cur is MISSING:
            return MISSING
    return cur


def set_path(doc: Any, segs: tuple[str, ...], value: Any) -> Any:
    """Return a copy of ``doc`` with ``segs`` set to ``value`` (``update``).

    Missing intermediate objects are created; a non-object on the way raises
    ``not-object``. ``doc`` itself is not modified.
    """
    if type(doc) is not dict:
        raise TesseraError("not-object")
    new = dict(doc)
    seg = segs[0]
    if len(segs) == 1:
        new[seg] = value
    else:
        new[seg] = set_path(new.get(seg, {}), segs[1:], value)
    return new


def unset_path(doc: Any, segs: tuple[str, ...]) -> Any:
    """Return a copy of ``doc`` without the field at ``segs`` (``unset``).

    Raises ``not-object`` / ``no-field`` as SPEC §18.3 prescribes.
    """
    if type(doc) is not dict:
        raise TesseraError("not-object")
    seg = segs[0]
    if seg not in doc:
        raise TesseraError("no-field")
    new = dict(doc)
    if len(segs) == 1:
        del new[seg]
    else:
        new[seg] = unset_path(new[seg], segs[1:])
    return new
