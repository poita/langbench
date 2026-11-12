"""KBL parser: logical lines -> syntax tree.

The entry point is :func:`parse_file`.  Lexical errors are raised first (by
:func:`kiln.lexer.logical_lines`), then the first grammar error in file order,
then an unterminated block, exactly as the specification orders them.
"""

from __future__ import annotations

from . import nodes as n
from .errors import SyntaxFail, parse_error
from .lexer import RESERVED, LogicalLine, Token, logical_lines, skip_interpolation, tokenize

_ESCAPES = {
    0x5C: b"\\",
    0x22: b'"',
    0x6E: b"\n",
    0x74: b"\t",
    0x72: b"\r",
    0x30: b"\0",
}

_BINARY_LEVELS: list[frozenset[bytes]] = [
    frozenset([b"||"]),
    frozenset([b"&&"]),
    frozenset([b"==", b"!=", b"<", b"<=", b">", b">="]),
    frozenset([b"++"]),
    frozenset([b"~"]),
    frozenset([b"+", b"-"]),
    frozenset([b"*", b"/", b"%"]),
]

STEP_FIELDS = frozenset([b"out", b"in", b"after", b"cost", b"depfile", b"cmd"])


def _op(tok: Token | None, text: bytes) -> bool:
    return tok is not None and tok[0] == "op" and tok[1] == text


def _is_name(tok: Token | None) -> bool:
    """An identifier that is not a reserved word."""
    return tok is not None and tok[0] == "id" and tok[1] not in RESERVED


# -- string literals -------------------------------------------------------------


def parse_string(raw: bytes) -> n.Literal | n.Interp:
    """Decode a string token (quotes included) into a literal or interpolation."""
    body = raw[1:-1]
    if raw[0] == 0x27:
        return n.Literal(body.replace(b"''", b"'"))
    parts: list[bytes | n.Expr] = []
    buf = bytearray()
    i = 0
    size = len(body)
    while i < size:
        c = body[i]
        if c == 0x5C:
            esc = _ESCAPES.get(body[i + 1]) if i + 1 < size else None
            if esc is None:
                raise SyntaxFail("bad escape")
            buf += esc
            i += 2
        elif c == 0x7B:
            if i + 1 < size and body[i + 1] == 0x7B:
                buf.append(0x7B)
                i += 2
                continue
            end = skip_interpolation(body, i + 1)
            tokens = tokenize(body[i + 1 : end - 1])
            if not tokens:
                raise SyntaxFail("empty interpolation")
            if buf:
                parts.append(bytes(buf))
                buf.clear()
            parts.append(ExprParser(tokens).parse_complete())
            i = end
        elif c == 0x7D:
            if i + 1 < size and body[i + 1] == 0x7D:
                buf.append(0x7D)
                i += 2
            else:
                raise SyntaxFail("lone }")
        else:
            buf.append(c)
            i += 1
    if not parts:
        return n.Literal(bytes(buf))
    if buf:
        parts.append(bytes(buf))
    return n.Interp(parts)


# -- expressions -----------------------------------------------------------------


