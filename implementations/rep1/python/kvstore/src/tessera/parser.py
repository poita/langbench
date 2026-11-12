"""Parser for the command language: commands, value literals, paths, predicates (SPEC §6, §17).

``parse_command`` turns one line into a command tuple; every problem is
reported as a :class:`~tessera.errors.TesseraError` in the order SPEC §18.2
prescribes (the first problem in source order wins).
"""

from __future__ import annotations

from typing import Any, NamedTuple, Optional

from .constants import (INT_MAX, INT_MIN, MAX_DEPTH, MAX_KEY, MAX_LIMIT, MAX_PATH,
                        MAX_PATH_SEGMENTS)
from .errors import TesseraError
from .lexer import INT, STRING, SYM, WORD, Token, resolve_string, tokenize
from .query import And, Cmp, Exists, Missing, Not, Or, Predicate

COMMAND_WORDS = frozenset((
    "begin", "commit", "rollback", "checkpoint", "stat", "indexes", "put", "get",
    "delete", "update", "unset", "scan", "find", "create", "drop"))
_CMP_OPS = frozenset(("==", "!=", "<", "<=", ">", ">="))


# -- parsed commands -------------------------------------------------------------------

class Simple(NamedTuple):
    """``begin``, ``commit``, ``rollback``, ``checkpoint``, ``stat`` or ``indexes``."""
    name: str


class Put(NamedTuple):
    key: bytes
    value: Any


class Get(NamedTuple):
    key: bytes


class Delete(NamedTuple):
    key: bytes


class Update(NamedTuple):
    key: bytes
    segs: tuple[str, ...]
    value: Any


class Unset(NamedTuple):
    key: bytes
    segs: tuple[str, ...]


class Scan(NamedTuple):
    start: Optional[bytes]
    stop: Optional[bytes]
    limit: Optional[int]
    reverse: bool
    keys_only: bool


class Find(NamedTuple):
    pred: Predicate
    limit: Optional[int]


class CreateIndex(NamedTuple):
    segs: tuple[str, ...]


class DropIndex(NamedTuple):
    segs: tuple[str, ...]


Command = (Simple, Put, Get, Delete, Update, Unset, Scan, Find, CreateIndex, DropIndex)


def _syntax(detail: str = "") -> TesseraError:
    return TesseraError("syntax", detail)


