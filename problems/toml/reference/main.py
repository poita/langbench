#!/usr/bin/env python3
"""TOML 1.0.0 decoder and encoder.

stdin carries a mode line ("decode" or "encode") followed by the document.
decode parses a TOML document and prints it as the tagged JSON described in
SPEC.md; encode reads that tagged JSON and prints canonical TOML.
"""
import json
import re
import sys

INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1

SCALAR_TYPES = ('string', 'integer', 'float', 'bool',
                'datetime', 'datetime-local', 'date-local', 'time-local')

DAYS_IN_MONTH = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)


class TomlError(Exception):
    """Signals a document that the TOML 1.0.0 grammar or table rules reject."""


# ---------------------------------------------------------------------------
# Value model
# ---------------------------------------------------------------------------

class Scalar:
    """A leaf value together with its tagged-JSON type name."""
    __slots__ = ('type', 'value')

    def __init__(self, type_, value):
        self.type = type_
        self.value = value


class Table:
    """A TOML table plus the provenance flags the table rules depend on."""
    __slots__ = ('items', 'explicit', 'inline', 'dotted', 'sealed')

    def __init__(self, inline=False, dotted=False, explicit=False):
        self.items = {}
        self.explicit = explicit  # written as [header] or as an inline table
        self.inline = inline      # part of an inline-table literal
        self.dotted = dotted      # brought into being by a dotted key
        self.sealed = False       # its inline-table literal has been closed


class Array:
    """Either an array literal (static) or an array of tables."""
    __slots__ = ('items', 'static')

    def __init__(self, static):
        self.items = []
        self.static = static


# ---------------------------------------------------------------------------
# Lexical patterns
# ---------------------------------------------------------------------------

RE_BARE_KEY = re.compile(r'[A-Za-z0-9_-]+')
# Digits are spelled out as [0-9] rather than \d: TOML digits are ASCII only,
# while Python's \d also matches decimal digits from other scripts.
RE_DATETIME = re.compile(
    r'([0-9]{4})-([0-9]{2})-([0-9]{2})'
    r'(?:([Tt ])([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?'
    r'([Zz]|[+-][0-9]{2}:[0-9]{2})?)?')
RE_TIME = re.compile(r'([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?')
RE_HEX = re.compile(r'0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*')
RE_OCT = re.compile(r'0o[0-7](?:_?[0-7])*')
RE_BIN = re.compile(r'0b[01](?:_?[01])*')
RE_SPECIAL_FLOAT = re.compile(r'[+-]?(?:inf|nan)')
RE_FLOAT = re.compile(
    r'[+-]?(?:0|[1-9](?:_?[0-9])*)'
    r'(?:(?:\.[0-9](?:_?[0-9])*)?[eE][+-]?[0-9](?:_?[0-9])*'
    r'|\.[0-9](?:_?[0-9])*)')
RE_INT = re.compile(r'[+-]?(?:0|[1-9](?:_?[0-9])*)')
RE_BOOL = re.compile(r'true|false')


def is_bare_char(c):
    return c.isascii() and (c.isalnum() or c in '_-')


# ---------------------------------------------------------------------------
# Canonical text for scalars
# ---------------------------------------------------------------------------

def format_float(x):
    """Renders a double as the canonical 17-significant-digit text."""
    if x != x:
        return 'nan'
    if x == float('inf'):
        return 'inf'
    if x == float('-inf'):
        return '-inf'
    return '%.16e' % x


def canonical_fraction(frac):
    """Strips trailing zeros from a fractional-second part, dot included."""
    if not frac:
        return ''
    digits = frac[1:].rstrip('0')
    return '.' + digits if digits else ''


def check_date(year, month, day):
    if year < 1:
        raise TomlError('year out of range')
    if not 1 <= month <= 12:
        raise TomlError('month out of range')
    limit = DAYS_IN_MONTH[month - 1]
    if month == 2 and (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)):
        limit = 29
    if not 1 <= day <= limit:
        raise TomlError('day out of range')


def check_time(hour, minute, second):
    if hour > 23 or minute > 59 or second > 59:
        raise TomlError('time out of range')


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