class ExprParser:
    """Precedence-climbing parser over a token list."""

    def __init__(self, tokens: list[Token], pos: int = 0) -> None:
        self.toks = tokens
        self.pos = pos

    def peek(self) -> Token | None:
        return self.toks[self.pos] if self.pos < len(self.toks) else None

    def at_end(self) -> bool:
        return self.pos >= len(self.toks)

    def expect_op(self, text: bytes) -> None:
        if not _op(self.peek(), text):
            raise SyntaxFail(f"expected {text!r}")
        self.pos += 1

    def parse_complete(self) -> n.Expr:
        """Parse an expression that must consume every token."""
        e = self.parse_expr()
        if not self.at_end():
            raise SyntaxFail("trailing tokens")
        return e

    def parse_expr(self) -> n.Expr:
        left = self._binary(0)
        while _op(self.peek(), b"|>"):
            self.pos += 1
            tok = self.peek()
            if tok is None or tok[0] != "id":
                raise SyntaxFail("pipe target must be an identifier")
            self.pos += 1
            args: list[n.Expr] = [left]
            if _op(self.peek(), b"("):
                self.pos += 1
                args += self._arg_list()
            left = n.Call(tok[1], args)
        return left

    def _arg_list(self) -> list[n.Expr]:
        """Comma-separated expressions up to and including the closing ``)``."""
        args: list[n.Expr] = []
        if _op(self.peek(), b")"):
            self.pos += 1
            return args
        while True:
            args.append(self.parse_expr())
            if _op(self.peek(), b","):
                self.pos += 1
                if _op(self.peek(), b")"):
                    self.pos += 1
                    return args
                continue
            self.expect_op(b")")
            return args

    def _binary(self, level: int) -> n.Expr:
        if level == len(_BINARY_LEVELS):
            return self._unary()
        ops = _BINARY_LEVELS[level]
        left = self._binary(level + 1)
        while True:
            tok = self.peek()
            if tok is None or tok[0] != "op" or tok[1] not in ops:
                return left
            self.pos += 1
            left = n.Binary(tok[1], left, self._binary(level + 1))

    def _unary(self) -> n.Expr:
        tok = self.peek()
        if tok is not None and tok[0] == "op" and (tok[1] == b"!" or tok[1] == b"-"):
            self.pos += 1
            return n.Unary(tok[1], self._unary())
        return self._postfix()

    def _postfix(self) -> n.Expr:
        e = self._primary()
        while _op(self.peek(), b"["):
            self.pos += 1
            idx = self.parse_expr()
            self.expect_op(b"]")
            e = n.Index(e, idx)
        return e

    def _primary(self) -> n.Expr:
        tok = self.peek()
        if tok is None:
            raise SyntaxFail("unexpected end of line")
        kind, text = tok
        self.pos += 1
        if kind == "int":
            return n.Literal(int(text))
        if kind == "str":
            return parse_string(text)
        if kind == "id":
            if _op(self.peek(), b"("):
                self.pos += 1
                return n.Call(text, self._arg_list())
            if text == b"true":
                return n.Literal(True)
            if text == b"false":
                return n.Literal(False)
            if text in RESERVED:
                raise SyntaxFail("reserved word")
            return n.Var(text)
        if text == b"(":
            e = self.parse_expr()
            self.expect_op(b")")
            return e
        if text == b"[":
            items: list[n.Expr] = []
            if _op(self.peek(), b"]"):
                self.pos += 1
                return n.ListExpr(items)
            while True:
                items.append(self.parse_expr())
                if _op(self.peek(), b","):
                    self.pos += 1
                    if _op(self.peek(), b"]"):
                        self.pos += 1
                        return n.ListExpr(items)
                    continue
                self.expect_op(b"]")
                return n.ListExpr(items)
        raise SyntaxFail("unexpected token")


def _expr_from(tokens: list[Token], start: int, stop: int | None = None) -> n.Expr:
    """Parse ``tokens[start:stop]`` as one complete expression."""
    return ExprParser(tokens[start:stop]).parse_complete()


# -- statements --------------------------------------------------------------------


def _paren_args(p: ExprParser) -> list[tuple[bytes | None, n.Expr]]:
    """``use`` argument list after the opening parenthesis, through ``)``."""
    args: list[tuple[bytes | None, n.Expr]] = []
    seen_keyword = False
    if _op(p.peek(), b")"):
        p.pos += 1
        return args
    while True:
        tok = p.peek()
        nxt = p.toks[p.pos + 1] if p.pos + 1 < len(p.toks) else None
        if _is_name(tok) and _op(nxt, b"="):
            p.pos += 2
            args.append((tok[1], p.parse_expr()))  # type: ignore[index]
            seen_keyword = True
        else:
            if seen_keyword:
                raise SyntaxFail("positional after keyword")
            args.append((None, p.parse_expr()))
        if _op(p.peek(), b","):
            p.pos += 1
            if _op(p.peek(), b")"):
                p.pos += 1
                return args
            continue
        p.expect_op(b")")
        return args


