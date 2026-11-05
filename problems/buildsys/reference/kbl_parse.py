"""KBL parser: expression parsing by precedence climbing, string-literal
reading with interpolation, and line-classified statement and block parsing."""
from kiln_err import parse_error
from kbl_lex import (RESERVED, Token, tokenize, skip_literal, LexFail,
                     DQUOTE, SQUOTE, BACKSLASH, LBRACE, RBRACE)
from kbl_ast import (EInt, EBool, EStr, EVar, EList, ECall, EIndex, EUnary,
                     EBinary, SLet, SSet, SInclude, SAbort, SDefault, SPhony,
                     SUse, SWhen, SEach, SRule, SStep)

MASK64 = (1 << 64) - 1

CMP_OPS = (b"==", b"!=", b"<", b"<=", b">", b">=")
ESCAPES = {
    BACKSLASH: b"\\",
    DQUOTE: b'"',
    0x6E: b"\n",
    0x74: b"\t",
    0x72: b"\r",
    0x30: b"\x00",
}


def wrap64(n):
    n &= MASK64
    if n >= 1 << 63:
        n -= 1 << 64
    return n


class ExprParser(object):
    """A cursor over one logical line's tokens."""

    def __init__(self, toks, filename, lineno):
        self.toks = toks
        self.pos = 0
        self.fn = filename
        self.line = lineno

    def fail(self):
        raise parse_error(self.fn, self.line)

    def at_end(self):
        return self.pos >= len(self.toks)

    def peek(self):
        if self.pos < len(self.toks):
            return self.toks[self.pos]
        return None

    def peek2(self):
        if self.pos + 1 < len(self.toks):
            return self.toks[self.pos + 1]
        return None

    def take(self):
        if self.pos >= len(self.toks):
            self.fail()
        t = self.toks[self.pos]
        self.pos += 1
        return t

    def advance(self):
        self.pos += 1

    def expect_punct(self, s):
        t = self.peek()
        if t is None or not t.is_punct(s):
            self.fail()
        self.pos += 1

    def expect_end(self):
        if not self.at_end():
            self.fail()

    def expect_name(self, allow_reserved=False):
        t = self.take()
        if t.kind != "ident":
            self.fail()
        if not allow_reserved and t.text in RESERVED:
            self.fail()
        return t.text

    # ---- expressions ----

    def parse_expr(self):
        return self.parse_pipe()

    def parse_pipe(self):
        e = self.parse_or()
        while True:
            t = self.peek()
            if t is None or not t.is_op(b"|>"):
                return e
            self.advance()
            nt = self.take()
            if nt.kind != "ident":
                self.fail()
            args = [e]
            p = self.peek()
            if p is not None and p.is_punct(b"("):
                args.extend(self.parse_call_args())
            e = ECall(nt.text, args)

    def parse_or(self):
        e = self.parse_and()
        while True:
            t = self.peek()
            if t is None or not t.is_op(b"||"):
                return e
            self.advance()
            e = EBinary(b"||", e, self.parse_and())

    def parse_and(self):
        e = self.parse_cmp()
        while True:
            t = self.peek()
            if t is None or not t.is_op(b"&&"):
                return e
            self.advance()
            e = EBinary(b"&&", e, self.parse_cmp())

    def parse_cmp(self):
        e = self.parse_cat()
        while True:
            t = self.peek()
            if t is None or t.kind != "op" or t.text not in CMP_OPS:
                return e
            op = t.text
            self.advance()
            e = EBinary(op, e, self.parse_cat())

    def parse_cat(self):
        e = self.parse_strcat()
        while True:
            t = self.peek()
            if t is None or not t.is_op(b"++"):
                return e
            self.advance()
            e = EBinary(b"++", e, self.parse_strcat())

    def parse_strcat(self):
        e = self.parse_add()
        while True:
            t = self.peek()
            if t is None or not t.is_op(b"~"):
                return e
            self.advance()
            e = EBinary(b"~", e, self.parse_add())

    def parse_add(self):
        e = self.parse_mul()
        while True:
            t = self.peek()
            if t is None or t.kind != "op" or t.text not in (b"+", b"-"):
                return e
            op = t.text
            self.advance()
            e = EBinary(op, e, self.parse_mul())

    def parse_mul(self):
        e = self.parse_unary()
        while True:
            t = self.peek()
            if t is None or t.kind != "op" or t.text not in (b"*", b"/", b"%"):
                return e
            op = t.text
            self.advance()
            e = EBinary(op, e, self.parse_unary())

    def parse_unary(self):
        t = self.peek()
        if t is not None and t.kind == "op" and t.text in (b"!", b"-"):
            self.advance()
            return EUnary(t.text, self.parse_unary())
        return self.parse_postfix()

    def parse_postfix(self):
        t = self.peek()
        if t is None:
            self.fail()
        e = None
        if t.kind == "ident":
            nxt = self.peek2()
            is_call = nxt is not None and nxt.is_punct(b"(")
            if t.text == b"true" and not is_call:
                self.advance()
                e = EBool(True)
            elif t.text == b"false" and not is_call:
                self.advance()
                e = EBool(False)
            elif is_call:
                # A call names a built-in function, a namespace of its own, so
                # a reserved word here parses and fails later as E_UNKNOWN_FUNC.
                self.advance()
                e = ECall(t.text, self.parse_call_args())
            else:
                if t.text in RESERVED:
                    self.fail()
                self.advance()
                e = EVar(t.text)
        else:
            e = self.parse_primary()
        while True:
            p = self.peek()
            if p is None:
                return e
            if p.is_punct(b"["):
                self.advance()
                idx = self.parse_expr()
                self.expect_punct(b"]")
                e = EIndex(e, idx)
            elif p.is_punct(b"("):
                self.fail()
            else:
                return e

    def parse_primary(self):
        t = self.take()
        if t.kind == "int":
            return EInt(wrap64(int(t.text)))
        if t.kind == "str":
            return parse_string_literal(t.text, self.fn, self.line)
        if t.is_punct(b"("):
            e = self.parse_expr()
            self.expect_punct(b")")
            return e
        if t.is_punct(b"["):
            items = []
            p = self.peek()
            if p is not None and p.is_punct(b"]"):
                self.advance()
                return EList(items)
            while True:
                items.append(self.parse_expr())
                p = self.peek()
                if p is not None and p.is_punct(b","):
                    self.advance()
                    p = self.peek()
                    if p is not None and p.is_punct(b"]"):
                        self.advance()
                        return EList(items)
                    continue
                if p is not None and p.is_punct(b"]"):
                    self.advance()
                    return EList(items)
                self.fail()
        self.fail()

    def parse_call_args(self):
        """Parse ``( expr, expr, ... )`` with an optional trailing comma."""
        self.expect_punct(b"(")
        args = []
        p = self.peek()
        if p is not None and p.is_punct(b")"):
            self.advance()
            return args
        while True:
            args.append(self.parse_expr())
            p = self.peek()
            if p is not None and p.is_punct(b","):
                self.advance()
                p = self.peek()
                if p is not None and p.is_punct(b")"):
                    self.advance()
                    return args
                continue
            if p is not None and p.is_punct(b")"):
                self.advance()
                return args
            self.fail()