class Parser:
    def __init__(self, src):
        self.s = src
        self.n = len(src)
        self.i = 0
        self.root = Table(explicit=True)
        self.current = self.root

    # -- low level -----------------------------------------------------
    def eof(self):
        return self.i >= self.n

    def peek(self, k=0):
        j = self.i + k
        return self.s[j] if j < self.n else ''

    def error(self, msg='invalid TOML'):
        raise TomlError(msg)

    def skip_ws(self):
        s, n = self.s, self.n
        i = self.i
        while i < n and (s[i] == ' ' or s[i] == '\t'):
            i += 1
        self.i = i

    def skip_comment(self):
        """Consumes a comment if one starts here, validating its characters."""
        if self.peek() != '#':
            return
        s, n = self.s, self.n
        i = self.i + 1
        while i < n:
            c = s[i]
            if c == '\n':
                break
            if c == '\r' and i + 1 < n and s[i + 1] == '\n':
                break
            o = ord(c)
            if not (c == '\t' or 0x20 <= o <= 0x7E or o >= 0x80):
                self.error('control character in comment')
            i += 1
        self.i = i

    def at_newline(self):
        c = self.peek()
        return c == '\n' or (c == '\r' and self.peek(1) == '\n')

    def take_newline(self):
        if self.peek() == '\n':
            self.i += 1
            return True
        if self.peek() == '\r':
            if self.peek(1) == '\n':
                self.i += 2
                return True
            self.error('bare carriage return')
        return False

    def skip_blank(self):
        """Skips whitespace, comments and newlines between statements."""
        while True:
            self.skip_ws()
            self.skip_comment()
            if not self.take_newline():
                return

    def finish_line(self):
        """Requires the rest of the line to be blank after a statement."""
        self.skip_ws()
        self.skip_comment()
        if self.eof():
            return
        if not self.take_newline():
            self.error('trailing characters after statement')

    # -- document ------------------------------------------------------
    def parse(self):
        while True:
            self.skip_blank()
            if self.eof():
                break
            if self.peek() == '[':
                self.parse_header()
            else:
                self.parse_keyval(self.current)
            self.finish_line()
        return self.root

    # -- keys ----------------------------------------------------------
    def parse_simple_key(self):
        c = self.peek()
        if c == '"':
            return self.parse_basic_string()
        if c == "'":
            return self.parse_literal_string()
        m = RE_BARE_KEY.match(self.s, self.i)
        if not m:
            self.error('expected a key')
        self.i = m.end()
        return m.group(0)

    def parse_key(self):
        parts = [self.parse_simple_key()]
        while True:
            self.skip_ws()
            if self.peek() != '.':
                return parts
            self.i += 1
            self.skip_ws()
            parts.append(self.parse_simple_key())

    # -- table headers -------------------------------------------------
    def parse_header(self):
        self.i += 1
        aot = False
        if self.peek() == '[':
            aot = True
            self.i += 1
        self.skip_ws()
        parts = self.parse_key()
        self.skip_ws()
        if self.peek() != ']':
            self.error('unterminated table header')
        self.i += 1
        if aot:
            if self.peek() != ']':
                self.error('unterminated array-of-tables header')
            self.i += 1
        self.current = self.resolve_header(parts, aot)

    def resolve_header(self, parts, aot):
        t = self.root
        for k in parts[:-1]:
            v = t.items.get(k)
            if v is None:
                nt = Table()
                t.items[k] = nt
                t = nt
            elif isinstance(v, Table):
                if v.inline:
                    self.error('cannot extend an inline table')
                t = v
            elif isinstance(v, Array):
                if v.static or not v.items:
                    self.error('cannot extend an array literal')
                t = v.items[-1]
            else:
                self.error('key is not a table')
        k = parts[-1]
        v = t.items.get(k)
        if aot:
            if v is None:
                arr = Array(static=False)
                t.items[k] = arr
            elif isinstance(v, Array) and not v.static:
                arr = v
            else:
                self.error('cannot redefine as an array of tables')
            nt = Table(explicit=True)
            arr.items.append(nt)
            return nt
        if v is None:
            nt = Table(explicit=True)
            t.items[k] = nt
            return nt
        if isinstance(v, Table) and not v.explicit and not v.inline and not v.dotted:
            v.explicit = True
            return v
        self.error('table defined twice')

    # -- key/value statements -------------------------------------------
    def parse_keyval(self, table):
        parts = self.parse_key()
        self.skip_ws()
        if self.peek() != '=':
            self.error('expected =')
        self.i += 1
        self.skip_ws()
        value = self.parse_value()
        t = table
        for k in parts[:-1]:
            v = t.items.get(k)
            if v is None:
                nt = Table(dotted=True, inline=table.inline)
                t.items[k] = nt
                t = nt
            elif isinstance(v, Table) and not v.explicit and not v.sealed:
                t = v
            else:
                self.error('cannot extend this key with a dotted key')
        k = parts[-1]
        if k in t.items:
            self.error('duplicate key')
        t.items[k] = value

    # -- values ----------------------------------------------------------
    def parse_value(self):
        c = self.peek()
        if c == '"':
            if self.s.startswith('"""', self.i):
                return Scalar('string', self.parse_ml_basic_string())
            return Scalar('string', self.parse_basic_string())
        if c == "'":
            if self.s.startswith("'''", self.i):
                return Scalar('string', self.parse_ml_literal_string())
            return Scalar('string', self.parse_literal_string())
        if c == '[':
            return self.parse_array()
        if c == '{':
            return self.parse_inline_table()
        if c == 't' or c == 'f':
            m = RE_BOOL.match(self.s, self.i)
            if m:
                self.i = m.end()
                return Scalar('bool', m.group(0) == 'true')
            self.error('invalid value')
        m = RE_DATETIME.match(self.s, self.i)
        if m:
            self.i = m.end()
            return self.make_datetime(m)
        m = RE_TIME.match(self.s, self.i)
        if m:
            self.i = m.end()
            hour, minute, second = int(m.group(1)), int(m.group(2)), int(m.group(3))
            check_time(hour, minute, second)
            return Scalar('time-local', '%02d:%02d:%02d%s'
                          % (hour, minute, second, canonical_fraction(m.group(4))))
        m = RE_SPECIAL_FLOAT.match(self.s, self.i)
        if m:
            self.i = m.end()
            text = m.group(0)
            if text.endswith('nan'):
                return Scalar('float', float('nan'))
            return Scalar('float', float('-inf') if text[0] == '-' else float('inf'))
        for pattern, base in ((RE_HEX, 16), (RE_OCT, 8), (RE_BIN, 2)):
            m = pattern.match(self.s, self.i)
            if m:
                self.i = m.end()
                v = int(m.group(0)[2:].replace('_', ''), base)
                if not INT_MIN <= v <= INT_MAX:
                    self.error('integer out of range')
                return Scalar('integer', v)
        m = RE_FLOAT.match(self.s, self.i)
        if m:
            self.i = m.end()
            return Scalar('float', float(m.group(0).replace('_', '')))
        m = RE_INT.match(self.s, self.i)
        if m:
            self.i = m.end()
            v = int(m.group(0).replace('_', ''))
            if not INT_MIN <= v <= INT_MAX:
                self.error('integer out of range')
            return Scalar('integer', v)
        self.error('invalid value')

    def make_datetime(self, m):
        year, month, day = int(m.group(1)), int(m.group(2)), int(m.group(3))
        check_date(year, month, day)
        date = '%04d-%02d-%02d' % (year, month, day)
        if m.group(4) is None:
            return Scalar('date-local', date)
        hour, minute, second = int(m.group(5)), int(m.group(6)), int(m.group(7))
        check_time(hour, minute, second)
        stamp = '%sT%02d:%02d:%02d%s' % (date, hour, minute, second,
                                         canonical_fraction(m.group(8)))
        offset = m.group(9)
        if offset is None:
            return Scalar('datetime-local', stamp)
        if offset in ('Z', 'z'):
            return Scalar('datetime', stamp + 'Z')
        oh, om = int(offset[1:3]), int(offset[4:6])
        if oh > 23 or om > 59:
            self.error('offset out of range')
        if oh == 0 and om == 0:
            return Scalar('datetime', stamp + 'Z')
        return Scalar('datetime', '%s%s%02d:%02d' % (stamp, offset[0], oh, om))

    # -- strings ---------------------------------------------------------
    def parse_basic_string(self):
        self.i += 1
        out = []
        while True:
            if self.eof():
                self.error('unterminated string')
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return ''.join(out)
            if c == '\\':
                out.append(self.parse_escape())
                continue
            o = ord(c)
            if not (c == '\t' or 0x20 <= o <= 0x7E or o >= 0x80):
                self.error('control character in string')
            out.append(c)
            self.i += 1

    def parse_escape(self):
        self.i += 1
        c = self.peek()
        simple = {'b': '\b', 't': '\t', 'n': '\n', 'f': '\f', 'r': '\r',
                  '"': '"', '\\': '\\'}
        if c in simple:
            self.i += 1
            return simple[c]
        if c == 'u' or c == 'U':
            width = 4 if c == 'u' else 8
            digits = self.s[self.i + 1:self.i + 1 + width]
            if len(digits) != width or not all(d in '0123456789abcdefABCDEF' for d in digits):
                self.error('bad unicode escape')
            cp = int(digits, 16)
            if cp > 0x10FFFF or 0xD800 <= cp <= 0xDFFF:
                self.error('escape is not a Unicode scalar value')
            self.i += 1 + width
            return chr(cp)
        self.error('unknown escape sequence')

    def parse_ml_delimiter(self, quote):
        """Handles a run of quote characters inside a multi-line string.

        Returns the text to append and whether the string ends here.
        """
        j = self.i
        while j < self.n and self.s[j] == quote:
            j += 1
        run = j - self.i
        if run < 3:
            self.i = j
            return quote * run, False
        if run > 5:
            self.error('too many quotes')
        self.i = j
        return quote * (run - 3), True

    def parse_ml_basic_string(self):
        self.i += 3
        if self.peek() == '\r' and self.peek(1) == '\n':
            self.i += 2
        elif self.peek() == '\n':
            self.i += 1
        out = []
        while True:
            if self.eof():
                self.error('unterminated string')
            c = self.s[self.i]
            if c == '"':
                text, done = self.parse_ml_delimiter('"')
                out.append(text)
                if done:
                    return ''.join(out)
                continue
            if c == '\\':
                if self.is_escaped_newline():
                    self.skip_escaped_newline()
                    continue
                out.append(self.parse_escape())
                continue
            if c == '\n':
                out.append('\n')
                self.i += 1
                continue
            if c == '\r':
                if self.peek(1) != '\n':
                    self.error('bare carriage return')
                out.append('\n')
                self.i += 2
                continue
            o = ord(c)
            if not (c == '\t' or 0x20 <= o <= 0x7E or o >= 0x80):
                self.error('control character in string')
            out.append(c)
            self.i += 1

    def is_escaped_newline(self):
        j = self.i + 1
        while j < self.n and self.s[j] in ' \t':
            j += 1
        if j < self.n and self.s[j] == '\n':
            return True
        return j + 1 < self.n and self.s[j] == '\r' and self.s[j + 1] == '\n'

    def skip_escaped_newline(self):
        self.i += 1
        while True:
            c = self.peek()
            if c == ' ' or c == '\t':
                self.i += 1
            elif c == '\n':
                self.i += 1
            elif c == '\r' and self.peek(1) == '\n':
                self.i += 2
            else:
                return

    def parse_literal_string(self):
        self.i += 1
        out = []
        while True:
            if self.eof():
                self.error('unterminated string')
            c = self.s[self.i]
            if c == "'":
                self.i += 1
                return ''.join(out)
            o = ord(c)
            if not (c == '\t' or 0x20 <= o <= 0x7E or o >= 0x80):
                self.error('control character in string')
            out.append(c)
            self.i += 1

    def parse_ml_literal_string(self):
        self.i += 3
        if self.peek() == '\r' and self.peek(1) == '\n':
            self.i += 2
        elif self.peek() == '\n':
            self.i += 1
        out = []
        while True:
            if self.eof():
                self.error('unterminated string')
            c = self.s[self.i]
            if c == "'":
                text, done = self.parse_ml_delimiter("'")
                out.append(text)
                if done:
                    return ''.join(out)
                continue
            if c == '\n':
                out.append('\n')
                self.i += 1
                continue
            if c == '\r':
                if self.peek(1) != '\n':
                    self.error('bare carriage return')
                out.append('\n')
                self.i += 2
                continue
            o = ord(c)
            if not (c == '\t' or 0x20 <= o <= 0x7E or o >= 0x80):
                self.error('control character in string')
            out.append(c)
            self.i += 1

    # -- collections -------------------------------------------------------
    def parse_array(self):
        self.i += 1
        arr = Array(static=True)
        while True:
            self.skip_blank()
            if self.eof():
                self.error('unterminated array')
            if self.peek() == ']':
                self.i += 1
                return arr
            arr.items.append(self.parse_value())
            self.skip_blank()
            if self.peek() == ',':
                self.i += 1
                continue
            if self.peek() == ']':
                self.i += 1
                return arr
            self.error('expected , or ] in array')

    def parse_inline_table(self):
        self.i += 1
        table = Table(inline=True, explicit=True)
        self.skip_ws()
        if self.peek() == '}':
            self.i += 1
            seal(table)
            return table
        while True:
            self.skip_ws()
            if self.at_newline():
                self.error('newline in inline table')
            self.parse_keyval(table)
            self.skip_ws()
            c = self.peek()
            if c == ',':
                self.i += 1
                continue
            if c == '}':
                self.i += 1
                seal(table)
                return table
            self.error('expected , or } in inline table')


