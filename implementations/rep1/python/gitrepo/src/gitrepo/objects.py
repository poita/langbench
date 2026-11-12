"""Parsed forms of git objects: trees, commits and tags."""

from __future__ import annotations

from dataclasses import dataclass, field

from .errors import CorruptObjectError

HEX = frozenset(b"0123456789abcdef")

S_IFMT = 0o170000
S_IFDIR = 0o040000
S_IFGITLINK = 0o160000

_WS = b" \t\r\n\x0b\x0c"


def is_hex_id(text: bytes) -> bool:
    """True if *text* is exactly 40 lowercase hexadecimal digits."""
    return len(text) == 40 and all(c in HEX for c in text)


def entry_type(mode: int) -> str:
    """Object type (``tree``/``commit``/``blob``) a tree entry with *mode* refers to."""
    kind = mode & S_IFMT
    if kind == S_IFDIR:
        return "tree"
    if kind == S_IFGITLINK:
        return "commit"
    return "blob"


@dataclass(frozen=True, slots=True)
class TreeEntry:
    """One entry of a tree object."""

    mode: int
    name: bytes
    id: str  # 40 lowercase hex digits

    @property
    def type(self) -> str:
        return entry_type(self.mode)


def parse_tree(payload: bytes) -> list[TreeEntry]:
    """Parse a tree payload into its entries, in stored order."""
    entries: list[TreeEntry] = []
    pos = 0
    n = len(payload)
    while pos < n:
        sp = payload.find(b" ", pos)
        if sp < 0:
            raise CorruptObjectError("malformed tree entry")
        mode_text = payload[pos:sp]
        if not mode_text or any(not 0x30 <= c <= 0x37 for c in mode_text):
            raise CorruptObjectError("malformed tree entry mode")
        nul = payload.find(b"\0", sp + 1)
        if nul < 0 or nul == sp + 1 or nul + 21 > n:
            raise CorruptObjectError("malformed tree entry")
        name = payload[sp + 1:nul]
        if b"/" in name:
            raise CorruptObjectError("slash in tree entry name")
        entries.append(TreeEntry(int(mode_text, 8), name, payload[nul + 1:nul + 21].hex()))
        pos = nul + 21
    return entries


def _split_message(payload: bytes) -> tuple[list[tuple[bytes, bytes]], bytes]:
    """Split a commit/tag payload into ``(key, value)`` headers and the message."""
    headers: list[tuple[bytes, bytes]] = []
    pos = 0
    n = len(payload)
    message = b""
    while pos < n:
        end = payload.find(b"\n", pos)
        if end < 0:
            line, pos = payload[pos:], n
        else:
            line, pos = payload[pos:end], end + 1
        if not line:
            message = payload[pos:]
            break
        if line[0] == 0x20:
            continue  # continuation of the previous header
        key, sep, value = line.partition(b" ")
        headers.append((key, value if sep else b""))
    return headers, message


def parse_ident(value: bytes) -> tuple[bytes, int]:
    """Extract ``(name, timestamp)`` from an ``author``/``committer`` value."""
    lt = value.find(b"<")
    if lt < 0:
        return value.rstrip(_WS), 0
    name = value[:lt].rstrip(_WS)
    gt = value.find(b">", lt)
    if gt < 0:
        return name, 0
    pos = gt + 1
    n = len(value)
    while pos < n and value[pos] == 0x20:
        pos += 1
    if pos < n and value[pos] in b"+-":
        pos += 1
    start = pos
    while pos < n and 0x30 <= value[pos] <= 0x39:
        pos += 1
    return name, int(value[start:pos]) if pos > start else 0


def subject_of(message: bytes) -> bytes:
    """Compute a commit's subject line from its *message*."""
    parts: list[bytes] = []
    for line in message.split(b"\n"):
        line = line.rstrip(_WS)
        if not line:
            if parts:
                break
            continue
        parts.append(line)
    return b" ".join(parts)


@dataclass(frozen=True, slots=True)
class Commit:
    """A parsed commit object."""

    tree: str | None
    parents: tuple[str, ...]
    author_name: bytes
    author_time: int
    committer_name: bytes
    committer_time: int
    message: bytes
    subject: bytes = field(default=b"")


def parse_commit(payload: bytes) -> Commit:
    """Parse a commit payload."""
    headers, message = _split_message(payload)
    tree: str | None = None
    parents: list[str] = []
    author = (b"", 0)
    committer = (b"", 0)
    for key, value in headers:
        if key == b"tree":
            tree = value.decode("ascii") if is_hex_id(value) else None
        elif key == b"parent":
            if not is_hex_id(value):
                raise CorruptObjectError("malformed parent header")
            parents.append(value.decode("ascii"))
        elif key == b"author":
            author = parse_ident(value)
        elif key == b"committer":
            committer = parse_ident(value)
    return Commit(tree, tuple(parents), author[0], author[1], committer[0], committer[1],
                  message, subject_of(message))


def parse_tag_target(payload: bytes) -> str | None:
    """Return the id named by a tag's ``object`` header, or ``None``."""
    headers, _ = _split_message(payload)
    target = None
    for key, value in headers:
        if key == b"object":
            target = value.decode("ascii") if is_hex_id(value) else None
    return target
