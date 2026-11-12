"""The virtual file system a session runs against.

The file system is a flat map from workspace path to content.  Hashes are
memoised by content, so each distinct content is hashed once however many
paths hold it or however many builds look at it.  A sorted index of the paths
that ``glob`` may match supports prefix-bounded glob queries.
"""

from __future__ import annotations

import os
from bisect import bisect_left, insort
from collections.abc import Iterator

from .hashing import hash_hex
from .paths import STATE_FILE, is_generated


def _globbable(path: bytes) -> bool:
    return not is_generated(path) and path != STATE_FILE


class VirtualFS:
    """A mutable path -> bytes map with content hashes and a glob index."""

    def __init__(self) -> None:
        self._files: dict[bytes, bytes] = {}
        self._stamps: dict[bytes, int] = {}
        self._clock = 0
        self._hash_memo: dict[bytes, bytes] = {}
        self._index: list[bytes] = []

    # -- queries ---------------------------------------------------------

    def __contains__(self, path: bytes) -> bool:
        return path in self._files

    def __len__(self) -> int:
        return len(self._files)

    def paths(self) -> Iterator[bytes]:
        """All file paths, in no particular order."""
        return iter(self._files)

    def read(self, path: bytes) -> bytes:
        """The content of *path*; ``KeyError`` when absent."""
        return self._files[path]

    def get(self, path: bytes) -> bytes | None:
        return self._files.get(path)

    def stamp(self, path: bytes) -> int:
        """The modification stamp of *path* (informational only)."""
        return self._stamps[path]

    def hash_content(self, content: bytes) -> bytes:
        """Hex FNV-1a hash of *content*, memoised."""
        h = self._hash_memo.get(content)
        if h is None:
            h = self._hash_memo[content] = hash_hex(content)
        return h

    def hash_of(self, path: bytes) -> bytes | None:
        """Hex hash of the file at *path*, or ``None`` when absent."""
        content = self._files.get(path)
        return None if content is None else self.hash_content(content)

    # -- mutation --------------------------------------------------------

    def write(self, path: bytes, content: bytes) -> None:
        """Create or replace a file."""
        if path not in self._files and _globbable(path):
            insort(self._index, path)
        self._files[path] = content
        self.touch(path)

    def delete(self, path: bytes) -> None:
        """Remove a file; absent paths are ignored."""
        if self._files.pop(path, None) is None:
            return
        self._stamps.pop(path, None)
        if _globbable(path):
            i = bisect_left(self._index, path)
            if i < len(self._index) and self._index[i] == path:
                del self._index[i]

    def touch(self, path: bytes) -> None:
        """Bump the modification stamp of an existing file."""
        self._clock += 1
        self._stamps[path] = self._clock

    # -- glob support ----------------------------------------------------

    def glob_candidates(self, prefix: bytes) -> Iterator[bytes]:
        """Globbable paths starting with *prefix*, in sorted order.

        Costs O(log F) plus the number of paths sharing the prefix.
        """
        index = self._index
        i = bisect_left(index, prefix)
        n = len(index)
        while i < n:
            p = index[i]
            if not p.startswith(prefix):
                return
            yield p
            i += 1

    # -- real file system bridge ------------------------------------------

    @classmethod
    def load(cls, root: str | bytes, *, skip_session: bool = True) -> VirtualFS:
        """Load every regular file below *root* (``session.txt`` excluded)."""
        fs = cls()
        broot = os.fsencode(root)
        loaded: dict[bytes, bytes] = {}
        for dirpath, _dirs, files in os.walk(broot):
            rel_dir = os.path.relpath(dirpath, broot)
            for name in files:
                rel = name if rel_dir == b"." else rel_dir + b"/" + name
                if skip_session and rel == b"session.txt":
                    continue
                with open(os.path.join(dirpath, name), "rb") as fh:
                    loaded[rel] = fh.read()
        for path, content in loaded.items():
            fs._files[path] = content
            fs.touch(path)
        fs._index = sorted(p for p in loaded if _globbable(p))
        return fs

    def dump(self, root: str | bytes) -> None:
        """Write every file below *root* at its workspace path."""
        broot = os.fsencode(root)
        made: set[bytes] = set()
        for path, content in self._files.items():
            dest = os.path.join(broot, path)
            parent = os.path.dirname(dest)
            if parent not in made:
                os.makedirs(parent, exist_ok=True)
                made.add(parent)
            with open(dest, "wb") as fh:
                fh.write(content)