def seal(table):
    """Marks a finished inline table and its sub-tables as unextendable."""
    table.sealed = True
    for v in table.items.values():
        if isinstance(v, Table):
            seal(v)


# ---------------------------------------------------------------------------
# Tagged JSON output
# ---------------------------------------------------------------------------

def to_tagged(value):
    if isinstance(value, Table):
        return {k: to_tagged(v) for k, v in value.items.items()}
    if isinstance(value, Array):
        return [to_tagged(v) for v in value.items]
    if value.type == 'integer':
        return {'type': 'integer', 'value': str(value.value)}
    if value.type == 'float':
        return {'type': 'float', 'value': format_float(value.value)}
    if value.type == 'bool':
        return {'type': 'bool', 'value': 'true' if value.value else 'false'}
    return {'type': value.type, 'value': value.value}


def decode(data):
    try:
        src = data.decode('utf-8')
    except UnicodeDecodeError:
        return 'error'
    try:
        root = Parser(src).parse()
    except TomlError:
        return 'error'
    except RecursionError:
        return 'error'
    return json.dumps(to_tagged(root), ensure_ascii=False, sort_keys=True,
                      separators=(',', ':'))


# ---------------------------------------------------------------------------
# Canonical TOML output
# ---------------------------------------------------------------------------

ESCAPES = {'"': '\\"', '\\': '\\\\', '\b': '\\b', '\t': '\\t',
           '\n': '\\n', '\f': '\\f', '\r': '\\r'}


