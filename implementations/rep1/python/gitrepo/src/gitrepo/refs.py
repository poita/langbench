"""Reference lookup: loose refs, ``packed-refs`` and symbolic refs."""

from __future__ import annotations

import os

from .objects import is_hex_id

MAX_SYMREF_DEPTH = 5
_WS = b" \t\r\n\x0b\x0c"


class RefStore:
    """Resolves ref names (``HEAD``, ``refs/...``) to object ids."""

    def __init__(self, git_dir: str) -> None:
        self._git_dir = os.fsencode(git_dir)
        self._packed: dict[bytes, str] | None = None

    @staticmethod
    def valid_name(name: bytes) -> bool:
        """True if *name* may be looked up on disk."""
        if name != b"HEAD" and not name.startswith(b"refs/"):
            return False
        if b"\0" in name:
            return False
        return all(part not in (b"", b".", b"..") for part in name.split(b"/"))

    def _packed_refs(self) -> dict[bytes, str]:
        if self._packed is None:
            packed: dict[bytes, str] = {}
            try:
                with open(os.path.join(self._git_dir, b"packed-refs"), "rb") as f:
                    data = f.read()
            except OSError:
                data = b""
            for line in data.split(b"\n"):
                if not line or line[0] in b"#^":
                    continue
                oid, sep, name = line.partition(b" ")
                if sep and is_hex_id(oid):
                    packed[name] = oid.decode("ascii")
            self._packed = packed
        return self._packed

    def resolve(self, name: bytes, _depth: int = 0) -> str | None:
        """Return the object id *name* holds, or ``None`` if it does not resolve.

        The id is taken at face value; the object need not exist.
        """
        if not self.valid_name(name):
            return None
        try:
            with open(os.path.join(self._git_dir, name), "rb") as f:
                content = f.read()
        except (FileNotFoundError, NotADirectoryError, IsADirectoryError):
            return self._packed_refs().get(name)
        except OSError:
            return None
        content = content.rstrip(_WS)
        if content.startswith(b"ref: "):
            if _depth >= MAX_SYMREF_DEPTH:
                return None
            return self.resolve(content[5:], _depth + 1)
        return content.decode("ascii") if is_hex_id(content) else None