def parse_expr_tokens(toks, filename, lineno):
    p = ExprParser(toks, filename, lineno)
    e = p.parse_expr()
    p.expect_end()
    return e


def _find_interp_end(body, i, end, filename, lineno):
    """Return the index of the ``}`` closing an interpolation whose opening
    brace has already been consumed."""
    depth = 1
    while i < end:
        c = body[i]
        if c == DQUOTE or c == SQUOTE:
            try:
                i = skip_literal(body, i, end)
            except LexFail:
                raise parse_error(filename, lineno)
        elif c == LBRACE:
            depth += 1
            i += 1
        elif c == RBRACE:
            depth -= 1
            if depth == 0:
                return i
            i += 1
        else:
            i += 1
    raise parse_error(filename, lineno)


def parse_string_literal(raw, filename, lineno):
    """Turn a raw string token (quotes included) into an ``EStr`` node."""
    if raw[0] == SQUOTE:
        body = raw[1:-1]
        out = bytearray()
        i = 0
        n = len(body)
        while i < n:
            if body[i] == SQUOTE:
                out.append(SQUOTE)
                i += 2
            else:
                out.append(body[i])
                i += 1
        return EStr([("lit", bytes(out))])
    body = raw[1:-1]
    parts = []
    buf = bytearray()
    i = 0
    n = len(body)
    while i < n:
        c = body[i]
        if c == BACKSLASH:
            if i + 1 >= n:
                raise parse_error(filename, lineno)
            e = body[i + 1]
            if e not in ESCAPES:
                raise parse_error(filename, lineno)
            buf += ESCAPES[e]
            i += 2
        elif c == LBRACE:
            if i + 1 < n and body[i + 1] == LBRACE:
                buf.append(LBRACE)
                i += 2
            else:
                j = _find_interp_end(body, i + 1, n, filename, lineno)
                inner = body[i + 1:j]
                if not inner.strip(b" \t"):
                    raise parse_error(filename, lineno)
                if buf:
                    parts.append(("lit", bytes(buf)))
                    buf = bytearray()
                sub = tokenize(inner, filename, lineno)
                parts.append(("expr", parse_expr_tokens(sub, filename, lineno)))
                i = j + 1
        elif c == RBRACE:
            if i + 1 < n and body[i + 1] == RBRACE:
                buf.append(RBRACE)
                i += 2
            else:
                raise parse_error(filename, lineno)
        else:
            buf.append(c)
            i += 1
    if buf:
        parts.append(("lit", bytes(buf)))
    return EStr(parts)