def quote_string(s):
    out = ['"']
    for c in s:
        if c in ESCAPES:
            out.append(ESCAPES[c])
        elif ord(c) < 0x20 or ord(c) == 0x7F:
            out.append('\\u%04x' % ord(c))
        else:
            out.append(c)
    out.append('"')
    return ''.join(out)


def render_key(k):
    if k and all(is_bare_char(c) for c in k):
        return k
    return quote_string(k)


def is_tagged(v):
    return (isinstance(v, dict) and len(v) == 2
            and isinstance(v.get('type'), str) and isinstance(v.get('value'), str)
            and v['type'] in SCALAR_TYPES)


def is_table(v):
    return isinstance(v, dict) and not is_tagged(v)


def is_table_array(v):
    return isinstance(v, list) and len(v) > 0 and all(is_table(x) for x in v)


def render_scalar(tag):
    kind, text = tag['type'], tag['value']
    if kind == 'string':
        return quote_string(text)
    return text


def render_inline(v):
    if is_tagged(v):
        return render_scalar(v)
    if isinstance(v, list):
        return '[' + ', '.join(render_inline(x) for x in v) + ']'
    parts = ['%s = %s' % (render_key(k), render_inline(v[k])) for k in sorted(v)]
    return '{' + ', '.join(parts) + '}'


