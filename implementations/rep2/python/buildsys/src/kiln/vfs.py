"""The virtual file system a session runs against.

A flat map from workspace path to content.  Each file's FNV-1a hash is
computed lazily and kept until the file's content changes, and a sorted index
of the glob-eligible paths is kept between builds (rebuilt only when the set
of eligible paths changes).
"""

from __future__ import annotations

import os
from bisect import bisect_left
from typing import Iterable, Iterator, Mapping

from .globs import Glob
from .hashing import hash_hex
from .paths import STATE_PATH, is_generated

__all__ = ["VirtualFS"]


def _glob_eligible(path: bytes) -> bool:
    return not is_generated(path) and path != STATE_PATH


class VirtualFS:
    """A mutable in-memory workspace.  All paths and contents are ``bytes``."""

    def __init__(self, files: Mapping[bytes, bytes] | None = None) -> None:
        self._files: dict[bytes, bytes] = dict(files or {})
        self._hashes: dict[bytes, bytes] = {}
        self._stamps: dict[bytes, int] = {}
        self._clock = 0
        self._index: list[bytes] | None = None

    # ---- loading and saving -------------------------------------------------

    @classmethod
    def from_directory(cls, root: str | os.PathLike[str], *, skip_session: bool = True) -> "VirtualFS":
        """Load every regular file below ``root``.

        The top-level ``session.txt`` is not part of the workspace.
        """
        broot = os.fsencode(root)
        files: dict[bytes, bytes] = {}
        for dirpath, _dirs, names in os.walk(broot):
            for name in names:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, broot).replace(os.sep.encode(), b"/")
                if skip_session and rel == b"session.txt":
                    continue
                with open(full, "rb") as fh:
                    files[rel] = fh.read()
        return cls(files)

    def write_to_directory(self, root: str | os.PathLike[str]) -> None:
        """Write every file to ``root`` at its workspace path."""
        broot = os.fsencode(root)
        made: set[bytes] = set()
        for path, content in self._files.items():
            full = os.path.join(broot, path)
            parent = os.path.dirname(full)
            if parent not in made:
                os.makedirs(parent, exist_ok=True)
                made.add(parent)
            with open(full, "wb") as fh:
                fh.write(content)

    # ---- basic access ---------------------------------------------------------

    def __contains__(self, path: bytes) -> bool:
        return path in self._files

    def __len__(self) -> int:
        return len(self._files)

    def exists(self, path: bytes) -> bool:
        return path in self._files

    def read(self, path: bytes) -> bytes | None:
        """The content of ``path``, or ``None`` if there is no such file."""
        return self._files.get(path)

    def write(self, path: bytes, content: bytes) -> None:
        """Create or replace a file."""
        files = self._files
        if self._index is not None and path not in files and _glob_eligible(path):
            self._index = None
        files[path] = content
        self._hashes.pop(path, None)

    def delete(self, path: bytes) -> bool:
        """Remove a file; returns whether it existed."""
        if path not in self._files:
            return False
        del self._files[path]
        self._hashes.pop(path, None)
        self._stamps.pop(path, None)
        if self._index is not None and _glob_eligible(path):
            self._index = None
        return True

    def touch(self, path: bytes) -> None:
        """Update the modification stamp of ``path`` (never used for builds)."""
        if path in self._files:
            self._clock += 1
            self._stamps[path] = self._clock

    def hash(self, path: bytes) -> bytes | None:
        """The 16-digit hex FNV-1a hash of the file, or ``None`` if absent."""
        h = self._hashes.get(path)
        if h is None:
            content = self._files.get(path)
            if content is None:
                return None
            h = self._hashes[path] = hash_hex(content)
        return h

    def paths(self) -> list[bytes]:
        """All file paths, sorted by byte order."""
        return sorted(self._files)

    def items(self) -> Iterator[tuple[bytes, bytes]]:
        return iter(self._files.items())

    def remove_generated(self) -> list[bytes]:
        """Remove ``out/…`` and ``.kiln-state``; return removed paths, sorted."""
        doomed = sorted(p for p in self._files if is_generated(p) or p == STATE_PATH)
        for p in doomed:
            self.delete(p)
        return doomed

    # ---- globbing ---------------------------------------------------------------

    def _glob_index(self) -> list[bytes]:
        if self._index is None:
            self._index = sorted(p for p in self._files if _glob_eligible(p))
        return self._index

    def glob(self, pattern: Glob) -> list[bytes]:
        """Sorted eligible paths matching ``pattern``.

        Costs O(log F) plus the paths that share the pattern's wildcard-free
        prefix.
        """
        index = self._glob_index()
        prefix = pattern.literal_prefix
        i = bisect_left(index, prefix)
        n = len(index)
        match = pattern.match
        out: list[bytes] = []
        while i < n:
            p = index[i]
            if not p.startswith(prefix):
                break
            if match(p):
                out.append(p)
            i += 1
        return out

    def update(self, files: Iterable[tuple[bytes, bytes]]) -> None:
        for p, c in files:
            self.write(p, c)
