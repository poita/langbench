"""Parser: template source to syntax tree (:class:`Template`)."""

from __future__ import annotations

from . import nodes as n
from .errors import FilterError, TemplateSyntaxError
from .filters import FILTER_NAMES
from .lexer import FLOAT, INT, NAME, OP, STRING, Token, split_template

KEYWORDS = frozenset({"and", "or", "not", "in", "is", "true", "false", "none"})
_COMPARE_OPS = frozenset({"==", "!=", "<", "<=", ">", ">="})


class Template:
    """A parsed template: its body, its block table and the filters it uses."""

    __slots__ = ("body", "blocks", "filters")

    def __init__(self, body: list, blocks: dict[str, n.Block], filters: set[str]) -> None:
        self.body = body
        self.blocks = blocks
        self.filters = filters


def parse_template(source: str) -> Template:
    """Lex, parse and filter-check *source*.

    Raises :class:`TemplateSyntaxError` for lexical and grammatical errors
    and then :class:`FilterError` for an unknown filter name anywhere.
    """
    parser = _Parser(split_template(source))
    body, terminator = parser.parse_body(frozenset(), top_level=True)
    if terminator is not None:  # pragma: no cover - top level has no terminators
        raise TemplateSyntaxError("unexpected tag")
    for name in parser.filters:
        if name not in FILTER_NAMES:
            raise FilterError(f"unknown filter {name!r}")
    return Template(body, parser.blocks, parser.filters)


class _Tokens:
    """A cursor over the tokens of one tag."""

    __slots__ = ("tokens", "pos")

    def __init__(self, tokens: list[Token]) -> None:
        self.tokens = tokens
        self.pos = 0

    def peek(self, offset: int = 0) -> Token | None:
        index = self.pos + offset
        return self.tokens[index] if index < len(self.tokens) else None

    def next(self) -> Token:
        token = self.peek()
        if token is None:
            raise TemplateSyntaxError("unexpected end of tag")
        self.pos += 1
        return token

    def at_end(self) -> bool:
        return self.pos >= len(self.tokens)

    def is_op(self, value: str, offset: int = 0) -> bool:
        token = self.peek(offset)
        return token is not None and token[0] == OP and token[1] == value

    def is_name(self, value: str, offset: int = 0) -> bool:
        token = self.peek(offset)
        return token is not None and token[0] == NAME and token[1] == value

    def expect_op(self, value: str) -> None:
        if not self.is_op(value):
            raise TemplateSyntaxError(f"expected {value!r}")
        self.pos += 1

    def expect_name(self) -> str:
        token = self.next()
        if token[0] != NAME:
            raise TemplateSyntaxError("expected a name")
        return token[1]

    def expect_identifier(self) -> str:
        name = self.expect_name()
        if name in KEYWORDS:
            raise TemplateSyntaxError(f"{name!r} cannot be used as a name")
        return name

    def expect_end(self) -> None:
        if not self.at_end():
            raise TemplateSyntaxError("unexpected tokens at the end of the tag")


