"""KBL lexer: comment stripping, logical-line assembly and tokenisation.

All three stages share one literal scanner so that they can never disagree
about what lies inside a string literal.
"""
from kiln_err import parse_error

DQUOTE = 0x22
SQUOTE = 0x27
BACKSLASH = 0x5C
LBRACE = 0x7B
RBRACE = 0x7D
HASH = 0x23

RESERVED = frozenset([
    b"abort", b"after", b"cmd", b"cost", b"default", b"depfile", b"each",
    b"elsewhen", b"false", b"in", b"include", b"let", b"otherwise", b"out",
    b"phony", b"rule", b"set", b"step", b"true", b"use", b"when",
])

TWO_OPS = frozenset([b"|>", b"||", b"&&", b"==", b"!=", b"<=", b">=", b"++"])
ONE_OPS = frozenset([b"<", b">", b"~", b"+", b"-", b"*", b"/", b"%", b"!"])
PUNCT = frozenset([b"(", b")", b"[", b"]", b"{", b"}", b",", b"="])


class LexFail(Exception):
    """Raised inside the scanner; the caller attaches file and line."""


def skip_literal(buf, i, end):
    """Skip the string literal starting at ``buf[i]`` and return the index just
    past its closing quote."""
    if buf[i] == SQUOTE:
        return skip_single(buf, i, end)
    return skip_double(buf, i, end)


def skip_single(buf, i, end):
    i += 1
    while i < end:
        if buf[i] == SQUOTE:
            if i + 1 < end and buf[i + 1] == SQUOTE:
                i += 2
            else:
                return i + 1
        else:
            i += 1
    raise LexFail()


def skip_double(buf, i, end):
    i += 1
    while i < end:
        c = buf[i]
        if c == BACKSLASH:
            if i + 1 >= end:
                raise LexFail()
            i += 2
        elif c == LBRACE:
            if i + 1 < end and buf[i + 1] == LBRACE:
                i += 2
            else:
                i = skip_interp(buf, i + 1, end)
        elif c == RBRACE:
            # A lone '}' is an ordinary byte to the scanner; the string-literal
            # reader rejects it when the literal is parsed.
            if i + 1 < end and buf[i + 1] == RBRACE:
                i += 2
            else:
                i += 1
        elif c == DQUOTE:
            return i + 1
        else:
            i += 1
    raise LexFail()


def skip_interp(buf, i, end):
    """Skip an interpolation region whose opening brace has been consumed, and
    return the index just past the brace that closes it."""
    depth = 1
    while i < end:
        c = buf[i]
        if c == DQUOTE or c == SQUOTE:
            i = skip_literal(buf, i, end)
        elif c == LBRACE:
            depth += 1
            i += 1
        elif c == RBRACE:
            depth -= 1
            i += 1
            if depth == 0:
                return i
        else:
            i += 1
    raise LexFail()


def _scan_physical(line, depth):
    """Strip a comment from one physical line and update the bracket depth.

    Returns ``(stripped, depth)``; raises ``LexFail`` on an unterminated
    literal or a negative bracket depth.
    """
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == DQUOTE or c == SQUOTE:
            i = skip_literal(line, i, n)
        elif c == HASH:
            line = line[:i]
            break
        elif c == 0x28 or c == 0x5B:   # ( [
            depth += 1
            i += 1
        elif c == 0x29 or c == 0x5D:   # ) ]
            depth -= 1
            if depth < 0:
                raise LexFail()
            i += 1
        else:
            i += 1
    return line.rstrip(b" \t"), depth


def physical_lines(src):
    if src.endswith(b"\n"):
        src = src[:-1]
    elif src == b"":
        return []
    return src.split(b"\n")


class LogicalLine(object):
    __slots__ = ("line", "text", "toks")

    def __init__(self, line, text, toks):
        self.line = line
        self.text = text
        self.toks = toks


class Token(object):
    __slots__ = ("kind", "text")

    def __init__(self, kind, text):
        self.kind = kind
        self.text = text

    def is_punct(self, s):
        return self.kind == "punct" and self.text == s

    def is_op(self, s):
        return self.kind == "op" and self.text == s

    def is_word(self, s):
        return self.kind == "ident" and self.text == s

    def __repr__(self):
        return "Token(%s,%r)" % (self.kind, self.text)


def _is_ident_start(c):
    return 65 <= c <= 90 or 97 <= c <= 122 or c == 0x5F


def _is_ident_cont(c):
    return 65 <= c <= 90 or 97 <= c <= 122 or c == 0x5F or 48 <= c <= 57


def tokenize(text, filename, lineno):
    """Split one logical line's text into tokens."""
    toks = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == 0x20 or c == 0x09:
            i += 1
            continue
        if _is_ident_start(c):
            j = i + 1
            while j < n and _is_ident_cont(text[j]):
                j += 1
            toks.append(Token("ident", text[i:j]))
            i = j
        elif 48 <= c <= 57:
            j = i + 1
            while j < n and 48 <= text[j] <= 57:
                j += 1
            toks.append(Token("int", text[i:j]))
            i = j
        elif c == DQUOTE or c == SQUOTE:
            try:
                j = skip_literal(text, i, n)
            except LexFail:
                raise parse_error(filename, lineno)
            toks.append(Token("str", text[i:j]))
            i = j
        else:
            two = text[i:i + 2]
            one = text[i:i + 1]
            if two in TWO_OPS:
                toks.append(Token("op", two))
                i += 2
            elif one in ONE_OPS:
                toks.append(Token("op", one))
                i += 1
            elif one in PUNCT:
                toks.append(Token("punct", one))
                i += 1
            else:
                raise parse_error(filename, lineno)
    return toks


def lex_file(src, filename):
    """Lex a whole build file into a list of tokenised logical lines."""
    out = []
    start = None
    acc = None
    depth = 0
    for idx, pl in enumerate(physical_lines(src)):
        lineno = idx + 1
        if start is None:
            start = lineno
            acc = []
            depth = 0
        try:
            stripped, depth = _scan_physical(pl, depth)
        except LexFail:
            raise parse_error(filename, start)
        acc.append(stripped)
        if depth == 0:
            text = b" ".join(acc)
            if text.strip(b" \t"):
                out.append(LogicalLine(start, text,
                                       tokenize(text, filename, start)))
            start = None
    if start is not None:
        raise parse_error(filename, start)
    return out
