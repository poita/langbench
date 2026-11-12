"""Recursive-descent parser producing a :class:`~jtemplate.nodes.Template`.

:func:`parse_template` lexes and parses a whole template (any problem is a
:class:`~jtemplate.errors.TemplateSyntaxError`) and then checks every filter
name it uses (an unknown one is an
:class:`~jtemplate.errors.UnknownFilterError`).
"""

from __future__ import annotations

from .errors import TemplateSyntaxError, UnknownFilterError
from .filters import FILTERS
from .lexer import Item, TagItem, TextItem, Token, lex
from . import nodes as n
from . import operators


def parse_template(name: str, source: str) -> n.Template:
    """Lex, parse and filter-check ``source``."""
    parser = _Parser(lex(source))
    body = parser.parse_top()
    for filter_name in sorted(parser.filters):
        if filter_name not in FILTERS:
            raise UnknownFilterError(f"unknown filter {filter_name!r} in {name!r}")
    return n.Template(name, body, parser.blocks, parser.filters)


def _syntax(message: str) -> TemplateSyntaxError:
    return TemplateSyntaxError(message)


class _ExprParser:
    """Parses one expression from a token list."""

    def __init__(self, tokens: list[Token], filters: set[str]) -> None:
        self.tokens = tokens
        self.pos = 0
        self.filters = filters

    # -- token helpers ----------------------------------------------------

    def peek(self, offset: int = 0) -> Token | None:
        index = self.pos + offset
        return self.tokens[index] if index < len(self.tokens) else None

    def at_op(self, value: str, offset: int = 0) -> bool:
        tok = self.peek(offset)
        return tok is not None and tok[0] == "op" and tok[1] == value

    def at_kw(self, value: str, offset: int = 0) -> bool:
        tok = self.peek(offset)
        return tok is not None and tok[0] == "kw" and tok[1] == value

    def expect_op(self, value: str) -> None:
        if not self.at_op(value):
            raise _syntax(f"expected {value!r}")
        self.pos += 1

    def expect_name(self) -> str:
        tok = self.peek()
        if tok is None or tok[0] != "name":
            raise _syntax("expected a name")
        self.pos += 1
        return tok[1]  # type: ignore[return-value]

    def at_end(self) -> bool:
        return self.pos >= len(self.tokens)

    def expect_end(self) -> None:
        if not self.at_end():
            raise _syntax("unexpected tokens at end of tag")

    # -- expressions ------------------------------------------------------

    def parse_expr(self) -> n.Node:
        left = self.parse_and()
        while self.at_kw("or"):
            self.pos += 1
            left = n.Or(left, self.parse_and())
        return left

    def parse_and(self) -> n.Node:
        left = self.parse_not()
        while self.at_kw("and"):
            self.pos += 1
            left = n.And(left, self.parse_not())
        return left

    def parse_not(self) -> n.Node:
        if self.at_kw("not"):
            self.pos += 1
            return n.Not(self.parse_not())
        return self.parse_compare()

    def parse_compare(self) -> n.Node:
        first = self.parse_additive()
        rest: list = []
        while True:
            tok = self.peek()
            if tok is None:
                break
            if tok[0] == "op" and tok[1] in ("==", "!=", "<", "<=", ">", ">="):
                op = tok[1]
                self.pos += 1
            elif tok[0] == "kw" and tok[1] == "in":
                op = "in"
                self.pos += 1
            elif tok[0] == "kw" and tok[1] == "not" and self.at_kw("in", 1):
                op = "not in"
                self.pos += 2
            else:
                break
            rest.append((operators.COMPARE[op], self.parse_additive()))
        return n.Compare(first, rest) if rest else first

    def _binary(self, ops: tuple[str, ...], operand) -> n.Node:
        left = operand()
        while True:
            tok = self.peek()
            if tok is not None and tok[0] == "op" and tok[1] in ops:
                self.pos += 1
                op = tok[1]
                left = n.BinOp(op, operators.BINARY[op], left, operand())  # type: ignore[index]
            else:
                return left

    def parse_additive(self) -> n.Node:
        return self._binary(("+", "-"), self.parse_concat)

    def parse_concat(self) -> n.Node:
        return self._binary(("~",), self.parse_term)

    def parse_term(self) -> n.Node:
        return self._binary(("*", "/", "//", "%"), self.parse_power)

    def parse_power(self) -> n.Node:
        return self._binary(("**",), self.parse_filtered)

    def parse_filtered(self) -> n.Node:
        node = self.parse_unary()
        while True:
            if self.at_op("|"):
                self.pos += 1
                name = self.expect_name()
                args: list[n.Node] = []
                if self.at_op("("):
                    self.pos += 1
                    args = self._parse_list_args(")")
                self.filters.add(name)
                node = n.FilterCall(node, name, args)
            elif self.at_kw("is"):
                self.pos += 1
                negated = False
                if self.at_kw("not"):
                    self.pos += 1
                    negated = True
                tok = self.peek()
                if tok is None or tok != ("name", "defined"):
                    raise _syntax("only the 'defined' test exists")
                self.pos += 1
                node = n.IsDefined(node, negated)
            else:
                return node

    def _parse_list_args(self, closer: str) -> list[n.Node]:
        """Comma-separated expressions up to ``closer`` (no trailing comma)."""
        items: list[n.Node] = []
        if self.at_op(closer):
            self.pos += 1
            return items
        while True:
            items.append(self.parse_expr())
            if self.at_op(","):
                self.pos += 1
                continue
            self.expect_op(closer)
            return items

    def parse_unary(self) -> n.Node:
        if self.at_op("-"):
            self.pos += 1
            return n.Neg(self.parse_unary())
        return self.parse_postfix()

    def parse_postfix(self) -> n.Node:
        node = self.parse_primary()
        while True:
            if self.at_op("."):
                self.pos += 1
                node = n.Getitem(node, n.Const(self.expect_name()))
            elif self.at_op("["):
                self.pos += 1
                key = self.parse_expr()
                self.expect_op("]")
                node = n.Getitem(node, key)
            elif self.at_op("("):
                self.pos += 1
                node = self._parse_call(node)
            else:
                return node

    def _parse_call(self, callee: n.Node) -> n.Node:
        args: list[n.Node] = []
        kwargs: list[tuple[str, n.Node]] = []
        if self.at_op(")"):
            self.pos += 1
            return n.Call(callee, args, kwargs)
        while True:
            tok = self.peek()
            if tok is not None and tok[0] == "name" and self.at_op("=", 1):
                self.pos += 2
                key = tok[1]
                if any(key == existing for existing, _ in kwargs):
                    raise _syntax(f"duplicate keyword argument {key!r}")
                kwargs.append((key, self.parse_expr()))  # type: ignore[arg-type]
            else:
                if kwargs:
                    raise _syntax("positional argument after keyword argument")
                args.append(self.parse_expr())
            if self.at_op(","):
                self.pos += 1
                continue
            self.expect_op(")")
            return n.Call(callee, args, kwargs)

    def parse_primary(self) -> n.Node:
        tok = self.peek()
        if tok is None:
            raise _syntax("unexpected end of expression")
        kind, value = tok
        self.pos += 1
        if kind in ("int", "float", "str"):
            return n.Const(value)
        if kind == "name":
            return n.Name(value)  # type: ignore[arg-type]
        if kind == "kw":
            if value == "true":
                return n.Const(True)
            if value == "false":
                return n.Const(False)
            if value == "none":
                return n.Const(None)
        elif kind == "op":
            if value == "[":
                return n.ListLit(self._parse_list_args("]"))
            if value == "(":
                node = self.parse_expr()
                self.expect_op(")")
                return node
        raise _syntax(f"unexpected token {value!r}")


