"""Recursive-descent parser: filter text -> syntax tree."""

from __future__ import annotations

from dataclasses import replace
from typing import List, Optional

from . import ast
from .errors import JQSyntaxError
from .lexer import Token, tokenize

KEYWORDS = frozenset(
    ["if", "then", "elif", "else", "end", "as", "reduce", "and", "or", "true", "false", "null"]
)
_CMP_OPS = frozenset(["==", "!=", "<", "<=", ">", ">="])


class Parser:
    def __init__(self, text: str) -> None:
        self.toks: List[Token] = tokenize(text)
        self.i = 0

    # -- token helpers ----------------------------------------------------

    def _error(self, what: str) -> JQSyntaxError:
        t = self.toks[self.i]
        got = "end of input" if t.kind == "eof" else repr(t.value)
        return JQSyntaxError(f"syntax error: expected {what}, got {got} at offset {t.pos}")

    def _is_op(self, v: str) -> bool:
        t = self.toks[self.i]
        return t.kind == "op" and t.value == v

    def _is_kw(self, v: str) -> bool:
        t = self.toks[self.i]
        return t.kind == "ident" and t.value == v

    def _eat_op(self, v: str) -> bool:
        if self._is_op(v):
            self.i += 1
            return True
        return False

    def _expect_op(self, v: str) -> None:
        if not self._eat_op(v):
            raise self._error(repr(v))

    def _expect_kw(self, v: str) -> None:
        if not self._is_kw(v):
            raise self._error(repr(v))
        self.i += 1

    def _expect_var(self) -> str:
        t = self.toks[self.i]
        if t.kind != "var":
            raise self._error("a $variable")
        self.i += 1
        return t.value

    # -- grammar ----------------------------------------------------------

    def parse(self) -> ast.Node:
        node = self.pipe()
        if self.toks[self.i].kind != "eof":
            raise self._error("end of filter")
        return node

    def pipe(self) -> ast.Node:
        left = self.comma()
        if self._is_kw("as"):
            self.i += 1
            name = self._expect_var()
            self._expect_op("|")
            return ast.As(left, name, self.pipe())
        if self._eat_op("|"):
            return ast.Pipe(left, self.pipe())
        return left

    def comma(self) -> ast.Node:
        node = self.or_()
        while self._eat_op(","):
            node = ast.Comma(node, self.or_())
        return node

    def or_(self) -> ast.Node:
        node = self.and_()
        while self._is_kw("or"):
            self.i += 1
            node = ast.Or(node, self.and_())
        return node

    def and_(self) -> ast.Node:
        node = self.cmp()
        while self._is_kw("and"):
            self.i += 1
            node = ast.And(node, self.cmp())
        return node

    def cmp(self) -> ast.Node:
        node = self.add()
        t = self.toks[self.i]
        if t.kind == "op" and t.value in _CMP_OPS:
            self.i += 1
            node = ast.BinOp(t.value, node, self.add())
        return node

    def add(self) -> ast.Node:
        node = self.mul()
        while True:
            t = self.toks[self.i]
            if t.kind == "op" and t.value in ("+", "-"):
                self.i += 1
                node = ast.BinOp(t.value, node, self.mul())
            else:
                return node

    def mul(self) -> ast.Node:
        node = self.unary()
        while True:
            t = self.toks[self.i]
            if t.kind == "op" and t.value in ("*", "/", "%"):
                self.i += 1
                node = ast.BinOp(t.value, node, self.unary())
            else:
                return node

    def unary(self) -> ast.Node:
        if self._eat_op("-"):
            return ast.Neg(self.unary())
        return self.postfix()

    def postfix(self) -> ast.Node:
        node, tolerant_ok = self.primary()
        while True:
            t = self.toks[self.i]
            if t.kind == "field":
                self.i += 1
                node = ast.Index(node, ast.Literal(t.value))
                tolerant_ok = True
            elif t.kind == "op" and t.value == ".":
                nxt = self.toks[self.i + 1]
                if nxt.kind == "str":
                    self.i += 2
                    node = ast.Index(node, ast.Literal(nxt.value))
                    tolerant_ok = True
                elif nxt.kind == "op" and nxt.value == "[":
                    self.i += 1  # `.a.[0]`: the dot is just a separator
                else:
                    raise self._error("a field name after '.'")
            elif t.kind == "op" and t.value == "[":
                self.i += 1
                node = self.bracket(node)
                tolerant_ok = True
            elif t.kind == "op" and t.value == "?":
                self.i += 1
                if tolerant_ok:
                    node = replace(node, opt=True)
                    tolerant_ok = False
                else:
                    node = ast.Try(node)
            else:
                return node

    def bracket(self, term: ast.Node) -> ast.Node:
        """Parse the rest of a ``[...]`` suffix (the ``[`` is consumed)."""
        if self._eat_op("]"):
            return ast.Iterate(term)
        if self._eat_op(":"):
            hi = None if self._is_op("]") else self.pipe()
            self._expect_op("]")
            return ast.Slice(term, None, hi)
        first = self.pipe()
        if self._eat_op(":"):
            hi = None if self._is_op("]") else self.pipe()
            self._expect_op("]")
            return ast.Slice(term, first, hi)
        self._expect_op("]")
        return ast.Index(term, first)

    def primary(self):
        """Return ``(node, tolerant_ok)``; the flag is True for ``.name`` forms."""
        t = self.toks[self.i]
        k, v = t.kind, t.value
        if k == "num" or k == "str":
            self.i += 1
            return ast.Literal(v), False
        if k == "field":
            self.i += 1
            return ast.Index(ast.Identity(), ast.Literal(v)), True
        if k == "var":
            self.i += 1
            return ast.Var(v), False
        if k == "op":
            if v == ".":
                self.i += 1
                nxt = self.toks[self.i]
                if nxt.kind == "str":
                    self.i += 1
                    return ast.Index(ast.Identity(), ast.Literal(nxt.value)), True
                return ast.Identity(), False
            if v == "(":
                self.i += 1
                node = self.pipe()
                self._expect_op(")")
                return node, False
            if v == "[":
                self.i += 1
                if self._eat_op("]"):
                    return ast.ArrayCons(None), False
                node = self.pipe()
                self._expect_op("]")
                return ast.ArrayCons(node), False
            if v == "{":
                self.i += 1
                return self.object_(), False
        if k == "ident":
            if v == "true":
                self.i += 1
                return ast.Literal(True), False
            if v == "false":
                self.i += 1
                return ast.Literal(False), False
            if v == "null":
                self.i += 1
                return ast.Literal(None), False
            if v == "if":
                self.i += 1
                return self.if_(), False
            if v == "reduce":
                self.i += 1
                return self.reduce_(), False
            if v in KEYWORDS:
                raise self._error("an expression")
            self.i += 1
            args: List[ast.Node] = []
            if self._eat_op("("):
                args.append(self.pipe())
                while self._eat_op(";"):
                    args.append(self.pipe())
                self._expect_op(")")
            return ast.Call(v, tuple(args)), False
        raise self._error("an expression")

    def if_(self) -> ast.Node:
        cond = self.pipe()
        self._expect_kw("then")
        then = self.pipe()
        if self._is_kw("elif"):
            self.i += 1
            return ast.If(cond, then, self.if_())
        orelse: Optional[ast.Node] = None
        if self._is_kw("else"):
            self.i += 1
            orelse = self.pipe()
        self._expect_kw("end")
        return ast.If(cond, then, orelse)

    def reduce_(self) -> ast.Node:
        source = self.postfix()
        self._expect_kw("as")
        name = self._expect_var()
        self._expect_op("(")
        init = self.pipe()
        self._expect_op(";")
        update = self.pipe()
        self._expect_op(")")
        return ast.Reduce(source, name, init, update)

    def object_(self) -> ast.Node:
        entries = []
        if self._eat_op("}"):
            return ast.ObjectCons(())
        while True:
            entries.append(self.entry())
            if self._eat_op(","):
                continue
            self._expect_op("}")
            return ast.ObjectCons(tuple(entries))

    def entry(self):
        t = self.toks[self.i]
        if t.kind == "var":
            self.i += 1
            return ast.Literal(t.value), ast.Var(t.value)
        if t.kind == "ident" or t.kind == "str":
            self.i += 1
            if self._eat_op(":"):
                return ast.Literal(t.value), self.objval()
            return ast.Literal(t.value), ast.Index(ast.Identity(), ast.Literal(t.value))
        if t.kind == "op" and t.value == "(":
            self.i += 1
            key = self.pipe()
            self._expect_op(")")
            self._expect_op(":")
            return key, self.objval()
        raise self._error("an object key")

    def objval(self) -> ast.Node:
        node = self.objterm()
        while self._eat_op("|"):
            node = ast.Pipe(node, self.objterm())
        return node

    def objterm(self) -> ast.Node:
        if self._eat_op("-"):
            return ast.Neg(self.objterm())
        return self.postfix()


def parse(text: str) -> ast.Node:
    """Parse filter ``text`` into a syntax tree; raises :class:`JQSyntaxError`."""
    return Parser(text).parse()
