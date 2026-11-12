"""Recursive-descent parser producing a :class:`~datalog.syntax.Program`."""

from __future__ import annotations

from .errors import ParseError
from .lexer import ANON, IDENT, INT, NOT, PUNCT, VAR, Token, tokenize
from .syntax import (
    COMPARISON_OPERATORS,
    Atom,
    Comparison,
    Literal,
    Program,
    Rule,
    Term,
    Variable,
)


class _Parser:
    def __init__(self, source: str) -> None:
        self._tokens = list(tokenize(source))
        self._i = 0
        self._anon = 0

    # -- token helpers ---------------------------------------------------
    def _peek(self) -> Token | None:
        return self._tokens[self._i] if self._i < len(self._tokens) else None

    def _next(self) -> Token:
        tok = self._peek()
        if tok is None:
            raise ParseError("unexpected end of input")
        self._i += 1
        return tok

    def _at(self, text: str) -> bool:
        tok = self._peek()
        return tok is not None and tok.kind == PUNCT and tok.text == text

    def _expect(self, text: str) -> None:
        tok = self._next()
        if tok.kind != PUNCT or tok.text != text:
            raise ParseError(f"expected {text!r} at offset {tok.pos}, found {tok.text!r}")

    # -- grammar ---------------------------------------------------------
    def program(self) -> Program:
        program = Program()
        while self._peek() is not None:
            if self._at("?-"):
                self._next()
                program.queries.append(self._atom())
                self._expect(".")
                continue
            head = self._atom()
            body: list = []
            if self._at(":-"):
                self._next()
                body.append(self._literal())
                while self._at(","):
                    self._next()
                    body.append(self._literal())
            self._expect(".")
            program.rules.append(Rule(head, tuple(body)))
        return program

    def _atom(self) -> Atom:
        tok = self._next()
        if tok.kind != IDENT:
            raise ParseError(f"expected a predicate name at offset {tok.pos}, found {tok.text!r}")
        self._expect("(")
        args = [self._term()]
        while self._at(","):
            self._next()
            args.append(self._term())
        self._expect(")")
        return Atom(tok.text, tuple(args))

    def _term(self) -> Term:
        tok = self._next()
        if tok.kind == INT:
            return int(tok.text)
        if tok.kind == IDENT:
            return tok.text
        if tok.kind == VAR:
            return Variable(tok.text)
        if tok.kind == ANON:
            self._anon += 1
            return Variable(f"_{self._anon}")  # cannot clash: user variables start upper-case
        raise ParseError(f"expected a term at offset {tok.pos}, found {tok.text!r}")

    def _literal(self) -> Literal | Comparison:
        tok = self._peek()
        if tok is None:
            raise ParseError("unexpected end of input")
        if tok.kind == NOT:
            self._next()
            return Literal(self._atom(), negated=True)
        nxt = self._tokens[self._i + 1] if self._i + 1 < len(self._tokens) else None
        if tok.kind == IDENT and nxt is not None and nxt.kind == PUNCT and nxt.text == "(":
            return Literal(self._atom())
        left = self._term()
        op = self._next()
        if op.kind != PUNCT or op.text not in COMPARISON_OPERATORS:
            raise ParseError(f"expected a comparison operator at offset {op.pos}, found {op.text!r}")
        return Comparison(op.text, left, self._term())


def parse(source: str) -> Program:
    """Parse Datalog source text.  Raises :class:`ParseError` if malformed."""
    return _Parser(source).program()