class _Parser:
    def __init__(self, items: list) -> None:
        self.items = items
        self.index = 0
        self.blocks: dict[str, n.Block] = {}
        self.filters: set[str] = set()
        self.seen_extends = False

    # -- statements ------------------------------------------------------

    def parse_body(self, terminators: frozenset[str], top_level: bool = False):
        """Parse items until a statement keyword in *terminators*.

        Returns ``(body, tokens of the terminating tag or None)``.
        """
        body: list = []
        items = self.items
        while self.index < len(items):
            kind, payload = items[self.index]
            self.index += 1
            if kind == "text":
                body.append(n.Text(payload))
            elif kind == "var":
                tokens = _Tokens(payload)
                expr = self.parse_expression(tokens)
                tokens.expect_end()
                body.append(n.Output(expr))
            else:
                tokens = _Tokens(payload)
                head = tokens.peek()
                if head is None or head[0] != NAME:
                    raise TemplateSyntaxError("a statement must start with a keyword")
                keyword = head[1]
                if keyword in terminators:
                    return body, tokens
                tokens.pos = 1
                handler = getattr(self, "stmt_" + keyword, None)
                if handler is None or keyword in KEYWORDS:
                    raise TemplateSyntaxError(f"unknown statement {keyword!r}")
                body.append(handler(tokens, top_level))
        return body, None

    def _body_until(self, terminators: frozenset[str]):
        body, tokens = self.parse_body(terminators)
        if tokens is None:
            raise TemplateSyntaxError("missing end tag")
        return body, tokens

    def stmt_if(self, tokens: _Tokens, top_level: bool) -> n.If:
        branches = []
        orelse = None
        condition = self.parse_expression(tokens)
        tokens.expect_end()
        while True:
            body, term = self._body_until(frozenset({"elif", "else", "endif"}))
            branches.append((condition, body))
            word = term.next()[1]
            if word == "elif":
                condition = self.parse_expression(term)
                term.expect_end()
            elif word == "else":
                term.expect_end()
                orelse, term = self._body_until(frozenset({"endif"}))
                term.next()
                term.expect_end()
                break
            else:
                term.expect_end()
                break
        return n.If(branches, orelse)

    def stmt_for(self, tokens: _Tokens, top_level: bool) -> n.For:
        var = tokens.expect_identifier()
        if not tokens.is_name("in"):
            raise TemplateSyntaxError("expected 'in'")
        tokens.pos += 1
        iterable = self.parse_expression(tokens)
        tokens.expect_end()
        body, term = self._body_until(frozenset({"else", "endfor"}))
        orelse = None
        if term.next()[1] == "else":
            term.expect_end()
            orelse, term = self._body_until(frozenset({"endfor"}))
            term.next()
        term.expect_end()
        return n.For(var, iterable, body, orelse)

    def stmt_set(self, tokens: _Tokens, top_level: bool) -> n.Set:
        name = tokens.expect_identifier()
        tokens.expect_op("=")
        expr = self.parse_expression(tokens)
        tokens.expect_end()
        return n.Set(name, expr)

    def stmt_macro(self, tokens: _Tokens, top_level: bool) -> n.MacroDef:
        name = tokens.expect_identifier()
        tokens.expect_op("(")
        params: list = []
        seen: set[str] = set()
        if not tokens.is_op(")"):
            while True:
                param = tokens.expect_identifier()
                if param in seen:
                    raise TemplateSyntaxError(f"duplicate parameter {param!r}")
                seen.add(param)
                default = None
                if tokens.is_op("="):
                    tokens.pos += 1
                    default = self.parse_expression(tokens)
                params.append((param, default))
                if tokens.is_op(","):
                    tokens.pos += 1
                    continue
                break
        tokens.expect_op(")")
        tokens.expect_end()
        body, term = self._body_until(frozenset({"endmacro"}))
        term.next()
        term.expect_end()
        return n.MacroDef(name, params, body)

    def stmt_include(self, tokens: _Tokens, top_level: bool) -> n.Include:
        expr = self.parse_expression(tokens)
        tokens.expect_end()
        return n.Include(expr)

    def stmt_extends(self, tokens: _Tokens, top_level: bool) -> n.Extends:
        if not top_level or self.seen_extends:
            raise TemplateSyntaxError("misplaced or repeated 'extends'")
        self.seen_extends = True
        expr = self.parse_expression(tokens)
        tokens.expect_end()
        return n.Extends(expr)

    def stmt_block(self, tokens: _Tokens, top_level: bool) -> n.Block:
        name = tokens.expect_name()
        tokens.expect_end()
        if name in self.blocks:
            raise TemplateSyntaxError(f"duplicate block {name!r}")
        block = n.Block(name, [])
        self.blocks[name] = block
        block.body, term = self._body_until(frozenset({"endblock"}))
        term.next()
        if not term.at_end():
            if term.expect_name() != name:
                raise TemplateSyntaxError("mismatched endblock name")
            term.expect_end()
        return block

    # -- expressions -------------------------------------------------------

    def parse_expression(self, t: _Tokens):
        return self._or(t)

    def _or(self, t: _Tokens):
        left = self._and(t)
        while t.is_name("or"):
            t.pos += 1
            left = n.BoolOp("or", left, self._and(t))
        return left

    def _and(self, t: _Tokens):
        left = self._not(t)
        while t.is_name("and"):
            t.pos += 1
            left = n.BoolOp("and", left, self._not(t))
        return left

    def _not(self, t: _Tokens):
        if t.is_name("not"):
            t.pos += 1
            return n.Not(self._not(t))
        return self._compare(t)

    def _compare(self, t: _Tokens):
        first = self._additive(t)
        rest = []
        while True:
            token = t.peek()
            if token is None:
                break
            kind, value = token
            if kind == OP and value in _COMPARE_OPS:
                t.pos += 1
                op = value
            elif kind == NAME and value == "in":
                t.pos += 1
                op = "in"
            elif kind == NAME and value == "not" and t.is_name("in", 1):
                t.pos += 2
                op = "not in"
            else:
                break
            rest.append((op, self._additive(t)))
        return n.Compare(first, rest) if rest else first

    def _additive(self, t: _Tokens):
        left = self._concat(t)
        while t.is_op("+") or t.is_op("-"):
            op = t.next()[1]
            left = n.BinOp(op, left, self._concat(t))
        return left

    def _concat(self, t: _Tokens):
        left = self._term(t)
        while t.is_op("~"):
            t.pos += 1
            left = n.BinOp("~", left, self._term(t))
        return left

    def _term(self, t: _Tokens):
        left = self._power(t)
        while t.is_op("*") or t.is_op("/") or t.is_op("//") or t.is_op("%"):
            op = t.next()[1]
            left = n.BinOp(op, left, self._power(t))
        return left

    def _power(self, t: _Tokens):
        left = self._filtered(t)
        while t.is_op("**"):
            t.pos += 1
            left = n.BinOp("**", left, self._filtered(t))
        return left

    def _filtered(self, t: _Tokens):
        node = self._unary(t)
        while True:
            if t.is_op("|"):
                t.pos += 1
                name = t.expect_name()
                args = []
                if t.is_op("("):
                    t.pos += 1
                    args = self._expression_list(t, ")")
                self.filters.add(name)
                node = n.FilterCall(node, name, args)
            elif t.is_name("is"):
                t.pos += 1
                negated = False
                if t.is_name("not"):
                    t.pos += 1
                    negated = True
                if not t.is_name("defined"):
                    raise TemplateSyntaxError("only the 'defined' test exists")
                t.pos += 1
                node = n.IsDefined(node, negated)
            else:
                return node

    def _unary(self, t: _Tokens):
        if t.is_op("-"):
            t.pos += 1
            return n.Neg(self._unary(t))
        return self._postfix(t)

    def _postfix(self, t: _Tokens):
        node = self._primary(t)
        while True:
            if t.is_op("."):
                t.pos += 1
                node = n.GetItem(node, n.Const(t.expect_name()))
            elif t.is_op("["):
                t.pos += 1
                key = self.parse_expression(t)
                t.expect_op("]")
                node = n.GetItem(node, key)
            elif t.is_op("("):
                t.pos += 1
                node = self._call(t, node)
            else:
                return node

    def _call(self, t: _Tokens, func):
        args: list = []
        kwargs: list = []
        if t.is_op(")"):
            t.pos += 1
            return n.Call(func, args, kwargs)
        while True:
            token = t.peek()
            if token is not None and token[0] == NAME and t.is_op("=", 1):
                name = token[1]
                t.pos += 2
                if any(name == existing for existing, _ in kwargs):
                    raise TemplateSyntaxError(f"repeated keyword argument {name!r}")
                kwargs.append((name, self.parse_expression(t)))
            else:
                if kwargs:
                    raise TemplateSyntaxError("positional argument after keyword argument")
                args.append(self.parse_expression(t))
            if t.is_op(","):
                t.pos += 1
                continue
            t.expect_op(")")
            return n.Call(func, args, kwargs)

    def _expression_list(self, t: _Tokens, closer: str) -> list:
        items: list = []
        if t.is_op(closer):
            t.pos += 1
            return items
        while True:
            items.append(self.parse_expression(t))
            if t.is_op(","):
                t.pos += 1
                continue
            t.expect_op(closer)
            return items

    def _primary(self, t: _Tokens):
        kind, value = t.next()
        if kind == INT or kind == FLOAT or kind == STRING:
            return n.Const(value)
        if kind == NAME:
            if value == "true":
                return n.Const(True)
            if value == "false":
                return n.Const(False)
            if value == "none":
                return n.Const(None)
            if value in KEYWORDS:
                raise TemplateSyntaxError(f"unexpected keyword {value!r}")
            return n.Name(value)
        if kind == OP:
            if value == "[":
                return n.ListLit(self._expression_list(t, "]"))
            if value == "(":
                expr = self.parse_expression(t)
                t.expect_op(")")
                return expr
        raise TemplateSyntaxError(f"unexpected token {value!r}")
