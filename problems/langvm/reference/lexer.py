"""The Vellum lexer: one module body becomes one token list.

Positions are module-local: line 1 is the first line after the `@module`
header, and a column counts Unicode scalar values from 1.
"""

from verrors import CompileError

KEYWORDS = frozenset((
    'as', 'break', 'continue', 'else', 'enum', 'false', 'fn', 'for', 'if',
    'impl', 'in', 'let', 'match', 'pub', 'return', 'self', 'struct', 'trait',
    'true', 'use', 'var', 'when', 'while',
))

# Longest first, so that the scanner can try them in order.
OPERATORS = (
    '#[', '::', '..', '->', '==', '!=', '<=', '>=', '&&', '||', '<<', '>>',
    '++',
    '(', ')', '[', ']', '{', '}', ',', ';', ':', '.', '|', '+', '-', '*',
    '/', '%', '!', '~', '&', '^', '<', '>', '=', '_',
)

HEXDIGITS = '0123456789abcdefABCDEF'
MAX_INT = 9223372036854775807
MAX_IDENT = 200

SIMPLE_ESCAPES = {
    'n': '\n', 't': '\t', 'r': '\r', '0': '\0',
    '\\': '\\', "'": "'", '"': '"',
}


class Token:
    __slots__ = ('kind', 'val', 'line', 'col')

    def __init__(self, kind, val, line, col):
        self.kind = kind
        self.val = val
        self.line = line
        self.col = col

    def __repr__(self):
        return 'Token(%r,%r,%d,%d)' % (self.kind, self.val, self.line, self.col)


