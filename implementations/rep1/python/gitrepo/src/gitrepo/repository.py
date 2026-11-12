"""The :class:`Repository` facade: objects, refs and revision syntax."""

from __future__ import annotations

import os

from .errors import CorruptObjectError, GitRepoError, ObjectNotFoundError, RevisionError
from .objects import Commit, TreeEntry, parse_commit, parse_tag_target, parse_tree
from .odb import ObjectDatabase
from .refs import RefStore

_NAME_PATTERNS = (b"%s", b"refs/%s", b"refs/tags/%s", b"refs/heads/%s",
                  b"refs/remotes/%s", b"refs/remotes/%s/HEAD")
_DIGITS = frozenset(b"0123456789")


class Repository:
    """A git repository (a ``.git`` directory or a bare repository) on disk.

    >>> repo = Repository("path/to/repo")          # doctest: +SKIP
    >>> repo.rev_parse(b"HEAD^{tree}")             # doctest: +SKIP
    '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

    Revisions are ``bytes`` (ref names are not guaranteed to be UTF-8); object
    ids are 40-digit lowercase hex ``str``.
    """

    def __init__(self, git_dir: str | os.PathLike[str]) -> None:
        git_dir = os.fspath(git_dir)
        self.git_dir = git_dir
        self.odb = ObjectDatabase(git_dir)
        self.refs = RefStore(git_dir)
        self._commits: dict[str, Commit | GitRepoError] = {}
        self._trees: dict[str, list[TreeEntry] | GitRepoError] = {}

    # -- parsed objects (each parsed at most once) ---------------------------

    def read_object(self, oid: str) -> tuple[str, bytes]:
        """``(type, payload)`` of *oid*, unverified."""
        return self.odb.read(oid)

    def commit(self, oid: str) -> Commit:
        """The parsed commit *oid*; fails if it is missing, damaged or not a commit."""
        return self._parsed(self._commits, oid, "commit", parse_commit)

    def tree(self, oid: str) -> list[TreeEntry]:
        """The entries of tree *oid* in stored order."""
        return self._parsed(self._trees, oid, "tree", parse_tree)

    def _parsed(self, cache, oid, wanted, parser):
        hit = cache.get(oid)
        if hit is None:
            try:
                kind, payload = self.odb.read(oid)
                if kind != wanted:
                    raise CorruptObjectError(f"object {oid} is a {kind}, not a {wanted}")
                hit = parser(payload)
            except GitRepoError as exc:
                hit = exc
            cache[oid] = hit
        if isinstance(hit, GitRepoError):
            raise hit
        return hit

    # -- revision syntax ------------------------------------------------------

    def rev_parse(self, rev: bytes) -> str:
        """Resolve *rev* to an object id; raises :class:`RevisionError` on failure."""
        if rev.endswith(b"}"):
            pos = rev.rfind(b"^{")
            if pos > 0:
                oid = self.rev_parse(rev[:pos])
                return self._peel_operator(oid, rev[pos + 2:-1])
        end = len(rev)
        start = end
        while start > 0 and rev[start - 1] in _DIGITS:
            start -= 1
        if start >= 2 and rev[start - 1] in b"^~":
            op = rev[start - 1:start]
            n = int(rev[start:end]) if start < end else 1
            oid = self.peel(self.rev_parse(rev[:start - 1]), "commit")
            if n == 0:
                return oid
            if op == b"^":
                parents = self.commit(oid).parents
                if n > len(parents):
                    raise RevisionError(f"commit {oid} has no parent {n}")
                return parents[n - 1]
            for _ in range(n):
                parents = self.commit(oid).parents
                if not parents:
                    raise RevisionError("ran out of ancestors")
                oid = parents[0]
            return oid
        for pattern in _NAME_PATTERNS:
            oid = self.refs.resolve(pattern % rev)
            if oid is not None:
                return oid
        return self._resolve_hex(rev)

    def _resolve_hex(self, rev: bytes) -> str:
        if not 4 <= len(rev) <= 40 or not all(c in b"0123456789abcdefABCDEF" for c in rev):
            raise RevisionError(f"unknown revision {rev!r}")
        text = rev.decode("ascii").lower()
        if len(text) == 40:
            if not self.odb.contains(text):
                raise RevisionError(f"no such object {text}")
            return text
        try:
            return self.odb.expand_prefix(text)
        except ObjectNotFoundError as exc:
            raise RevisionError(str(exc)) from exc

    def _peel_operator(self, oid: str, what: bytes) -> str:
        if what == b"":
            return self.peel(oid, None)
        if what == b"object":
            if not self.odb.contains(oid):
                raise RevisionError(f"no such object {oid}")
            return oid
        if what in (b"commit", b"tree", b"blob", b"tag"):
            return self.peel(oid, what.decode("ascii"))
        raise RevisionError(f"unknown peel {what!r}")

    def peel(self, oid: str, wanted: str | None) -> str:
        """Peel *oid* towards type *wanted* (``None`` strips tags only).

        Mirrors the ``^{...}`` operators; raises :class:`RevisionError` when the
        object cannot be peeled to that type.
        """
        while True:
            try:
                kind, payload = self.odb.read(oid)
            except GitRepoError as exc:
                raise RevisionError(str(exc)) from exc
            if wanted is None:
                if kind != "tag":
                    return oid
            elif kind == wanted:
                return oid
            if kind == "tag":
                target = parse_tag_target(payload)
                if target is None:
                    raise RevisionError(f"tag {oid} has no valid object header")
                oid = target
            elif kind == "commit":
                try:
                    tree = self.commit(oid).tree
                except GitRepoError as exc:
                    raise RevisionError(str(exc)) from exc
                if tree is None:
                    raise RevisionError(f"commit {oid} has no tree")
                oid = tree
            else:
                raise RevisionError(f"cannot peel {kind} {oid} to {wanted}")