class _Parser:
    def __init__(self, tokens: list[Token]):
        self.toks = tokens
        self.pos = 0

    # -- token helpers ---------------------------------------------------------------

    def peek(self, ahead: int = 0) -> Token | None:
        i = self.pos + ahead
        return self.toks[i] if i < len(self.toks) else None

    def next(self) -> Token:
        t = self.peek()
        if t is None:
            raise _syntax("unexpected end of line")
        self.pos += 1
        return t

    def at_sym(self, sym: str, ahead: int = 0) -> bool:
        t = self.peek(ahead)
        return t is not None and t.kind == SYM and t.text == sym

    def at_word(self, word: str | None = None, ahead: int = 0) -> bool:
        t = self.peek(ahead)
        return t is not None and t.kind == WORD and (word is None or t.text == word)

    def expect_sym(self, sym: str) -> None:
        t = self.next()
        if t.kind != SYM or t.text != sym:
            raise _syntax(f"expected {sym!r}")

    def finish(self) -> None:
        if self.pos != len(self.toks):
            raise _syntax("unexpected trailing token")

    # -- scalars ---------------------------------------------------------------------

    def string(self) -> str:
        t = self.next()
        if t.kind != STRING:
            raise _syntax("expected a string")
        return resolve_string(t.text)

    def key(self) -> bytes:
        raw = self.string().encode("utf-8")
        if not 1 <= len(raw) <= MAX_KEY:
            raise TesseraError("bad-key", f"{len(raw)} bytes")
        return raw

    def integer(self) -> int:
        t = self.next()
        if t.kind != INT:
            raise _syntax("expected an integer")
        n = int(t.text)
        if not INT_MIN <= n <= INT_MAX:
            raise TesseraError("int-range", t.text)
        return n

    def limit(self) -> int:
        n = self.integer()
        if not 0 <= n <= MAX_LIMIT:
            raise _syntax("limit out of range")
        return n

    # -- paths -----------------------------------------------------------------------

    def path(self) -> tuple[str, ...]:
        segs: list[str] = []
        text_len = -1
        while True:
            t = self.next()
            if t.kind != WORD:
                raise _syntax("expected a path segment")
            segs.append(t.text)
            text_len += 1 + len(t.text)
            if len(segs) > MAX_PATH_SEGMENTS or text_len > MAX_PATH:
                raise TesseraError("bad-path", ".".join(segs))
            if self.at_sym("."):
                self.pos += 1
            else:
                return tuple(segs)

    # -- values ----------------------------------------------------------------------

    def value(self, level: int = 1) -> Any:
        if level > MAX_DEPTH:
            raise TesseraError("depth")
        t = self.next()
        k = t.kind
        if k == STRING:
            return resolve_string(t.text)
        if k == INT:
            return self._int_value(t)
        if k == WORD:
            if t.text == "null":
                return None
            if t.text == "true":
                return True
            if t.text == "false":
                return False
            raise _syntax("unexpected word in value position")
        if t.text == "[":
            return self._list(level)
        if t.text == "{":
            return self._object(level)
        raise _syntax("unexpected token in value position")

    @staticmethod
    def _int_value(t: Token) -> int:
        n = int(t.text)
        if not INT_MIN <= n <= INT_MAX:
            raise TesseraError("int-range", t.text)
        return n

    def _list(self, level: int) -> list:
        items: list = []
        if self.at_sym("]"):
            self.pos += 1
            return items
        while True:
            items.append(self.value(level + 1))
            t = self.next()
            if t.kind == SYM and t.text == ",":
                continue
            if t.kind == SYM and t.text == "]":
                return items
            raise _syntax("expected ',' or ']'")

    def _object(self, level: int) -> dict:
        obj: dict = {}
        if self.at_sym("}"):
            self.pos += 1
            return obj
        while True:
            t = self.next()
            if t.kind == STRING:
                name = resolve_string(t.text)
            elif t.kind == WORD:
                name = t.text
            else:
                raise _syntax("expected a field name")
            if name in obj:
                raise TesseraError("dup-field", name)
            self.expect_sym(":")
            obj[name] = self.value(level + 1)
            t = self.next()
            if t.kind == SYM and t.text == ",":
                continue
            if t.kind == SYM and t.text == "}":
                return obj
            raise _syntax("expected ',' or '}'")

    # -- predicates ------------------------------------------------------------------

    def predicate(self) -> Predicate:
        left = self._conj()
        while self.at_word("or"):
            self.pos += 1
            left = Or(left, self._conj())
        return left

    def _conj(self) -> Predicate:
        left = self._term()
        while self.at_word("and"):
            self.pos += 1
            left = And(left, self._term())
        return left

    def _term(self) -> Predicate:
        t = self.peek()
        if t is None:
            raise _syntax("unexpected end of predicate")
        if t.kind == SYM and t.text == "(":
            self.pos += 1
            p = self.predicate()
            self.expect_sym(")")
            return p
        if t.kind != WORD:
            raise _syntax("unexpected token in predicate")
        if t.text == "not" and self.at_sym("(", 1):
            self.pos += 2
            p = self.predicate()
            self.expect_sym(")")
            return Not(p)
        if t.text == "exists" and self.at_word(None, 1):
            self.pos += 1
            return Exists(self.path())
        if t.text == "missing" and self.at_word(None, 1):
            self.pos += 1
            return Missing(self.path())
        segs = self.path()
        op = self.next()
        if op.kind != SYM or op.text not in _CMP_OPS:
            raise _syntax("expected a comparison operator")
        return Cmp(segs, op.text, self.value(1))

    # -- commands --------------------------------------------------------------------

    def command(self):
        first = self.next()
        if first.kind != WORD:
            raise _syntax("a command must start with a word")
        name = first.text
        if name not in COMMAND_WORDS:
            raise TesseraError("unknown-command", name)
        if name in ("begin", "commit", "rollback", "checkpoint", "stat", "indexes"):
            cmd = Simple(name)
        elif name == "put":
            key = self.key()
            cmd = Put(key, self.value())
        elif name == "get":
            cmd = Get(self.key())
        elif name == "delete":
            cmd = Delete(self.key())
        elif name == "update":
            key = self.key()
            segs = self.path()
            cmd = Update(key, segs, self.value())
        elif name == "unset":
            key = self.key()
            cmd = Unset(key, self.path())
        elif name == "scan":
            cmd = self._scan()
        elif name == "find":
            pred = self.predicate()
            limit = None
            if self.at_word("limit"):
                self.pos += 1
                limit = self.limit()
            cmd = Find(pred, limit)
        else:  # create / drop
            t = self.next()
            if t.kind != WORD or t.text != "index":
                raise _syntax("expected 'index'")
            segs = self.path()
            cmd = CreateIndex(segs) if name == "create" else DropIndex(segs)
        self.finish()
        return cmd

    def _scan(self) -> Scan:
        start = stop = limit = None
        reverse = keys_only = False
        seen: set[str] = set()
        while self.peek() is not None:
            t = self.next()
            if t.kind != WORD or t.text not in ("from", "to", "limit", "reverse", "keys") \
                    or t.text in seen:
                raise _syntax("bad scan option")
            seen.add(t.text)
            if t.text == "from":
                start = self.string().encode("utf-8")
            elif t.text == "to":
                stop = self.string().encode("utf-8")
            elif t.text == "limit":
                limit = self.limit()
            elif t.text == "reverse":
                reverse = True
            else:
                keys_only = True
        return Scan(start, stop, limit, reverse, keys_only)


def parse_command(line: str):
    """Parse one command line into a command tuple (``Put``, ``Scan``, ...)."""
    return _Parser(tokenize(line)).command()


def parse_predicate(text: str) -> Predicate:
    """Parse a standalone predicate such as ``age >= 30 and name == "ada"``."""
    p = _Parser(tokenize(text))
    pred = p.predicate()
    p.finish()
    return pred


def parse_value(text: str) -> Any:
    """Parse a standalone value literal such as ``{name: "ada", tags: [1, 2]}``."""
    p = _Parser(tokenize(text))
    v = p.value()
    p.finish()
    return v