STEP_VALUE_FIELDS = (b"out", b"in", b"after", b"cost", b"depfile")
SIMPLE_KEYWORDS = (b"let", b"set", b"include", b"abort", b"default", b"phony",
                   b"use")


class FileParser(object):
    """Parses a whole build file from its tokenised logical lines."""

    def __init__(self, lines, filename):
        self.lines = lines
        self.i = 0
        self.fn = filename

    def fail(self, line):
        raise parse_error(self.fn, line)

    def parse_file(self):
        stmts, term = self.parse_statements(False)
        if term is not None:
            self.fail(term.line)
        return stmts

    def parse_statements(self, in_step):
        """Parse statements until a block terminator or end of file. Returns
        ``(statements, terminator_line_or_None)`` without consuming the
        terminator."""
        stmts = []
        while True:
            if self.i >= len(self.lines):
                return stmts, None
            ll = self.lines[self.i]
            toks = ll.toks
            if toks[0].is_punct(b"}"):
                return stmts, ll
            self.i += 1
            if toks[-1].is_punct(b"{") and len(toks) > 1:
                if in_step:
                    self.fail(ll.line)
                stmts.append(self.parse_block(ll))
            elif toks[-1].is_punct(b"{"):
                self.fail(ll.line)
            elif in_step:
                stmts.append(self.parse_step_field(ll))
            else:
                stmts.append(self.parse_simple(ll))

    def parse_block(self, ll):
        toks = ll.toks
        head = toks[0]
        if head.kind != "ident":
            self.fail(ll.line)
        if head.text == b"step":
            if len(toks) != 2:
                self.fail(ll.line)
            return self.parse_step_block(ll)
        if head.text == b"when":
            return self.parse_when_block(ll)
        if head.text == b"each":
            return self.parse_each_block(ll)
        if head.text == b"rule":
            return self.parse_rule_block(ll)
        self.fail(ll.line)

    def parse_step_block(self, ll):
        fields, term = self.parse_statements(True)
        if term is None:
            self.fail(ll.line)
        if len(term.toks) != 1:
            self.fail(term.line)
        self.i += 1
        return SStep(fields)

    def parse_when_block(self, ll):
        toks = ll.toks
        cond = parse_expr_tokens(toks[1:-1], self.fn, ll.line)
        branches = []
        body, term = self.parse_statements(False)
        if term is None:
            self.fail(ll.line)
        branches.append((cond, body))
        seen_otherwise = False
        while True:
            t = term.toks
            if len(t) == 1:
                self.i += 1
                return SWhen(branches)
            if not t[-1].is_punct(b"{"):
                self.fail(term.line)
            if t[1].is_word(b"elsewhen"):
                if seen_otherwise:
                    self.fail(term.line)
                cond = parse_expr_tokens(t[2:-1], self.fn, term.line)
                self.i += 1
                body, nxt = self.parse_statements(False)
                if nxt is None:
                    self.fail(term.line)
                branches.append((cond, body))
                term = nxt
            elif t[1].is_word(b"otherwise"):
                if seen_otherwise or len(t) != 3:
                    self.fail(term.line)
                seen_otherwise = True
                self.i += 1
                body, nxt = self.parse_statements(False)
                if nxt is None:
                    self.fail(term.line)
                branches.append((None, body))
                term = nxt
            else:
                self.fail(term.line)

    def parse_each_block(self, ll):
        toks = ll.toks
        p = ExprParser(toks[:-1], self.fn, ll.line)
        p.advance()                       # 'each'
        first = p.expect_name()
        ivar = None
        var = first
        nt = p.peek()
        if nt is not None and nt.is_punct(b","):
            p.advance()
            second = p.expect_name()
            ivar = first
            var = second
            if ivar == var:
                self.fail(ll.line)
        nt = p.peek()
        if nt is None or not nt.is_word(b"in"):
            self.fail(ll.line)
        p.advance()
        expr = p.parse_expr()
        p.expect_end()
        body, term = self.parse_statements(False)
        if term is None:
            self.fail(ll.line)
        if len(term.toks) != 1:
            self.fail(term.line)
        self.i += 1
        return SEach(ivar, var, expr, body)

    def parse_rule_block(self, ll):
        toks = ll.toks
        if len(toks) < 5 or not toks[-2].is_punct(b")"):
            self.fail(ll.line)
        if toks[1].kind != "ident" or toks[1].text in RESERVED:
            self.fail(ll.line)
        name = toks[1].text
        if not toks[2].is_punct(b"("):
            self.fail(ll.line)
        params = self.parse_params(toks[3:-2], ll.line)
        body, term = self.parse_statements(False)
        if term is None:
            self.fail(ll.line)
        if len(term.toks) != 1:
            self.fail(term.line)
        self.i += 1
        return SRule(name, params, body)

    def parse_params(self, toks, line):
        p = ExprParser(toks, self.fn, line)
        params = []
        seen = set()
        seen_default = False
        if p.at_end():
            return params
        while True:
            pname = p.expect_name()
            if pname in seen:
                self.fail(line)
            seen.add(pname)
            default = None
            nt = p.peek()
            if nt is not None and nt.is_punct(b"="):
                p.advance()
                default = p.parse_expr()
                seen_default = True
            elif seen_default:
                self.fail(line)
            params.append((pname, default))
            nt = p.peek()
            if nt is not None and nt.is_punct(b","):
                p.advance()
                if p.at_end():
                    return params
                continue
            if p.at_end():
                return params
            self.fail(line)

    def parse_step_field(self, ll):
        toks = ll.toks
        head = toks[0]
        if head.kind != "ident":
            self.fail(ll.line)
        if head.text in STEP_VALUE_FIELDS:
            if len(toks) < 2:
                self.fail(ll.line)
            expr = parse_expr_tokens(toks[1:], self.fn, ll.line)
            return (head.text, expr)
        if head.text == b"cmd":
            if len(toks) < 4 or toks[1].kind != "ident":
                self.fail(ll.line)
            p = ExprParser(toks[2:], self.fn, ll.line)
            args = p.parse_call_args()
            p.expect_end()
            return (b"cmd", toks[1].text, args)
        self.fail(ll.line)

    def parse_simple(self, ll):
        toks = ll.toks
        head = toks[0]
        if head.kind != "ident":
            self.fail(ll.line)
        kw = head.text
        if kw == b"let" or kw == b"set":
            if len(toks) < 4:
                self.fail(ll.line)
            if toks[1].kind != "ident" or toks[1].text in RESERVED:
                self.fail(ll.line)
            if not toks[2].is_punct(b"="):
                self.fail(ll.line)
            expr = parse_expr_tokens(toks[3:], self.fn, ll.line)
            return SLet(toks[1].text, expr) if kw == b"let" \
                else SSet(toks[1].text, expr)
        if kw == b"phony":
            if len(toks) < 4:
                self.fail(ll.line)
            if toks[1].kind != "ident" or toks[1].text in RESERVED:
                self.fail(ll.line)
            if not toks[2].is_punct(b"="):
                self.fail(ll.line)
            return SPhony(toks[1].text,
                          parse_expr_tokens(toks[3:], self.fn, ll.line))
        if kw in (b"include", b"abort", b"default"):
            if len(toks) < 2:
                self.fail(ll.line)
            expr = parse_expr_tokens(toks[1:], self.fn, ll.line)
            if kw == b"include":
                return SInclude(expr)
            if kw == b"abort":
                return SAbort(expr)
            return SDefault(expr)
        if kw == b"use":
            if len(toks) < 4 or toks[1].kind != "ident":
                self.fail(ll.line)
            p = ExprParser(toks[2:], self.fn, ll.line)
            args = self.parse_use_args(p, ll.line)
            p.expect_end()
            return SUse(toks[1].text, args)
        self.fail(ll.line)

    def parse_use_args(self, p, line):
        p.expect_punct(b"(")
        args = []
        seen_kw = False
        nt = p.peek()
        if nt is not None and nt.is_punct(b")"):
            p.advance()
            return args
        while True:
            nt = p.peek()
            n2 = p.peek2()
            if (nt is not None and nt.kind == "ident"
                    and nt.text not in RESERVED
                    and n2 is not None and n2.is_punct(b"=")):
                kwname = nt.text
                p.advance()
                p.advance()
                args.append((kwname, p.parse_expr()))
                seen_kw = True
            else:
                if seen_kw:
                    self.fail(line)
                args.append((None, p.parse_expr()))
            nt = p.peek()
            if nt is not None and nt.is_punct(b","):
                p.advance()
                nt = p.peek()
                if nt is not None and nt.is_punct(b")"):
                    p.advance()
                    return args
                continue
            if nt is not None and nt.is_punct(b")"):
                p.advance()
                return args
            self.fail(line)
