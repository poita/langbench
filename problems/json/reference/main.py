#!/usr/bin/env python3
"""Reference JSON parser and canonical serializer for the `json` problem.

Reads one JSON document from stdin, validates it against RFC 8259 plus the
extra rules in SPEC.md, and prints either the canonical serialization or
the word "invalid". The parser is a hand-written recursive descent parser;
regular expressions are used only to scan individual lexemes quickly.
"""
import re
import sys

MAX_DEPTH = 512

WS_RE = re.compile(r'[ \t\n\r]*')
NUM_RE = re.compile(r'-?(?:0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?')
# A run of string characters that need no processing: anything except the
# closing quote, a backslash, or a raw control character.
PLAIN_RE = re.compile(r'[^"\\\x00-\x1f]*')
HEXCHARS = set('0123456789abcdefABCDEF')
SIMPLE_ESCAPES = {
    '"': '"', '\\': '\\', '/': '/',
    'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t',
}

# Output escaping: only the characters the spec requires are escaped.
ESCAPE_RE = re.compile(r'["\\\x00-\x1f]')
ESCAPE_TABLE = {chr(c): '\\u%04x' % c for c in range(0x20)}
ESCAPE_TABLE.update({
    '"': '\\"', '\\': '\\\\', '\b': '\\b', '\f': '\\f',
    '\n': '\\n', '\r': '\\r', '\t': '\\t',
})


class Invalid(Exception):
    pass


def encode_string(u):
    return '"' + ESCAPE_RE.sub(lambda m: ESCAPE_TABLE[m.group(0)], u) + '"'


def normalize_number(lexeme, frac, exp):
    """Canonical text for a number lexeme (see SPEC.md, Numbers)."""
    if frac is None and exp is None:
        return lexeme
    if exp is None:
        return lexeme
    mantissa = lexeme[:len(lexeme) - len(exp)]
    e = exp[1:]
    sign = ''
    if e[0] in '+-':
        sign = e[0]
        e = e[1:]
    e = e.lstrip('0') or '0'
    if e == '0' or sign == '+':
        sign = ''
    return mantissa + 'e' + sign + e


def utf16_key(s):
    """Sort key giving UTF-16 code unit order."""
    return s.encode('utf-16-be')


class Parser:
    def __init__(self, text):
        self.s = text
        self.n = len(text)
        self.i = 0

    def skip_ws(self):
        self.i = WS_RE.match(self.s, self.i).end()

    def parse_document(self):
        out = self.parse_value(0)
        self.skip_ws()
        if self.i != self.n:
            raise Invalid()
        return out

    def parse_value(self, depth):
        """Parses one value and returns its canonical serialization."""
        self.skip_ws()
        s, i = self.s, self.i
        if i >= self.n:
            raise Invalid()
        c = s[i]
        if c == '"':
            return encode_string(self.parse_string())
        if c == '{':
            return self.parse_object(depth + 1)
        if c == '[':
            return self.parse_array(depth + 1)
        if c == '-' or c in '0123456789':
            m = NUM_RE.match(s, i)
            if m is None:
                raise Invalid()
            self.i = m.end()
            return normalize_number(m.group(0), m.group(1), m.group(2))
        if s.startswith('true', i):
            self.i = i + 4
            return 'true'
        if s.startswith('false', i):
            self.i = i + 5
            return 'false'
        if s.startswith('null', i):
            self.i = i + 4
            return 'null'
        raise Invalid()

    def parse_array(self, depth):
        if depth > MAX_DEPTH:
            raise Invalid()
        self.i += 1
        self.skip_ws()
        if self.i < self.n and self.s[self.i] == ']':
            self.i += 1
            return '[]'
        items = []
        while True:
            items.append(self.parse_value(depth))
            self.skip_ws()
            if self.i >= self.n:
                raise Invalid()
            c = self.s[self.i]
            self.i += 1
            if c == ',':
                continue
            if c == ']':
                return '[' + ','.join(items) + ']'
            raise Invalid()

    def parse_object(self, depth):
        if depth > MAX_DEPTH:
            raise Invalid()
        self.i += 1
        self.skip_ws()
        if self.i < self.n and self.s[self.i] == '}':
            self.i += 1
            return '{}'
        members = {}
        while True:
            self.skip_ws()
            if self.i >= self.n or self.s[self.i] != '"':
                raise Invalid()
            key = self.parse_string()
            self.skip_ws()
            if self.i >= self.n or self.s[self.i] != ':':
                raise Invalid()
            self.i += 1
            # Later duplicates overwrite earlier ones.
            members[key] = self.parse_value(depth)
            self.skip_ws()
            if self.i >= self.n:
                raise Invalid()
            c = self.s[self.i]
            self.i += 1
            if c == ',':
                continue
            if c == '}':
                break
            raise Invalid()
        keys = sorted(members, key=utf16_key)
        return '{' + ','.join(encode_string(k) + ':' + members[k] for k in keys) + '}'

    def parse_string(self):
        """Parses a string starting at the opening quote; returns its decoded value."""
        s, n = self.s, self.n
        i = self.i + 1
        parts = []
        while True:
            j = PLAIN_RE.match(s, i).end()
            if j >= n:
                raise Invalid()
            c = s[j]
            if c == '"':
                parts.append(s[i:j])
                self.i = j + 1
                return ''.join(parts)
            if c != '\\':
                # Raw control character.
                raise Invalid()
            parts.append(s[i:j])
            if j + 1 >= n:
                raise Invalid()
            e = s[j + 1]
            simple = SIMPLE_ESCAPES.get(e)
            if simple is not None:
                parts.append(simple)
                i = j + 2
                continue
            if e != 'u':
                raise Invalid()
            cp = self.hex4(j + 2)
            i = j + 6
            if 0xD800 <= cp <= 0xDBFF:
                # High surrogate must be immediately followed by an escaped low surrogate.
                if s[i:i + 2] != '\\u':
                    raise Invalid()
                low = self.hex4(i + 2)
                if not 0xDC00 <= low <= 0xDFFF:
                    raise Invalid()
                cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                i += 6
            elif 0xDC00 <= cp <= 0xDFFF:
                raise Invalid()
            parts.append(chr(cp))

    def hex4(self, i):
        h = self.s[i:i + 4]
        if len(h) != 4 or not all(ch in HEXCHARS for ch in h):
            raise Invalid()
        return int(h, 16)


def canonicalize(data):
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return None
    try:
        return Parser(text).parse_document()
    except Invalid:
        return None


def main():
    sys.setrecursionlimit(10000)
    data = sys.stdin.buffer.read()
    out = canonicalize(data)
    if out is None:
        sys.stdout.buffer.write(b'invalid\n')
    else:
        sys.stdout.buffer.write(out.encode('utf-8') + b'\n')


if __name__ == '__main__':
    main()