def _name_at(tokens: list[Token], i: int) -> bytes:
    tok = tokens[i] if i < len(tokens) else None
    if not _is_name(tok):
        raise SyntaxFail("expected a name")
    return tok[1]  # type: ignore[index]


def _parse_simple(tokens: list[Token]) -> n.Stmt:
    kind, word = tokens[0]
    if kind != "id":
        raise SyntaxFail("not a statement")
    if word == b"let" or word == b"set":
        name = _name_at(tokens, 1)
        if not _op(tokens[2] if len(tokens) > 2 else None, b"="):
            raise SyntaxFail("expected =")
        expr = _expr_from(tokens, 3)
        return n.Let(name, expr) if word == b"let" else n.Set(name, expr)
    if word == b"include":
        return n.Include(_expr_from(tokens, 1))
    if word == b"abort":
        return n.Abort(_expr_from(tokens, 1))
    if word == b"default":
        return n.Default(_expr_from(tokens, 1))
    if word == b"phony":
        name = _name_at(tokens, 1)
        if not _op(tokens[2] if len(tokens) > 2 else None, b"="):
            raise SyntaxFail("expected =")
        return n.Phony(name, _expr_from(tokens, 3))
    if word == b"use":
        if len(tokens) < 3 or tokens[1][0] != "id" or not _op(tokens[2], b"("):
            raise SyntaxFail("bad use")
        p = ExprParser(tokens, 3)
        args = _paren_args(p)
        if not p.at_end():
            raise SyntaxFail("trailing tokens")
        return n.Use(tokens[1][1], args)
    raise SyntaxFail("not a statement")


def _parse_step_field(tokens: list[Token]) -> n.StepField:
    kind, word = tokens[0]
    if kind != "id" or word not in STEP_FIELDS:
        raise SyntaxFail("not a step field")
    if word == b"cmd":
        if len(tokens) < 3 or tokens[1][0] != "id" or not _op(tokens[2], b"("):
            raise SyntaxFail("bad cmd")
        p = ExprParser(tokens, 3)
        args = p._arg_list()
        if not p.at_end():
            raise SyntaxFail("trailing tokens")
        return n.StepField("cmd", None, tokens[1][1], args)
    return n.StepField(word.decode(), _expr_from(tokens, 1))


class _Frame:
    """An open block while parsing."""

    __slots__ = ("kind", "line", "body", "branches", "cond", "in_otherwise", "info")

    def __init__(self, kind: str, line: int, info: object = None) -> None:
        self.kind = kind
        self.line = line
        self.body: list = []
        self.branches: list[tuple[n.Expr, list]] = []
        self.cond: n.Expr | None = None
        self.in_otherwise = False
        self.info = info


def _parse_header(tokens: list[Token], lineno: int) -> _Frame:
    """Parse a block header (a line whose last token is ``{``)."""
    head = tokens[:-1]
    if not head or head[0][0] != "id":
        raise SyntaxFail("bad block header")
    word = head[0][1]
    if word == b"step":
        if len(head) != 1:
            raise SyntaxFail("bad step header")
        return _Frame("step", lineno)
    if word == b"when":
        frame = _Frame("when", lineno)
        frame.cond = _expr_from(head, 1)
        return frame
    if word == b"each":
        first = _name_at(head, 1)
        pos = 2
        index_name = None
        if _op(head[pos] if pos < len(head) else None, b","):
            index_name, first = first, _name_at(head, 3)
            pos = 4
            if index_name == first:
                raise SyntaxFail("duplicate loop variable")
        tok = head[pos] if pos < len(head) else None
        if tok != ("id", b"in"):
            raise SyntaxFail("expected in")
        return _Frame("each", lineno, (index_name, first, _expr_from(head, pos + 1)))
    if word == b"rule":
        name = _name_at(head, 1)
        if not _op(head[2] if len(head) > 2 else None, b"("):
            raise SyntaxFail("expected (")
        p = ExprParser(head, 3)
        params: list[n.Param] = []
        seen: set[bytes] = set()
        defaulted = False
        if _op(p.peek(), b")"):
            p.pos += 1
        else:
            while True:
                pname = _name_at(head, p.pos)
                p.pos += 1
                if pname in seen:
                    raise SyntaxFail("duplicate parameter")
                seen.add(pname)
                default = None
                if _op(p.peek(), b"="):
                    p.pos += 1
                    default = p.parse_expr()
                    defaulted = True
                elif defaulted:
                    raise SyntaxFail("parameter without default after one with")
                params.append(n.Param(pname, default))
                if _op(p.peek(), b","):
                    p.pos += 1
                    if _op(p.peek(), b")"):
                        p.pos += 1
                        break
                    continue
                p.expect_op(b")")
                break
        if not p.at_end():
            raise SyntaxFail("trailing tokens")
        return _Frame("rule", lineno, (name, params))
    raise SyntaxFail("bad block header")