class _Parser:
    """Parses the item list of a template into statement nodes."""

    def __init__(self, items: list[Item]) -> None:
        self.items = items
        self.pos = 0
        self.filters: set[str] = set()
        self.blocks: dict[str, n.Block] = {}
        self.seen_extends = False

    def expr_parser(self, tokens: list[Token]) -> _ExprParser:
        return _ExprParser(tokens, self.filters)

    def parse_top(self) -> list[n.Node]:
        body, stop = self.parse_body((), 0)
        assert stop is None
        return body

    def parse_body(self, stops: tuple[str, ...], depth: int) -> tuple[list[n.Node], TagItem | None]:
        """Parse until a statement tag whose keyword is in ``stops``.

        Returns the nodes and the stopping tag (``None`` at end of input when
        ``stops`` is empty; otherwise reaching the end is a syntax error).
        """
        body: list[n.Node] = []
        items = self.items
        while self.pos < len(items):
            item = items[self.pos]
            self.pos += 1
            if isinstance(item, TextItem):
                body.append(n.Text(item.text))
                continue
            assert isinstance(item, TagItem)
            if item.opener == "{{":
                ep = self.expr_parser(item.tokens)
                node = ep.parse_expr()
                ep.expect_end()
                body.append(n.Print(node))
                continue
            tokens = item.tokens
            if not tokens or tokens[0][0] != "name":
                raise _syntax("bad statement")
            keyword = tokens[0][1]
            if keyword in stops:
                return body, item
            handler = _STATEMENTS.get(keyword)  # type: ignore[arg-type]
            if handler is None:
                raise _syntax(f"unknown or misplaced statement {keyword!r}")
            body.append(handler(self, tokens[1:], depth))
        if stops:
            raise _syntax(f"missing {stops[-1]!r}")
        return body, None

    # -- statements ---------------------------------------------------------

    def _tail_empty(self, tag: TagItem) -> None:
        if len(tag.tokens) != 1:
            raise _syntax(f"unexpected tokens after {tag.tokens[0][1]!r}")

    def stmt_if(self, tokens: list[Token], depth: int) -> n.Node:
        ep = self.expr_parser(tokens)
        cond = ep.parse_expr()
        ep.expect_end()
        branches: list[tuple[n.Node, list[n.Node]]] = []
        orelse: list[n.Node] | None = None
        while True:
            body, stop = self.parse_body(("elif", "else", "endif"), depth + 1)
            branches.append((cond, body))
            assert stop is not None
            word = stop.tokens[0][1]
            if word == "elif":
                ep = self.expr_parser(stop.tokens[1:])
                cond = ep.parse_expr()
                ep.expect_end()
            elif word == "else":
                self._tail_empty(stop)
                orelse, stop = self.parse_body(("endif",), depth + 1)
                assert stop is not None
                self._tail_empty(stop)
                break
            else:
                self._tail_empty(stop)
                break
        return n.If(branches, orelse)

    def stmt_for(self, tokens: list[Token], depth: int) -> n.Node:
        ep = self.expr_parser(tokens)
        target = ep.expect_name()
        if not ep.at_kw("in"):
            raise _syntax("expected 'in'")
        ep.pos += 1
        iterable = ep.parse_expr()
        ep.expect_end()
        body, stop = self.parse_body(("else", "endfor"), depth + 1)
        assert stop is not None
        self._tail_empty(stop)
        orelse = None
        if stop.tokens[0][1] == "else":
            orelse, stop = self.parse_body(("endfor",), depth + 1)
            assert stop is not None
            self._tail_empty(stop)
        return n.For(target, iterable, body, orelse)

    def stmt_set(self, tokens: list[Token], depth: int) -> n.Node:
        ep = self.expr_parser(tokens)
        target = ep.expect_name()
        ep.expect_op("=")
        expr = ep.parse_expr()
        ep.expect_end()
        return n.Set(target, expr)

    def stmt_macro(self, tokens: list[Token], depth: int) -> n.Node:
        ep = self.expr_parser(tokens)
        name = ep.expect_name()
        ep.expect_op("(")
        params: list[tuple[str, n.Node | None]] = []
        if ep.at_op(")"):
            ep.pos += 1
        else:
            while True:
                pname = ep.expect_name()
                if any(pname == existing for existing, _ in params):
                    raise _syntax(f"duplicate parameter {pname!r}")
                default = None
                if ep.at_op("="):
                    ep.pos += 1
                    default = ep.parse_expr()
                params.append((pname, default))
                if ep.at_op(","):
                    ep.pos += 1
                    continue
                ep.expect_op(")")
                break
        ep.expect_end()
        body, stop = self.parse_body(("endmacro",), depth + 1)
        assert stop is not None
        self._tail_empty(stop)
        return n.MacroDef(name, params, body)

    def stmt_include(self, tokens: list[Token], depth: int) -> n.Node:
        ep = self.expr_parser(tokens)
        expr = ep.parse_expr()
        ep.expect_end()
        return n.Include(expr)

    def stmt_extends(self, tokens: list[Token], depth: int) -> n.Node:
        if depth != 0 or self.seen_extends:
            raise _syntax("misplaced or repeated 'extends'")
        self.seen_extends = True
        ep = self.expr_parser(tokens)
        expr = ep.parse_expr()
        ep.expect_end()
        return n.Extends(expr)

    def stmt_block(self, tokens: list[Token], depth: int) -> n.Node:
        ep = self.expr_parser(tokens)
        name = ep.expect_name()
        ep.expect_end()
        if name in self.blocks:
            raise _syntax(f"duplicate block {name!r}")
        block = n.Block(name, [])
        self.blocks[name] = block
        body, stop = self.parse_body(("endblock",), depth + 1)
        assert stop is not None
        rest = stop.tokens[1:]
        if rest:
            if len(rest) != 1 or rest[0] != ("name", name):
                raise _syntax("endblock name does not match")
        block.body = body
        return block


_STATEMENTS = {
    "if": _Parser.stmt_if,
    "for": _Parser.stmt_for,
    "set": _Parser.stmt_set,
    "macro": _Parser.stmt_macro,
    "include": _Parser.stmt_include,
    "extends": _Parser.stmt_extends,
    "block": _Parser.stmt_block,
}
