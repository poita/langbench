"""The KBL parser: logical lines to syntax trees.

Entry point: :func:`parse_file`.  It lexes the whole file first (so lexical
errors take precedence), then parses logical lines in order, reporting the
first grammar error, and finally reports an unterminated block.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import nodes as N
from .errors import KilnError, SyntaxFault
from .lexer import RESERVED, Token, lex_file, skip_region, tokenize

__all__ = ["parse_file", "parse_expression"]

_BINARY_LEVELS: tuple[tuple[str, ...], ...] = (
    ("||",),
    ("&&",),
    ("==", "!=", "<", "<=", ">", ">="),
    ("++",),
    ("~",),
    ("+", "-"),
    ("*", "/", "%"),
)

_FIELD_KEYWORDS = frozenset({b"out", b"in", b"after", b"cost", b"depfile", b"cmd"})
_ESCAPES = {
    0x5C: b"\\", 0x22: b'"', 0x6E: b"\n", 0x74: b"\t", 0x72: b"\r", 0x30: b"\x00",
}


class _TokenParser:
    """Recursive-descent expression parser over one token list."""

    __slots__ = ("toks", "pos")

    def __init__(self, toks: list[Token], pos: int = 0) -> None:
        self.toks = toks
        self.pos = pos

    # -- token helpers --
    def peek(self, offset: int = 0) -> Token | None:
        i = self.pos + offset
        return self.toks[i] if i < len(self.toks) else None

    def at(self, kind: str) -> bool:
        t = self.peek()
        return t is not None and t[0] == kind

    def expect(self, kind: str) -> Token:
        t = self.peek()
        if t is None or t[0] != kind:
            raise SyntaxFault(f"expected {kind}")
        self.pos += 1
        return t

    def ident(self) -> bytes:
        """An identifier that is not a reserved word."""
        t = self.expect("ID")
        if t[1] in RESERVED:
            raise SyntaxFault("reserved word")
        return t[1]

    def at_end(self) -> bool:
        return self.pos >= len(self.toks)

    def require_end(self) -> None:
        if not self.at_end():
            raise SyntaxFault("trailing tokens")

    # -- expressions --
    def expr(self) -> N.Expr:
        left = self._binary(0)
        while self.at("|>"):
            self.pos += 1
            name = self.expect("ID")[1]
            args: tuple = ()
            if self.at("("):
                self.pos += 1
                args = self._call_args()
            left = N.Call(name, (left,) + args)
        return left

    def _binary(self, level: int) -> N.Expr:
        if level == len(_BINARY_LEVELS):
            return self._unary()
        ops = _BINARY_LEVELS[level]
        left = self._binary(level + 1)
        while True:
            t = self.peek()
            if t is None or t[0] not in ops:
                return left
            self.pos += 1
            right = self._binary(level + 1)
            left = N.Binary(t[0], left, right)

    def _unary(self) -> N.Expr:
        t = self.peek()
        if t is not None and (t[0] == "!" or t[0] == "-"):
            self.pos += 1
            return N.Unary(t[0], self._unary())
        return self._postfix()

    def _postfix(self) -> N.Expr:
        node = self._primary()
        while True:
            t = self.peek()
            if t is None:
                return node
            if t[0] == "[":
                self.pos += 1
                index = self.expr()
                self.expect("]")
                node = N.Index(node, index)
            elif t[0] == "(":
                raise SyntaxFault("call of a non-identifier")
            else:
                return node

    def _primary(self) -> N.Expr:
        t = self.peek()
        if t is None:
            raise SyntaxFault("expected expression")
        kind, value = t
        self.pos += 1
        if kind == "INT":
            return N.Lit(value)
        if kind == "STR":
            return parse_string_literal(value)
        if kind == "ID":
            nxt = self.peek()
            if nxt is not None and nxt[0] == "(":
                self.pos += 1
                return N.Call(value, self._call_args())
            if value == b"true":
                return N.Lit(True)
            if value == b"false":
                return N.Lit(False)
            if value in RESERVED:
                raise SyntaxFault("reserved word as variable")
            return N.Var(value)
        if kind == "(":
            e = self.expr()
            self.expect(")")
            return e
        if kind == "[":
            items: list[N.Expr] = []
            if self.at("]"):
                self.pos += 1
                return N.ListLit(())
            while True:
                items.append(self.expr())
                if self.at(","):
                    self.pos += 1
                    if self.at("]"):
                        self.pos += 1
                        break
                    continue
                self.expect("]")
                break
            return N.ListLit(tuple(items))
        raise SyntaxFault("unexpected token")

    def _call_args(self) -> tuple:
        """Parse ``expr, expr, ...`` up to and including the closing ``)``."""
        args: list[N.Expr] = []
        if self.at(")"):
            self.pos += 1
            return ()
        while True:
            args.append(self.expr())
            if self.at(","):
                self.pos += 1
                if self.at(")"):
                    self.pos += 1
                    break
                continue
            self.expect(")")
            break
        return tuple(args)


def parse_expression(toks: list[Token]) -> N.Expr:
    """Parse a complete expression from ``toks`` (all tokens must be consumed)."""
    p = _TokenParser(toks)
    e = p.expr()
    p.require_end()
    return e


# ---- string literals --------------------------------------------------------

def parse_string_literal(raw: bytes) -> N.Expr:
    """Decode a raw string token (including its quotes)."""
    if raw[0] == 0x27:
        return N.Lit(raw[1:-1].replace(b"''", b"'"))
    body = raw[1:-1]
    n = len(body)
    parts: list[object] = []
    buf = bytearray()
    i = 0
    while i < n:
        c = body[i]
        if c == 0x5C:
            if i + 1 >= n:
                raise SyntaxFault("bad escape")
            esc = _ESCAPES.get(body[i + 1])
            if esc is None:
                raise SyntaxFault("bad escape")
            buf += esc
            i += 2
        elif c == 0x7B:
            if i + 1 < n and body[i + 1] == 0x7B:
                buf.append(0x7B)
                i += 2
                continue
            end = skip_region(body, i + 1)
            if end < 0:
                raise SyntaxFault("unterminated interpolation")
            inner = body[i + 1:end - 1]
            toks = tokenize(inner)
            if not toks:
                raise SyntaxFault("empty interpolation")
            if buf:
                parts.append(bytes(buf))
                buf = bytearray()
            parts.append(parse_expression(toks))
            i = end
        elif c == 0x7D:
            if i + 1 < n and body[i + 1] == 0x7D:
                buf.append(0x7D)
                i += 2
            else:
                raise SyntaxFault("lone }")
        else:
            buf.append(c)
            i += 1
    if not parts:
        return N.Lit(bytes(buf))
    if buf:
        parts.append(bytes(buf))
    return N.Interp(tuple(parts))


# ---- statements ---------------------------------------------------------------

@dataclass
class _Frame:
    kind: str                       # "root" | "when" | "each" | "rule" | "step"
    line: int
    body: list = field(default_factory=list)
    # when: finished branches, current condition, whether ``otherwise`` was seen
    branches: list = field(default_factory=list)
    cond: N.Expr | None = None
    otherwise: bool = False
    # each / rule
    data: tuple = ()


def _is_id(tok: Token, word: bytes) -> bool:
    return tok[0] == "ID" and tok[1] == word


def parse_file(path: bytes, source: bytes) -> tuple:
    """Parse a build file into a tuple of statement nodes.

    Raises ``E_PARSE <path>:<line>`` for the single reported syntax error.
    """
    lines = lex_file(path, source)
    stack = [_Frame("root", 0)]
    for lineno, toks in lines:
        try:
            _handle_line(stack, toks, lineno)
        except SyntaxFault:
            raise KilnError("E_PARSE", b"%b:%d" % (path, lineno)) from None
        except RecursionError:
            raise KilnError("E_PARSE", b"%b:%d" % (path, lineno)) from None
    if len(stack) > 1:
        raise KilnError("E_PARSE", b"%b:%d" % (path, stack[-1].line))
    return tuple(stack[0].body)


def _handle_line(stack: list[_Frame], toks: list[Token], lineno: int) -> None:
    first = toks[0]
    last = toks[-1]
    if first[0] == "}":
        _terminator(stack, toks, lineno)
    elif last[0] == "{":
        _header(stack, toks, lineno)
    else:
        _simple(stack, toks)


def _terminator(stack: list[_Frame], toks: list[Token], lineno: int) -> None:
    frame = stack[-1]
    if frame.kind == "root":
        raise SyntaxFault("unmatched }")
    if len(toks) == 1:
        stack.pop()
        stack[-1].body.append(_close(frame))
        return
    second = toks[1]
    if frame.kind != "when" or frame.otherwise or second[0] != "ID" or toks[-1][0] != "{":
        raise SyntaxFault("bad terminator")
    if second[1] == b"elsewhen":
        cond = parse_expression(toks[2:-1])
        frame.branches.append((frame.cond, tuple(frame.body)))
        frame.cond = cond
        frame.body = []
        frame.line = lineno
    elif second[1] == b"otherwise" and len(toks) == 3:
        frame.branches.append((frame.cond, tuple(frame.body)))
        frame.cond = None
        frame.otherwise = True
        frame.body = []
        frame.line = lineno
    else:
        raise SyntaxFault("bad terminator")


def _close(frame: _Frame):
    body = tuple(frame.body)
    if frame.kind == "when":
        return N.When(tuple(frame.branches) + ((frame.cond, body),))
    if frame.kind == "each":
        index_name, name, subject = frame.data
        return N.Each(index_name, name, subject, body)
    if frame.kind == "rule":
        name, params = frame.data
        return N.RuleDef(name, params, body)
    return N.StepBlock(body)  # step


def _header(stack: list[_Frame], toks: list[Token], lineno: int) -> None:
    if stack[-1].kind == "step":
        raise SyntaxFault("block inside step")
    head = toks[0]
    inner = toks[:-1]
    if len(inner) == 1 and _is_id(head, b"step"):
        stack.append(_Frame("step", lineno))
    elif _is_id(head, b"when"):
        frame = _Frame("when", lineno)
        frame.cond = parse_expression(inner[1:])
        stack.append(frame)
    elif _is_id(head, b"each"):
        p = _TokenParser(inner, 1)
        first = p.ident()
        second = None
        if p.at(","):
            p.pos += 1
            second = p.ident()
        if not (p.peek() is not None and _is_id(p.peek(), b"in")):
            raise SyntaxFault("expected in")
        p.pos += 1
        subject = parse_expression(inner[p.pos:])
        if second is None:
            data = (None, first, subject)
        else:
            if first == second:
                raise SyntaxFault("duplicate loop variable")
            data = (first, second, subject)
        frame = _Frame("each", lineno)
        frame.data = data
        stack.append(frame)
    elif _is_id(head, b"rule"):
        p = _TokenParser(inner, 1)
        name = p.ident()
        p.expect("(")
        params = _params(p)
        p.require_end()
        frame = _Frame("rule", lineno)
        frame.data = (name, params)
        stack.append(frame)
    else:
        raise SyntaxFault("bad block header")


def _params(p: _TokenParser) -> tuple:
    """Parse a rule parameter list up to and including the closing ``)``."""
    params: list[N.Param] = []
    seen: set[bytes] = set()
    defaulted = False
    if p.at(")"):
        p.pos += 1
        return ()
    while True:
        name = p.ident()
        if name in seen:
            raise SyntaxFault("duplicate parameter")
        seen.add(name)
        default = None
        if p.at("="):
            p.pos += 1
            default = p.expr()
            defaulted = True
        elif defaulted:
            raise SyntaxFault("parameter without default after one with")
        params.append(N.Param(name, default))
        if p.at(","):
            p.pos += 1
            if p.at(")"):
                p.pos += 1
                break
            continue
        p.expect(")")
        break
    return tuple(params)


def _simple(stack: list[_Frame], toks: list[Token]) -> None:
    frame = stack[-1]
    head = toks[0]
    if head[0] != "ID":
        raise SyntaxFault("statement must start with a keyword")
    word = head[1]
    if frame.kind == "step":
        if word not in _FIELD_KEYWORDS:
            raise SyntaxFault("not a step field")
        frame.body.append(_step_field(word, toks))
        return
    if word in _FIELD_KEYWORDS:
        raise SyntaxFault("step field outside step")
    p = _TokenParser(toks, 1)
    if word == b"let" or word == b"set" or word == b"phony":
        name = p.ident()
        p.expect("=")
        expr = p.expr()
        p.require_end()
        node = N.Let(name, expr) if word == b"let" else N.Set(name, expr) if word == b"set" else N.Phony(name, expr)
    elif word == b"include":
        node = N.Include(_rest_expr(p))
    elif word == b"abort":
        node = N.Abort(_rest_expr(p))
    elif word == b"default":
        node = N.Default(_rest_expr(p))
    elif word == b"use":
        name = p.expect("ID")[1]
        p.expect("(")
        args, kwargs = _use_args(p)
        p.require_end()
        node = N.Use(name, args, kwargs)
    else:
        raise SyntaxFault("unknown statement")
    frame.body.append(node)


def _rest_expr(p: _TokenParser) -> N.Expr:
    e = p.expr()
    p.require_end()
    return e


def _use_args(p: _TokenParser) -> tuple[tuple, tuple]:
    args: list[N.Expr] = []
    kwargs: list[tuple[bytes, N.Expr]] = []
    if p.at(")"):
        p.pos += 1
        return (), ()
    while True:
        t, nxt = p.peek(), p.peek(1)
        if t is not None and t[0] == "ID" and t[1] not in RESERVED and nxt is not None and nxt[0] == "=":
            p.pos += 2
            kwargs.append((t[1], p.expr()))
        else:
            if kwargs:
                raise SyntaxFault("positional after keyword")
            args.append(p.expr())
        if p.at(","):
            p.pos += 1
            if p.at(")"):
                p.pos += 1
                break
            continue
        p.expect(")")
        break
    return tuple(args), tuple(kwargs)


def _step_field(word: bytes, toks: list[Token]):
    p = _TokenParser(toks, 1)
    if word == b"cmd":
        name = p.expect("ID")[1]
        p.expect("(")
        args = p._call_args()
        p.require_end()
        return N.CmdField(name, args)
    return N.StepField(word, _rest_expr(p))