class Lexer:
    def __init__(self, src):
        self.src = src
        self.n = len(src)
        self.i = 0
        self.line = 1
        self.col = 1
        self.toks = []

    def err(self, kind, line=None, col=None):
        raise CompileError(kind,
                           self.line if line is None else line,
                           self.col if col is None else col)

    def advance(self, k=1):
        """Move forward k characters, tracking line and column."""
        src = self.src
        for _ in range(k):
            if src[self.i] == '\n':
                self.line += 1
                self.col = 1
            else:
                self.col += 1
            self.i += 1

    def peek(self, k=0):
        j = self.i + k
        return self.src[j] if j < self.n else ''

    def run(self):
        while True:
            self.skip_trivia()
            if self.i >= self.n:
                break
            self.one_token()
        # The end-of-input position: the last line's length plus one.
        lines = self.src.split('\n')
        self.toks.append(Token('eof', None, len(lines), len(lines[-1]) + 1))
        return self.toks

    def skip_trivia(self):
        while self.i < self.n:
            c = self.src[self.i]
            if c in ' \t\n\r':
                self.advance()
            elif c == '/' and self.peek(1) == '/':
                while self.i < self.n and self.src[self.i] != '\n':
                    self.advance()
            elif c == '/' and self.peek(1) == '*':
                self.block_comment()
            else:
                return

    def block_comment(self):
        line, col = self.line, self.col
        depth = 0
        while self.i < self.n:
            c = self.src[self.i]
            if c == '/' and self.peek(1) == '*':
                depth += 1
                self.advance(2)
            elif c == '*' and self.peek(1) == '/':
                depth -= 1
                self.advance(2)
                if depth == 0:
                    return
            else:
                self.advance()
        self.err('unterminated', line, col)

    def one_token(self):
        line, col = self.line, self.col
        c = self.src[self.i]
        if c.isascii() and (c.isalpha() or c == '_'):
            self.ident(line, col)
        elif c.isascii() and c.isdigit():
            self.number(line, col)
        elif c == '"':
            self.string(line, col)
        elif c == "'":
            self.charlit(line, col)
        else:
            for op in OPERATORS:
                if self.src.startswith(op, self.i):
                    self.advance(len(op))
                    self.toks.append(Token(op, None, line, col))
                    return
            self.err('bad-token', line, col)

    def ident(self, line, col):
        j = self.i
        src = self.src
        while j < self.n:
            c = src[j]
            if c.isascii() and (c.isalnum() or c == '_'):
                j += 1
            else:
                break
        text = src[self.i:j]
        self.advance(j - self.i)
        if text == '_':
            self.toks.append(Token('_', None, line, col))
        elif text in KEYWORDS:
            self.toks.append(Token(text, None, line, col))
        else:
            if len(text) > MAX_IDENT:
                self.err('bad-token', line, col)
            self.toks.append(Token('ident', text, line, col))

    def digit_run(self, ok, line, col):
        """Scan `digit { digit | '_' }` and return the digits with no `_`."""
        src = self.src
        j = self.i
        if j >= self.n or src[j] not in ok:
            self.err('bad-token', line, col)
        out = []
        while j < self.n and (src[j] in ok or src[j] == '_'):
            if src[j] != '_':
                out.append(src[j])
            j += 1
        self.advance(j - self.i)
        return ''.join(out)

    def number(self, line, col):
        src = self.src
        if src[self.i] == '0' and self.peek(1) == 'x':
            self.advance(2)
            digits = self.digit_run(HEXDIGITS, line, col)
            self.finish_int(int(digits, 16), line, col)
            return
        if src[self.i] == '0' and self.peek(1) == 'b':
            self.advance(2)
            digits = self.digit_run('01', line, col)
            self.finish_int(int(digits, 2), line, col)
            return
        text = self.digit_run('0123456789', line, col)
        isfloat = False
        # A `.` is part of the number only when a digit follows it.
        if self.peek() == '.' and self.peek(1).isascii() and self.peek(1).isdigit():
            self.advance(1)
            frac = self.digit_run('0123456789', line, col)
            text = text + '.' + frac
            isfloat = True
        if self.peek() in ('e', 'E'):
            k = 1
            sign = ''
            if self.peek(1) in ('+', '-'):
                sign = self.peek(1)
                k = 2
            if self.peek(k).isascii() and self.peek(k).isdigit():
                self.advance(1 + len(sign))
                expd = self.digit_run('0123456789', line, col)
                text = text + 'e' + sign + expd
                isfloat = True
        if isfloat:
            self.toks.append(Token('float', float(text), line, col))
        else:
            self.finish_int(int(text), line, col)

    def finish_int(self, value, line, col):
        if value > MAX_INT:
            self.err('int-range', line, col)
        self.toks.append(Token('int', value, line, col))

    def escape(self):
        """Read one escape sequence; the `\\` is the current character."""
        bline, bcol = self.line, self.col
        self.advance(1)
        if self.i >= self.n:
            self.err('bad-escape', bline, bcol)
        c = self.src[self.i]
        if c in SIMPLE_ESCAPES:
            self.advance(1)
            return SIMPLE_ESCAPES[c]
        if c == 'u':
            if self.peek(1) != '{':
                self.err('bad-escape', bline, bcol)
            j = self.i + 2
            digits = []
            while j < self.n and self.src[j] in HEXDIGITS:
                digits.append(self.src[j])
                j += 1
            if not digits or len(digits) > 6 or j >= self.n or self.src[j] != '}':
                self.err('bad-escape', bline, bcol)
            value = int(''.join(digits), 16)
            if value > 0x10FFFF or 0xD800 <= value <= 0xDFFF:
                self.err('bad-escape', bline, bcol)
            self.advance(j + 1 - self.i)
            return chr(value)
        self.err('bad-escape', bline, bcol)

    def string(self, line, col):
        self.advance(1)
        out = []
        while True:
            if self.i >= self.n:
                self.err('unterminated', line, col)
            c = self.src[self.i]
            if c == '"':
                self.advance(1)
                break
            if c == '\n' or c == '\r':
                self.err('unterminated', line, col)
            if c == '\\':
                out.append(self.escape())
            else:
                out.append(c)
                self.advance(1)
        self.toks.append(Token('str', ''.join(out), line, col))

    def charlit(self, line, col):
        self.advance(1)
        if self.i >= self.n:
            self.err('unterminated', line, col)
        c = self.src[self.i]
        if c == "'" or c == '\n' or c == '\r':
            self.err('unterminated', line, col)
        if c == '\\':
            value = self.escape()
        else:
            value = c
            self.advance(1)
        if self.i >= self.n or self.src[self.i] != "'":
            self.err('unterminated', line, col)
        self.advance(1)
        self.toks.append(Token('char', value, line, col))


def lex(src):
    return Lexer(src).run()
