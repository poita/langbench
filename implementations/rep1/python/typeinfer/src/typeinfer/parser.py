"""Recursive-descent parser for the grammar in the specification."""

from __future__ import annotations

from .errors import ParseError
from .lexer import EOF, IDENT, INT, Token, tokenize
from .syntax import (
    App,
    BinOp,
    BoolLit,
    Cons,
    Decl,
    Expr,
    Fun,
    If,
    IntLit,
    Let,
    LetRec,
    ListLit,
    NilLit,
    Tuple,
    UnitLit,
    Var,
)

_CMP_OPS = frozenset({"=", "<", ">", "<=", ">="})
_ATOM_START = frozenset({INT, IDENT, "true", "false", "(", "["})


class Parser:
    """Parses a token list; use :meth:`parse_decl` repeatedly or :meth:`parse_program`."""

    def __init__(self, tokens: list[Token]) -> None:
        self.tokens = tokens
        self.i = 0

    # -- helpers ---------------------------------------------------------

    def at_end(self) -> bool:
        return self.tokens[self.i].kind == EOF

    def _error(self, what: str) -> ParseError:
        tok = self.tokens[self.i]
        found = "end of input" if tok.kind == EOF else repr(tok.text)
        return ParseError(f"expected {what}, found {found}", tok.pos)

    def _expect(self, kind: str) -> Token:
        tok = self.tokens[self.i]
        if tok.kind != kind:
            raise self._error(repr(kind))
        self.i += 1
        return tok

    def _ident(self) -> str:
        tok = self.tokens[self.i]
        if tok.kind != IDENT:
            raise self._error("an identifier")
        self.i += 1
        return tok.text

    def _params(self) -> list[str]:
        params = []
        tokens = self.tokens
        while tokens[self.i].kind == IDENT:
            params.append(tokens[self.i].text)
            self.i += 1
        return params

    # -- declarations ----------------------------------------------------

    def parse_program(self) -> list[Decl]:
        decls = []
        while not self.at_end():
            decls.append(self.parse_decl())
        return decls

    def parse_decl(self) -> Decl:
        """Parse one declaration, including its terminating ``;;``."""
        if self.tokens[self.i].kind == "let":
            self.i += 1
            recursive = self._accept("rec")
            name = self._ident()
            params = self._params()
            if recursive and not params:
                raise self._error("a parameter")
            self._expect("=")
            value = self.parse_expr()
            expr = Fun(params, value) if params else value
            self._expect(";;")
            return Decl(name, expr, recursive)
        expr = self.parse_expr()
        self._expect(";;")
        return Decl(None, expr)

    def _accept(self, kind: str) -> bool:
        if self.tokens[self.i].kind == kind:
            self.i += 1
            return True
        return False

    # -- expressions -----------------------------------------------------

    def parse_expr(self) -> Expr:
        kind = self.tokens[self.i].kind
        if kind == "let":
            self.i += 1
            recursive = self._accept("rec")
            name = self._ident()
            params = self._params()
            if recursive and not params:
                raise self._error("a parameter")
            self._expect("=")
            value = self.parse_expr()
            self._expect("in")
            body = self.parse_expr()
            if recursive:
                return LetRec(name, Fun(params, value), body)
            return Let(name, Fun(params, value) if params else value, body)
        if kind == "fun":
            self.i += 1
            params = self._params()
            if not params:
                raise self._error("a parameter")
            self._expect("->")
            return Fun(params, self.parse_expr())
        if kind == "if":
            self.i += 1
            cond = self.parse_expr()
            self._expect("then")
            then = self.parse_expr()
            self._expect("else")
            return If(cond, then, self.parse_expr())
        return self._parse_or()

    def _parse_or(self) -> Expr:
        left = self._parse_and()
        tokens = self.tokens
        while tokens[self.i].kind == "||":
            self.i += 1
            left = BinOp("||", left, self._parse_and())
        return left

    def _parse_and(self) -> Expr:
        left = self._parse_cmp()
        tokens = self.tokens
        while tokens[self.i].kind == "&&":
            self.i += 1
            left = BinOp("&&", left, self._parse_cmp())
        return left

    def _parse_cmp(self) -> Expr:
        left = self._parse_cons()
        op = self.tokens[self.i].kind
        if op in _CMP_OPS:
            self.i += 1
            return BinOp(op, left, self._parse_cons())
        return left

    def _parse_cons(self) -> Expr:
        head = self._parse_add()
        if self.tokens[self.i].kind == "::":
            self.i += 1
            return Cons(head, self._parse_cons())
        return head

    def _parse_add(self) -> Expr:
        left = self._parse_mul()
        tokens = self.tokens
        while True:
            op = tokens[self.i].kind
            if op != "+" and op != "-":
                return left
            self.i += 1
            left = BinOp(op, left, self._parse_mul())

    def _parse_mul(self) -> Expr:
        left = self._parse_app()
        tokens = self.tokens
        while True:
            op = tokens[self.i].kind
            if op != "*" and op != "/":
                return left
            self.i += 1
            left = BinOp(op, left, self._parse_app())

    def _parse_app(self) -> Expr:
        func = self._parse_atom()
        tokens = self.tokens
        args: list[Expr] = []
        while tokens[self.i].kind in _ATOM_START:
            args.append(self._parse_atom())
        return App(func, args) if args else func

    def _parse_atom(self) -> Expr:
        tok = self.tokens[self.i]
        kind = tok.kind
        if kind == IDENT:
            self.i += 1
            return Var(tok.text)
        if kind == INT:
            self.i += 1
            return IntLit(tok.text)
        if kind == "true" or kind == "false":
            self.i += 1
            return BoolLit(kind == "true")
        if kind == "(":
            self.i += 1
            if self._accept(")"):
                return UnitLit()
            first = self.parse_expr()
            if self._accept(")"):
                return first
            items = [first]
            while self._accept(","):
                items.append(self.parse_expr())
            self._expect(")")
            return Tuple(items)
        if kind == "[":
            self.i += 1
            if self._accept("]"):
                return NilLit()
            items = [self.parse_expr()]
            while self._accept(";"):
                items.append(self.parse_expr())
            self._expect("]")
            return ListLit(items)
        raise self._error("an expression")


def parse_program(source: str) -> list[Decl]:
    """Parse a whole program into its declarations."""
    return Parser(tokenize(source)).parse_program()


def parse_expr(source: str) -> Expr:
    """Parse a single expression (no trailing ``;;``)."""
    parser = Parser(tokenize(source))
    expr = parser.parse_expr()
    if not parser.at_end():
        raise parser._error("end of input")
    return expr
