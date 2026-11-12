"""Recursive-descent parser: filter text -> syntax tree.

The tree is made of plain tuples whose first element names the node kind:

``("id",)``  ``("lit", value)``  ``("var", name)``
``("index", target, key, opt)``  ``("iter", target, opt)``
``("slice", target, lo, hi, opt)``  ``("try", body)``  ``("group", body)``
``("neg", body)``  ``("binop", op, left, right)``  ``("and", l, r)``  ``("or", l, r)``
``("pipe", l, r)``  ``("comma", l, r)``  ``("as", src, name, body)``
``("reduce", src, name, init, update)``  ``("if", cond, then, else_or_None)``
``("array", body_or_None)``  ``("object", [(key, value), ...])``
``("call", name, [args])``

``opt`` is true when the suffix carried a directly attached ``?``.
"""

from __future__ import annotations

from typing import Any

from .errors import JQSyntaxError
from .lexer import Token, tokenize

Node = tuple

_KEYWORDS = {"if", "then", "elif", "else", "end", "as", "reduce", "and", "or"}
_CMP = {"==", "!=", "<", "<=", ">", ">="}
_PATH_KINDS = {"index", "iter", "slice"}
_IDENTITY: Node = ("id",)


class _Parser:
    def __init__(self, tokens: list[Token]) -> None:
        self.toks = tokens
        self.i = 0

    # -- token helpers -----------------------------------------------------
    def peek(self) -> Token:
        return self.toks[self.i]

    def next(self) -> Token:
        t = self.toks[self.i]
        self.i += 1
        return t

    def is_op(self, text: str) -> bool:
        k, v = self.toks[self.i]
        return k == "op" and v == text

    def is_word(self, text: str) -> bool:
        k, v = self.toks[self.i]
        return k == "ident" and v == text

    def expect_op(self, text: str) -> None:
        if not self.is_op(text):
            raise JQSyntaxError(f"expected {text!r}, found {self.peek()[1]!r}")
        self.i += 1

    def expect_word(self, text: str) -> None:
        if not self.is_word(text):
            raise JQSyntaxError(f"expected {text!r}, found {self.peek()[1]!r}")
        self.i += 1

    def expect_var(self) -> str:
        k, v = self.next()
        if k != "var":
            raise JQSyntaxError("expected a $variable")
        return v

    # -- grammar -----------------------------------------------------------
    def pipe(self) -> Node:
        node = self.comma()
        if self.is_word("as"):
            self.i += 1
            name = self.expect_var()
            self.expect_op("|")
            return ("as", node, name, self.pipe())
        if self.is_op("|"):
            self.i += 1
            return ("pipe", node, self.pipe())
        return node

    def comma(self) -> Node:
        node = self.or_()
        while self.is_op(","):
            self.i += 1
            node = ("comma", node, self.or_())
        return node

    def or_(self) -> Node:
        node = self.and_()
        while self.is_word("or"):
            self.i += 1
            node = ("or", node, self.and_())
        return node

    def and_(self) -> Node:
        node = self.cmp()
        while self.is_word("and"):
            self.i += 1
            node = ("and", node, self.cmp())
        return node

    def cmp(self) -> Node:
        node = self.add()
        k, v = self.peek()
        if k == "op" and v in _CMP:
            self.i += 1
            node = ("binop", v, node, self.add())
        return node

    def add(self) -> Node:
        node = self.mul()
        while True:
            k, v = self.peek()
            if k == "op" and (v == "+" or v == "-"):
                self.i += 1
                node = ("binop", v, node, self.mul())
            else:
                return node

    def mul(self) -> Node:
        node = self.unary()
        while True:
            k, v = self.peek()
            if k == "op" and v in ("*", "/", "%"):
                self.i += 1
                node = ("binop", v, node, self.unary())
            else:
                return node

    def unary(self) -> Node:
        if self.is_op("-"):
            self.i += 1
            return ("neg", self.unary())
        return self.postfix()

    def postfix(self) -> Node:
        node = self.primary()
        while True:
            k, v = self.peek()
            if k == "field":
                self.i += 1
                node = ("index", node, ("lit", v), False)
            elif k == "op":
                if v == ".":
                    nk, _ = self.toks[self.i + 1]
                    if nk == "str":
                        self.i += 1
                        node = ("index", node, ("lit", self.next()[1]), False)
                    elif self.toks[self.i + 1] == ("op", "["):
                        self.i += 1  # ``.a.[0]``
                    else:
                        raise JQSyntaxError("unexpected '.'")
                elif v == "[":
                    self.i += 1
                    node = self.bracket(node)
                elif v == "?":
                    self.i += 1
                    if node[0] in _PATH_KINDS and not node[-1]:
                        node = node[:-1] + (True,)
                    else:
                        node = ("try", node)
                else:
                    return node
            else:
                return node

    def bracket(self, target: Node) -> Node:
        """Parse a suffix after ``[`` has been consumed."""
        if self.is_op("]"):
            self.i += 1
            return ("iter", target, False)
        lo: Node | None = None
        if not self.is_op(":"):
            lo = self.pipe()
        if self.is_op(":"):
            self.i += 1
            hi: Node | None = None
            if not self.is_op("]"):
                hi = self.pipe()
            self.expect_op("]")
            return ("slice", target, lo or ("lit", None), hi or ("lit", None), False)
        self.expect_op("]")
        return ("index", target, lo, False)

    def primary(self) -> Node:
        kind, v = self.next()
        if kind == "num" or kind == "str":
            return ("lit", v)
        if kind == "var":
            return ("var", v)
        if kind == "field":
            return ("index", _IDENTITY, ("lit", v), False)
        if kind == "op":
            if v == ".":
                k2, v2 = self.peek()
                if k2 == "str":
                    self.i += 1
                    return ("index", _IDENTITY, ("lit", v2), False)
                return _IDENTITY
            if v == "(":
                body = self.pipe()
                self.expect_op(")")
                return ("group", body)
            if v == "[":
                if self.is_op("]"):
                    self.i += 1
                    return ("array", None)
                body = self.pipe()
                self.expect_op("]")
                return ("array", body)
            if v == "{":
                return self.object()
        if kind == "ident":
            if v == "true":
                return ("lit", True)
            if v == "false":
                return ("lit", False)
            if v == "null":
                return ("lit", None)
            if v == "if":
                return self.if_()
            if v == "reduce":
                return self.reduce()
            if v in _KEYWORDS:
                raise JQSyntaxError(f"unexpected keyword {v!r}")
            args: list[Node] = []
            if self.is_op("("):
                self.i += 1
                args.append(self.pipe())
                while self.is_op(";"):
                    self.i += 1
                    args.append(self.pipe())
                self.expect_op(")")
            return ("call", v, args)
        raise JQSyntaxError(f"unexpected token {v!r}")

    def if_(self) -> Node:
        cond = self.pipe()
        self.expect_word("then")
        then = self.pipe()
        if self.is_word("elif"):
            self.i += 1
            return ("if", cond, then, self.if_())  # nested ``if`` consumes ``end``
        els: Node | None = None
        if self.is_word("else"):
            self.i += 1
            els = self.pipe()
        self.expect_word("end")
        return ("if", cond, then, els)

    def reduce(self) -> Node:
        src = self.postfix()
        self.expect_word("as")
        name = self.expect_var()
        self.expect_op("(")
        init = self.pipe()
        self.expect_op(";")
        update = self.pipe()
        self.expect_op(")")
        return ("reduce", src, name, init, update)

    def object(self) -> Node:
        entries: list[tuple[Node, Node]] = []
        if self.is_op("}"):
            self.i += 1
            return ("object", entries)
        while True:
            kind, v = self.next()
            if kind == "var":
                entries.append((("lit", v), ("var", v)))
            elif kind == "op" and v == "(":
                key = self.pipe()
                self.expect_op(")")
                self.expect_op(":")
                entries.append((("group", key), self.objval()))
            elif kind == "ident" or kind == "str":
                if self.is_op(":"):
                    self.i += 1
                    entries.append((("lit", v), self.objval()))
                else:
                    entries.append((("lit", v), ("index", _IDENTITY, ("lit", v), False)))
            else:
                raise JQSyntaxError(f"unexpected {v!r} in object construction")
            if self.is_op(","):
                self.i += 1
                continue
            self.expect_op("}")
            return ("object", entries)

    def objval(self) -> Node:
        node = self.objterm()
        while self.is_op("|"):
            self.i += 1
            node = ("pipe", node, self.objterm())
        return node

    def objterm(self) -> Node:
        if self.is_op("-"):
            self.i += 1
            return ("neg", self.objterm())
        return self.postfix()


def parse(source: str) -> Node:
    """Parse filter text into a syntax tree (raises ``JQSyntaxError``)."""
    p = _Parser(tokenize(source))
    node = p.pipe()
    if p.peek()[0] != "end":
        raise JQSyntaxError(f"unexpected token {p.peek()[1]!r}")
    return node
