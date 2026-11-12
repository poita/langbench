"""Formula parser: text -> syntax tree plus static dependencies.

A hand-written tokenizer and recursive-descent parser following the grammar
in the specification.  A formula that mentions an invalid reference anywhere
collapses to the constant ``#REF!`` and depends on nothing.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from . import syntax as ast
from .refs import key_col, key_row, make_key, parse_ref
from .values import REF

__all__ = ["ParsedFormula", "parse_formula", "FormulaSyntaxError"]

_AGGREGATES = frozenset({"SUM", "MIN", "MAX", "AVG", "COUNT"})
_TOKEN = re.compile(
    r"""
      (?P<space> [ ]+)
    | (?P<number> [0-9]+(?:\.[0-9]+)?)
    | (?P<string> "[^"\n]*")
    | (?P<ref>    [A-Z]+[0-9]+)
    | (?P<name>   [A-Z]+)
    | (?P<op>     <>|<=|>=|[=<>&+\-*/(),:])
    """,
    re.VERBOSE,
)

_COMPARE_OPS = frozenset({"=", "<>", "<", ">", "<=", ">="})


class FormulaSyntaxError(ValueError):
    """Raised for formulas that violate the grammar."""


@dataclass(frozen=True, slots=True)
class ParsedFormula:
    """A parsed formula: its tree and the keys of every cell it depends on."""

    root: ast.Node
    deps: frozenset[int]


def _tokenize(text: str) -> list[tuple[str, str]]:
    tokens: list[tuple[str, str]] = []
    pos = 0
    n = len(text)
    match = _TOKEN.match
    while pos < n:
        m = match(text, pos)
        if m is None:
            raise FormulaSyntaxError(f"unexpected character at {pos}: {text[pos]!r}")
        kind = m.lastgroup
        if kind != "space":
            tokens.append((kind, m.group()))
        pos = m.end()
    tokens.append(("end", ""))
    return tokens


class _Parser:
    def __init__(self, tokens: list[tuple[str, str]]) -> None:
        self.tokens = tokens
        self.pos = 0
        self.deps: set[int] = set()
        self.invalid_ref = False

    # -- token helpers -------------------------------------------------
    def _peek(self) -> tuple[str, str]:
        return self.tokens[self.pos]

    def _next(self) -> tuple[str, str]:
        tok = self.tokens[self.pos]
        self.pos += 1
        return tok

    def _expect(self, text: str) -> None:
        kind, value = self._next()
        if kind != "op" or value != text:
            raise FormulaSyntaxError(f"expected {text!r}, found {value!r}")

    def _at_op(self, ops: frozenset[str] | set[str] | tuple[str, ...]) -> str | None:
        kind, value = self.tokens[self.pos]
        if kind == "op" and value in ops:
            return value
        return None

    # -- grammar -------------------------------------------------------
    def parse(self) -> ast.Node:
        node = self._cmp()
        if self._peek()[0] != "end":
            raise FormulaSyntaxError(f"unexpected {self._peek()[1]!r}")
        return node

    def _cmp(self) -> ast.Node:
        left = self._cat()
        while (op := self._at_op(_COMPARE_OPS)) is not None:
            self.pos += 1
            left = ast.Compare(op, left, self._cat())
        return left

    def _cat(self) -> ast.Node:
        left = self._add()
        while self._at_op(("&",)):
            self.pos += 1
            left = ast.Concat(left, self._add())
        return left

    def _add(self) -> ast.Node:
        left = self._mul()
        while (op := self._at_op(("+", "-"))) is not None:
            self.pos += 1
            left = ast.Arith(op, left, self._mul())
        return left

    def _mul(self) -> ast.Node:
        left = self._unary()
        while (op := self._at_op(("*", "/"))) is not None:
            self.pos += 1
            left = ast.Arith(op, left, self._unary())
        return left

    def _unary(self) -> ast.Node:
        negations = 0
        while self._at_op(("-",)):
            self.pos += 1
            negations += 1
        node = self._primary()
        for _ in range(negations):
            node = ast.Neg(node)
        return node

    def _primary(self) -> ast.Node:
        kind, value = self._next()
        if kind == "number":
            return ast.Literal(float(value))
        if kind == "string":
            return ast.Literal(value[1:-1])
        if kind == "ref":
            return self._reference(value)
        if kind == "name":
            return self._call(value)
        if kind == "op" and value == "(":
            node = self._cmp()
            self._expect(")")
            return node
        raise FormulaSyntaxError(f"unexpected {value!r}")

    def _reference(self, text: str) -> ast.Node:
        key = parse_ref(text)
        if key is None:
            self.invalid_ref = True
            return ast.Literal(REF)
        self.deps.add(key)
        return ast.Ref(key)

    def _call(self, name: str) -> ast.Node:
        self._expect("(")
        if name == "IF":
            cond = self._cmp()
            self._expect(",")
            then = self._cmp()
            self._expect(",")
            otherwise = self._cmp()
            self._expect(")")
            return ast.If(cond, then, otherwise)
        if name not in _AGGREGATES:
            raise FormulaSyntaxError(f"unknown function {name!r}")
        args = [self._argument()]
        while self._at_op((",",)):
            self.pos += 1
            args.append(self._argument())
        self._expect(")")
        return ast.Aggregate(name, tuple(args))

    def _argument(self) -> ast.Node:
        kind, first = self._peek()
        nxt = self.tokens[self.pos + 1]
        if kind == "ref" and nxt == ("op", ":"):
            self.pos += 2
            kind2, second = self._next()
            if kind2 != "ref":
                raise FormulaSyntaxError("range needs a cell reference after ':'")
            k1, k2 = parse_ref(first), parse_ref(second)
            if k1 is None or k2 is None:
                self.invalid_ref = True
                return ast.Literal(REF)
            r1, r2 = sorted((key_row(k1), key_row(k2)))
            c1, c2 = sorted((key_col(k1), key_col(k2)))
            for r in range(r1, r2 + 1):
                base = make_key(r, 0)
                self.deps.update(range(base + c1, base + c2 + 1))
            return ast.Range(r1, c1, r2, c2)
        return self._cmp()


def parse_formula(text: str) -> ParsedFormula:
    """Parse formula *text* (the part after the leading ``=``)."""
    parser = _Parser(_tokenize(text))
    root = parser.parse()
    if parser.invalid_ref:
        return ParsedFormula(ast.Literal(REF), frozenset())
    return ParsedFormula(root, frozenset(parser.deps))
