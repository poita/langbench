"""The Tessera value model: SPEC.md §4, §5.1, §6.4, §14.1, §17.2.

A value is a two-element tuple ``(rank, payload)`` where rank is the type rank
of SPEC.md §4:

    (NULL, None)
    (BOOL, True) / (BOOL, False)
    (INT, int)                  -- a Python int inside the signed 64-bit range
    (STR, bytes)                -- the UTF-8 bytes of the string
    (LIST, [value, ...])
    (OBJ,  [(name_bytes, value), ...])   -- always sorted by name, byte-wise

Strings and field names are held as UTF-8 bytes so that every comparison in
this file is the byte-wise comparison the specification asks for, and so that
serialisation needs no re-encoding.
"""

NULL = 0
BOOL = 1
INT = 2
STR = 3
LIST = 4
OBJ = 5

MAX_DEPTH = 32
MAX_DOC = 65536
MAX_KEY = 128
MAX_INDEX_KEY = 128
MAX_PATH = 30
MAX_PATH_SEGMENTS = 8

VNULL = (NULL, None)
VTRUE = (BOOL, True)
VFALSE = (BOOL, False)

INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1


# --------------------------------------------------------------------------
# Serialisation (§4.2)
# --------------------------------------------------------------------------

def _ser_into(v, out):
    k = v[0]
    if k == NULL:
        out.append(b"\x00")
    elif k == BOOL:
        out.append(b"\x02" if v[1] else b"\x01")
    elif k == INT:
        out.append(b"\x03")
        out.append((v[1] & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big"))
    elif k == STR:
        s = v[1]
        out.append(b"\x04")
        out.append(len(s).to_bytes(4, "big"))
        out.append(s)
    elif k == LIST:
        items = v[1]
        out.append(b"\x05")
        out.append(len(items).to_bytes(4, "big"))
        for e in items:
            _ser_into(e, out)
    else:
        fields = v[1]
        out.append(b"\x06")
        out.append(len(fields).to_bytes(4, "big"))
        for name, val in fields:
            out.append(len(name).to_bytes(4, "big"))
            out.append(name)
            _ser_into(val, out)


def ser(v):
    """The stored byte string of a value."""
    out = []
    _ser_into(v, out)
    return b"".join(out)


class _Reader(object):
    __slots__ = ("data", "pos")

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, n):
        p = self.pos
        self.pos = p + n
        return self.data[p:p + n]

    def u8(self):
        p = self.pos
        self.pos = p + 1
        return self.data[p]

    def u32(self):
        p = self.pos
        self.pos = p + 4
        return int.from_bytes(self.data[p:p + 4], "big")


def _deser_from(r):
    tag = r.u8()
    if tag == 0x00:
        return VNULL
    if tag == 0x01:
        return VFALSE
    if tag == 0x02:
        return VTRUE
    if tag == 0x03:
        u = int.from_bytes(r.take(8), "big")
        if u >= 1 << 63:
            u -= 1 << 64
        return (INT, u)
    if tag == 0x04:
        n = r.u32()
        return (STR, r.take(n))
    if tag == 0x05:
        n = r.u32()
        return (LIST, [_deser_from(r) for _ in range(n)])
    if tag == 0x06:
        n = r.u32()
        fields = []
        for _ in range(n):
            ln = r.u32()
            name = r.take(ln)
            fields.append((name, _deser_from(r)))
        return (OBJ, fields)
    raise ValueError("bad serialised value tag %d" % tag)


def deser(data):
    """The inverse of ser (§4.3)."""
    return _deser_from(_Reader(data))


# --------------------------------------------------------------------------
# Depth (§4.1)
# --------------------------------------------------------------------------

def depth(v):
    k = v[0]
    if k == LIST:
        items = v[1]
        if not items:
            return 1
        return 1 + max(depth(e) for e in items)
    if k == OBJ:
        fields = v[1]
        if not fields:
            return 1
        return 1 + max(depth(f[1]) for f in fields)
    return 1


# --------------------------------------------------------------------------
# Rendering (§4.4, §4.5)
# --------------------------------------------------------------------------

_ESCAPES = {
    0x08: "\\b",
    0x09: "\\t",
    0x0A: "\\n",
    0x0C: "\\f",
    0x0D: "\\r",
}


def render_string(b):
    """A string, key or field name rendered with the escaping of §4.5."""
    out = ['"']
    for ch in b.decode("utf-8", "surrogateescape"):
        o = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif o in _ESCAPES:
            out.append(_ESCAPES[o])
        elif o < 0x20 or o == 0x7F:
            out.append("\\u%04x" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def render(v):
    """One line of text for results.txt, with no whitespace anywhere."""
    k = v[0]
    if k == NULL:
        return "null"
    if k == BOOL:
        return "true" if v[1] else "false"
    if k == INT:
        return "%d" % v[1]
    if k == STR:
        return render_string(v[1])
    if k == LIST:
        return "[" + ",".join(render(e) for e in v[1]) + "]"
    parts = []
    for name, val in v[1]:
        parts.append(render_string(name) + ":" + render(val))
    return "{" + ",".join(parts) + "}"


# --------------------------------------------------------------------------
# Object helpers: fields stay sorted by name, byte-wise
# --------------------------------------------------------------------------

def obj_find(fields, name):
    """Index of `name` in a sorted field list, or -(insertion point) - 1."""
    lo, hi = 0, len(fields)
    while lo < hi:
        mid = (lo + hi) // 2
        if fields[mid][0] < name:
            lo = mid + 1
        else:
            hi = mid
    if lo < len(fields) and fields[lo][0] == name:
        return lo
    return -lo - 1


def obj_get(v, name):
    """The value of field `name` of an object value, or None when absent."""
    i = obj_find(v[1], name)
    if i < 0:
        return None
    return v[1][i][1]


def obj_set(v, name, val):
    fields = list(v[1])
    i = obj_find(fields, name)
    if i >= 0:
        fields[i] = (name, val)
    else:
        fields.insert(-i - 1, (name, val))
    return (OBJ, fields)


def obj_del(v, name):
    fields = list(v[1])
    i = obj_find(fields, name)
    if i >= 0:
        del fields[i]
    return (OBJ, fields)


# --------------------------------------------------------------------------
# Field paths (§6.4)
# --------------------------------------------------------------------------

def path_resolve(doc, segs):
    """Resolve a path (a list of name byte strings), or None when missing."""
    cur = doc
    for seg in segs:
        if cur[0] != OBJ:
            return None
        i = obj_find(cur[1], seg)
        if i < 0:
            return None
        cur = cur[1][i][1]
    return cur


class PathNotObject(Exception):
    """A path segment traverses a value that is not an object."""


class PathNoField(Exception):
    """An unset path names a field that is not there."""


def path_set(doc, segs, newval):
    """§18.3 `update`: set segs to newval, auto-vivifying missing ancestors."""
    if doc[0] != OBJ:
        raise PathNotObject()
    if len(segs) == 1:
        return obj_set(doc, segs[0], newval)
    sub = obj_get(doc, segs[0])
    if sub is None:
        sub = (OBJ, [])
    return obj_set(doc, segs[0], path_set(sub, segs[1:], newval))


def path_unset(doc, segs):
    """§18.3 `unset`: remove the field segs names."""
    if doc[0] != OBJ:
        raise PathNotObject()
    sub = obj_get(doc, segs[0])
    if sub is None:
        raise PathNoField()
    if len(segs) == 1:
        return obj_del(doc, segs[0])
    return obj_set(doc, segs[0], path_unset(sub, segs[1:]))


# --------------------------------------------------------------------------
# Comparison (§17.2)
# --------------------------------------------------------------------------

def veq(a, b):
    """Deep equality, which also requires equal type ranks."""
    ka = a[0]
    if ka != b[0]:
        return False
    if ka == LIST:
        xs, ys = a[1], b[1]
        if len(xs) != len(ys):
            return False
        for i in range(len(xs)):
            if not veq(xs[i], ys[i]):
                return False
        return True
    if ka == OBJ:
        xs, ys = a[1], b[1]
        if len(xs) != len(ys):
            return False
        for i in range(len(xs)):
            if xs[i][0] != ys[i][0] or not veq(xs[i][1], ys[i][1]):
                return False
        return True
    if ka == BOOL:
        return a[1] is b[1]
    return a[1] == b[1]


def vorder(a, b):
    """-1/0/1 for two ordered values of the same rank, or None when the order
    comparisons of §17.2 are all false (differing ranks, lists, objects)."""
    ka = a[0]
    if ka != b[0] or ka == LIST or ka == OBJ:
        return None
    if ka == NULL:
        return 0
    if ka == BOOL:
        x, y = (1 if a[1] else 0), (1 if b[1] else 0)
    else:
        x, y = a[1], b[1]
    if x < y:
        return -1
    if x > y:
        return 1
    return 0


# --------------------------------------------------------------------------
# Index key encoding (§14.1)
# --------------------------------------------------------------------------

def vkey(v):
    """The order-preserving self-delimiting encoding of a scalar, or None for a
    list or an object, which have no vkey and are therefore not indexable."""
    k = v[0]
    if k == NULL:
        return b"\x10"
    if k == BOOL:
        return b"\x21" if v[1] else b"\x20"
    if k == INT:
        return b"\x30" + ((v[1] + (1 << 63)) & 0xFFFFFFFFFFFFFFFF).to_bytes(8, "big")
    if k == STR:
        return b"\x40" + v[1].replace(b"\x00", b"\x00\xff") + b"\x00\x00"
    return None


def vkey_len(ikey):
    """The length of the vkey prefix of an index key, so the document key that
    follows it can be recovered (§17.4)."""
    tag = ikey[0]
    if tag == 0x10 or tag == 0x20 or tag == 0x21:
        return 1
    if tag == 0x30:
        return 9
    i = 1
    n = len(ikey)
    while i < n:
        if ikey[i] == 0x00:
            if i + 1 < n and ikey[i + 1] == 0xFF:
                i += 2
                continue
            return i + 2
        i += 1
    return n
