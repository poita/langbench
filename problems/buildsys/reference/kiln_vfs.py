"""Virtual file system, path validation and FNV-1a-64 content hashing.

Every KBL string, workspace path and file content is a Python ``bytes`` object,
so that all of Kiln's operations are byte operations as the specification
requires.
"""
import os

MASK64 = (1 << 64) - 1
FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3

_HASH_MEMO = {}


def fnv1a64(data):
    """Return the 64-bit FNV-1a hash of ``data`` as an integer."""
    h = FNV_OFFSET
    for b in data:
        h = ((h ^ b) * FNV_PRIME) & MASK64
    return h


def hexhash(data):
    """Return the 16-lowercase-hex-digit hash of ``data``, memoised by content."""
    got = _HASH_MEMO.get(data)
    if got is None:
        got = b"%016x" % fnv1a64(data)
        _HASH_MEMO[data] = got
    return got


_PCHAR = bytearray(256)
for _c in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-":
    _PCHAR[_c] = 1
_PCHAR = bytes(_PCHAR)


def is_ws_path(p):
    """True when ``p`` is a valid workspace path."""
    if not p or len(p) > 1024:
        return False
    for comp in p.split(b"/"):
        n = len(comp)
        if n == 0 or n > 255:
            return False
        if comp == b"." or comp == b"..":
            return False
        for ch in comp:
            if not _PCHAR[ch]:
                return False
    return True


def is_ident(name):
    """True when ``name`` matches ``[A-Za-z_][A-Za-z0-9_]*``."""
    if not name:
        return False
    c = name[0]
    if not (65 <= c <= 90 or 97 <= c <= 122 or c == 95):
        return False
    for c in name[1:]:
        if not (65 <= c <= 90 or 97 <= c <= 122 or c == 95 or 48 <= c <= 57):
            return False
    return True


def is_generated(p):
    """True when ``p``'s first component is exactly ``out``."""
    return p == b"out" or p.startswith(b"out/")


STATE_PATH = b".kiln-state"


def lines_of(content):
    """Split ``content`` into Kiln lines: no lines for empty content, and a
    single trailing newline does not produce an empty final line."""
    if not content:
        return []
    parts = content.split(b"\n")
    if parts[-1] == b"":
        parts.pop()
    return parts


def join_lines(lines):
    """Concatenate each line followed by one newline."""
    if not lines:
        return b""
    return b"\n".join(lines) + b"\n"


class Workspace(object):
    """A flat map from workspace path to content, plus unobservable stamps."""

    def __init__(self):
        self.files = {}
        self.stamps = {}
        self._clock = 0

    def exists(self, path):
        return path in self.files

    def read(self, path):
        return self.files[path]

    def write(self, path, content):
        self.files[path] = content
        self._clock += 1
        self.stamps[path] = self._clock

    def remove(self, path):
        if path in self.files:
            del self.files[path]
            del self.stamps[path]

    def touch(self, path):
        if path in self.files:
            self._clock += 1
            self.stamps[path] = self._clock

    def hash_of(self, path):
        return hexhash(self.files[path])

    def sorted_paths(self):
        return sorted(self.files)


def load_workspace(indir):
    """Walk ``indir`` and load every regular file except the top-level
    ``session.txt`` into a fresh workspace."""
    ws = Workspace()
    indir = os.path.abspath(indir)
    for dirpath, dirnames, filenames in os.walk(indir):
        dirnames.sort()
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            if not os.path.isfile(full) or os.path.islink(full):
                continue
            rel = os.path.relpath(full, indir)
            rel = rel.replace(os.sep, "/").encode("utf-8")
            if rel == b"session.txt":
                continue
            with open(full, "rb") as f:
                ws.write(rel, f.read())
    return ws


def dump_workspace(ws, outdir):
    """Write every workspace file into ``outdir``/workspace."""
    root = os.path.join(outdir, "workspace")
    for path in ws.sorted_paths():
        rel = path.decode("utf-8")
        full = os.path.join(root, *rel.split("/"))
        parent = os.path.dirname(full)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(full, "wb") as f:
            f.write(ws.files[path])