def _close(stack: list[_Frame]) -> None:
    frame = stack.pop()
    parent = stack[-1]
    kind = frame.kind
    node: n.Stmt
    if kind == "step":
        node = n.Step(frame.body)
    elif kind == "when":
        if frame.in_otherwise:
            node = n.When(frame.branches, frame.body)
        else:
            frame.branches.append((frame.cond, frame.body))  # type: ignore[arg-type]
            node = n.When(frame.branches, None)
    elif kind == "each":
        index_name, name, subject = frame.info  # type: ignore[misc]
        node = n.Each(index_name, name, subject, frame.body)
    else:
        name, params = frame.info  # type: ignore[misc]
        node = n.Rule(name, params, frame.body)
    parent.body.append(node)


def _terminator(stack: list[_Frame], tokens: list[Token], lineno: int) -> None:
    top = stack[-1]
    if top.kind == "root":
        raise SyntaxFail("unmatched }")
    if len(tokens) == 1:
        _close(stack)
        return
    if top.kind != "when" or top.in_otherwise or not _op(tokens[-1], b"{"):
        raise SyntaxFail("bad terminator")
    if tokens[1] == ("id", b"elsewhen") and len(tokens) > 3:
        cond = _expr_from(tokens, 2, -1)
        top.branches.append((top.cond, top.body))  # type: ignore[arg-type]
        top.cond = cond
        top.body = []
        top.line = lineno
    elif tokens[1] == ("id", b"otherwise") and len(tokens) == 3:
        top.branches.append((top.cond, top.body))  # type: ignore[arg-type]
        top.cond = None
        top.body = []
        top.in_otherwise = True
        top.line = lineno
    else:
        raise SyntaxFail("bad terminator")


def _parse_line(stack: list[_Frame], tokens: list[Token], lineno: int) -> None:
    top = stack[-1]
    if _op(tokens[0], b"}"):
        _terminator(stack, tokens, lineno)
    elif _op(tokens[-1], b"{"):
        if top.kind == "step":
            raise SyntaxFail("block inside step")
        stack.append(_parse_header(tokens, lineno))
    elif top.kind == "step":
        top.body.append(_parse_step_field(tokens))
    else:
        top.body.append(_parse_simple(tokens))


def parse_lines(path: bytes, lines: list[LogicalLine]) -> list[n.Stmt]:
    """Parse already-lexed logical lines into statements."""
    root = _Frame("root", 0)
    stack = [root]
    for lineno, tokens in lines:
        try:
            _parse_line(stack, tokens, lineno)
        except SyntaxFail:
            raise parse_error(path, lineno) from None
    if len(stack) > 1:
        raise parse_error(path, stack[-1].line)
    return root.body


def parse_file(path: bytes, source: bytes) -> list[n.Stmt]:
    """Lex and parse a build file; raises ``KilnError`` (``E_PARSE``)."""
    return parse_lines(path, logical_lines(path, source))


__all__ = ["ExprParser", "STEP_FIELDS", "parse_file", "parse_lines", "parse_string"]