def render_path(path):
    return '.'.join(render_key(k) for k in path)


def render_table(table, path, out):
    keys = sorted(table)
    for k in keys:
        v = table[k]
        if not is_table(v) and not is_table_array(v):
            out.append('%s = %s' % (render_key(k), render_inline(v)))
    for k in keys:
        v = table[k]
        if is_table(v):
            if out:
                out.append('')
            out.append('[' + render_path(path + [k]) + ']')
            render_table(v, path + [k], out)
        elif is_table_array(v):
            for elem in v:
                if out:
                    out.append('')
                out.append('[[' + render_path(path + [k]) + ']]')
                render_table(elem, path + [k], out)


def encode(data):
    doc = json.loads(data.decode('utf-8'))
    out = []
    render_table(doc, [], out)
    return '\n'.join(out)


# ---------------------------------------------------------------------------

def main():
    data = sys.stdin.buffer.read()
    nl = data.find(b'\n')
    if nl < 0:
        mode, body = data.strip(), b''
    else:
        mode, body = data[:nl].strip(), data[nl + 1:]
    sys.setrecursionlimit(20000)
    if mode == b'decode':
        sys.stdout.write(decode(body) + '\n')
    elif mode == b'encode':
        sys.stdout.write(encode(body) + '\n')
    else:
        sys.stderr.write('unknown mode\n')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
