"""Tokeniser and recursive-descent parser."""

from __future__ import annotations

import re
from typing import Iterator

from .errors import ParseError
from .syntax import (
    Atom, Comparison, Const, Literal, Not, Program, Query, Rule, Term, Var,
)

_TOKEN = re.compile(
    r"""
    (?P<skip>(?:[ \t\r\n]+|%[^\n]*)+)
  | (?P<punct>\?-|:-|<=|>=|!=|[(),.<>=])
  | (?P<int>-?[0-9]+)
  | (?P<ident>[a-z][a-z0-9_]*)
  | (?P<var>[A-Z][A-Za-z0-9_]*)
  | (?P<anon>_)
    """,
    re.VERBOSE,
)

_CMP_OPS = {"<", "<=", ">", ">=", "=", "!="}

# (kind, text) with kind one of: punct int ident var anon
Token = tuple[str, str]


def tokenize(text: str) -> Iterator[Token]:
    """Yield ``(kind, text)`` tokens, skipping whitespace and ``%`` comments."""
    pos, end = 0, len(text)
    match = _TOKEN.match
    while pos < end:
        m = match(text, pos)
        if m is None:
            raise ParseError(f"unexpected character {text[pos]!r} at offset {pos}")
        pos = m.end()
        kind = m.lastgroup
        if kind != "skip":
            yield kind, m.group()


class _Parser:
    def __init__(self, text: str) -> None:
        self.tokens = list(tokenize(text))
        self.i = 0
        self.fresh = 0  # counter for anonymous variables

    # -- token helpers -----------------------------------------------------
    def peek(self, offset: int = 0) -> Token | None:
        j = self.i + offset
        return self.tokens[j] if j < len(self.tokens) else None

    def next(self) -> Token:
        tok = self.peek()
        if tok is None:
            raise ParseError("unexpected end of input")
        self.i += 1
        return tok

    def expect(self, text: str) -> None:
        tok = self.next()
        if tok != ("punct", text):
            raise ParseError(f"expected {text!r}, found {tok[1]!r}")

    def at(self, text: str) -> bool:
        return self.peek() == ("punct", text)

    # -- grammar -----------------------------------------------------------
    def program(self) -> Program:
        rules: list[Rule] = []
        queries: list[Query] = []
        while self.peek() is not None:
            self.fresh = 0  # variable names are scoped to a clause
            if self.at("?-"):
                self.next()
                queries.append(Query(self.atom()))
                self.expect(".")
                continue
            head = self.atom()
            body: list[Literal] = []
            if self.at(":-"):
                self.next()
                body.append(self.literal())
                while self.at(","):
                    self.next()
                    body.append(self.literal())
            self.expect(".")
            rules.append(Rule(head, tuple(body)))
        return Program(tuple(rules), tuple(queries))

    def atom(self) -> Atom:
        kind, name = self.next()
        if kind != "ident" or name == "not":
            raise ParseError(f"expected a predicate name, found {name!r}")
        self.expect("(")
        args = [self.term()]
        while self.at(","):
            self.next()
            args.append(self.term())
        self.expect(")")
        return Atom(name, tuple(args))

    def literal(self) -> Literal:
        tok = self.peek()
        if tok == ("ident", "not"):
            self.next()
            return Not(self.atom())
        if tok is not None and tok[0] == "ident" and self.peek(1) == ("punct", "("):
            return self.atom()
        left = self.term()
        kind, op = self.next()
        if kind != "punct" or op not in _CMP_OPS:
            raise ParseError(f"expected a comparison operator, found {op!r}")
        return Comparison(op, left, self.term())

    def term(self) -> Term:
        kind, text = self.next()
        if kind == "int":
            return Const(int(text))
        if kind == "ident" and text != "not":
            return Const(text)
        if kind == "var":
            return Var(text)
        if kind == "anon":
            self.fresh += 1
            return Var(f"_{self.fresh}")  # cannot clash: user variables start A-Z
        raise ParseError(f"expected a term, found {text!r}")


def parse(text: str) -> Program:
    """Parse a whole program.

    Raises :class:`~datalog.errors.ParseError` on malformed input.
    """
    return _Parser(text).program()


def parse_atom(text: str) -> Atom:
    """Parse a single atom such as ``"path(1, X)"`` (no trailing ``.``)."""
    p = _Parser(text)
    atom = p.atom()
    if p.peek() is not None:
        raise ParseError("trailing input after atom")
    return atom
