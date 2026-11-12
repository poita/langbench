"""The query language: lexer, recursive-descent parser and query tree.

The parser never fails: every input line yields a (possibly empty) tree.
"""

from __future__ import annotations

from dataclasses import dataclass

from .analysis import STOP_WORDS, WHITESPACE, term_for, token_texts

__all__ = [
    "Atom",
    "And",
    "Or",
    "Not",
    "Node",
    "make_atom",
    "parse_query",
    "positive_atoms",
]


@dataclass(frozen=True, slots=True)
class Atom:
    """A search atom: a tuple of terms that must occur adjacently, in order."""

    terms: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class And:
    children: tuple[Node, ...]


@dataclass(frozen=True, slots=True)
class Or:
    children: tuple[Node, ...]


@dataclass(frozen=True, slots=True)
class Not:
    """``count`` directly nested ``NOT`` operators applied to ``child``."""

    child: Node
    count: int = 1


type Node = Atom | And | Or | Not

# Lexer token kinds.
_LPAREN, _RPAREN, _AND, _OR, _NOT, _PHRASE = range(6)
_OPERATORS = {"AND": _AND, "OR": _OR, "NOT": _NOT}
_WORD_STOPPERS = frozenset(WHITESPACE) | {"(", ")", '"'}


def make_atom(body: str) -> Atom | None:
    """Analyse a phrase body into an atom, or ``None`` if the atom is empty.

    A body without terms, or with a single term whose token text is a stop
    word, gives an empty atom.
    """
    texts = token_texts(body)
    if not texts or (len(texts) == 1 and texts[0] in STOP_WORDS):
        return None
    return Atom(tuple(term_for(t) for t in texts))


def _lex(text: str) -> list[tuple[int, str]]:
    tokens: list[tuple[int, str]] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch in WHITESPACE:
            i += 1
        elif ch == "(":
            tokens.append((_LPAREN, ch))
            i += 1
        elif ch == ")":
            tokens.append((_RPAREN, ch))
            i += 1
        elif ch == '"':
            end = text.find('"', i + 1)
            if end < 0:
                end = n
            tokens.append((_PHRASE, text[i + 1 : end]))
            i = end + 1
        else:
            j = i
            while j < n and text[j] not in _WORD_STOPPERS:
                j += 1
            word = text[i:j]
            kind = _OPERATORS.get(word)
            tokens.append((kind, word) if kind is not None else (_PHRASE, word))
            i = j
    return tokens


class _Parser:
    def __init__(self, text: str) -> None:
        self.tokens = _lex(text)
        self.pos = 0

    def _peek(self) -> int | None:
        return self.tokens[self.pos][0] if self.pos < len(self.tokens) else None

    @staticmethod
    def _combine(kind: type[And] | type[Or], parts: list[Node]) -> Node | None:
        if not parts:
            return None
        if len(parts) == 1:
            return parts[0]
        return kind(tuple(parts))

    def parse(self) -> Node | None:
        return self._or()  # leftover tokens (stray ')') are discarded

    def _or(self) -> Node | None:
        parts = []
        first = self._and()
        if first is not None:
            parts.append(first)
        while self._peek() == _OR:
            self.pos += 1
            part = self._and()
            if part is not None:
                parts.append(part)
        return self._combine(Or, parts)

    def _and(self) -> Node | None:
        parts = []
        while True:
            kind = self._peek()
            if kind is None or kind == _RPAREN or kind == _OR:
                break
            if kind == _AND:
                self.pos += 1
                continue
            part = self._not()
            if part is not None:
                parts.append(part)
        return self._combine(And, parts)

    def _not(self) -> Node | None:
        count = 0
        while self._peek() == _NOT:
            self.pos += 1
            count += 1
        primary = self._primary()
        if primary is None:
            return None
        return Not(primary, count) if count else primary

    def _primary(self) -> Node | None:
        kind = self._peek()
        if kind is None or kind == _RPAREN:
            return None
        token = self.tokens[self.pos]
        self.pos += 1
        if kind == _LPAREN:
            inner = self._or()
            if self._peek() == _RPAREN:
                self.pos += 1
            return inner
        if kind == _PHRASE:
            return make_atom(token[1])
        return None  # a stray operator


def parse_query(text: str) -> Node | None:
    """Parse query text into a tree; ``None`` is the empty tree."""
    return _Parser(text).parse()


def positive_atoms(tree: Node | None) -> list[Atom]:
    """The atoms under an even number of ``NOT``s, first-met order, deduplicated."""
    found: dict[Atom, None] = {}

    def walk(node: Node, positive: bool) -> None:
        if isinstance(node, Atom):
            if positive:
                found.setdefault(node)
        elif isinstance(node, Not):
            walk(node.child, positive == (node.count % 2 == 0))
        else:
            for child in node.children:
                walk(child, positive)

    if tree is not None:
        walk(tree, True)
    return list(found)
