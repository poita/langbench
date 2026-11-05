#!/usr/bin/env python3
"""Reference solver for the `protowire` problem.

Parses the schema, then answers each `decode`/`encode` request with the
canonical text form, the canonical wire bytes, or `error`, following the
rules in SPEC.md. The wire format is implemented from scratch.
"""
import sys

SCALARS = {'int32', 'int64', 'uint32', 'uint64', 'sint32', 'sint64', 'bool',
           'fixed32', 'fixed64', 'sfixed32', 'sfixed64', 'string', 'bytes'}
VARINT_TYPES = {'int32', 'int64', 'uint32', 'uint64', 'sint32', 'sint64', 'bool'}
FIXED32_TYPES = {'fixed32', 'sfixed32'}
FIXED64_TYPES = {'fixed64', 'sfixed64'}
SIGNED_TYPES = {'int32', 'int64', 'sint32', 'sint64', 'sfixed32', 'sfixed64'}
INT_RANGE = {
    'int32': (-2 ** 31, 2 ** 31 - 1), 'sint32': (-2 ** 31, 2 ** 31 - 1), 'sfixed32': (-2 ** 31, 2 ** 31 - 1),
    'int64': (-2 ** 63, 2 ** 63 - 1), 'sint64': (-2 ** 63, 2 ** 63 - 1), 'sfixed64': (-2 ** 63, 2 ** 63 - 1),
    'uint32': (0, 2 ** 32 - 1), 'fixed32': (0, 2 ** 32 - 1),
    'uint64': (0, 2 ** 64 - 1), 'fixed64': (0, 2 ** 64 - 1),
}
MASK64 = (1 << 64) - 1
MASK32 = (1 << 32) - 1


class Error(Exception):
    pass


class Field:
    __slots__ = ('name', 'type', 'number', 'repeated', 'wire')

    def __init__(self, name, type_, number, repeated):
        self.name = name
        self.type = type_
        self.number = number
        self.repeated = repeated
        if type_ in VARINT_TYPES:
            self.wire = 0
        elif type_ in FIXED64_TYPES:
            self.wire = 1
        elif type_ in FIXED32_TYPES:
            self.wire = 5
        else:
            self.wire = 2

    def is_message(self):
        return self.type not in SCALARS

    def packable(self):
        return self.repeated and self.wire != 2


# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------
def tokenize_schema(text):
    tokens = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c in ' \t\r\n':
            i += 1
        elif c in '{};=':
            tokens.append(c)
            i += 1
        else:
            j = i
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            if j == i:
                raise Error('bad schema char')
            tokens.append(text[i:j])
            i = j
    return tokens


def parse_schema(text):
    tokens = tokenize_schema(text)
    messages = {}
    i = 0
    while i < len(tokens):
        assert tokens[i] == 'message' and tokens[i + 2] == '{'
        name = tokens[i + 1]
        i += 3
        fields = []
        while tokens[i] != '}':
            repeated = False
            if tokens[i] == 'repeated':
                repeated = True
                i += 1
            type_, fname, eq, num, semi = tokens[i:i + 5]
            assert eq == '=' and semi == ';'
            fields.append(Field(fname, type_, int(num), repeated))
            i += 5
        i += 1
        fields.sort(key=lambda f: f.number)
        messages[name] = {
            'fields': fields,
            'by_number': {f.number: f for f in fields},
            'by_name': {f.name: f for f in fields},
        }
    return messages


# ---------------------------------------------------------------------------
# Wire decoding
# ---------------------------------------------------------------------------
def read_varint(data, pos, end, max_bytes=10):
    """Reads a varint of at most max_bytes bytes; the value is taken modulo 2^64."""
    result = 0
    shift = 0
    count = 0
    while True:
        if pos >= end:
            raise Error('truncated varint')
        b = data[pos]
        pos += 1
        count += 1
        result |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return result & MASK64, pos
        if count >= max_bytes:
            raise Error('varint too long')


def zigzag_decode(v):
    return (v >> 1) ^ -(v & 1)


def to_signed(v, bits):
    if v >= 1 << (bits - 1):
        v -= 1 << bits
    return v


def convert_varint(type_, v):
    if type_ == 'int32':
        return to_signed(v & MASK32, 32)
    if type_ == 'int64':
        return to_signed(v, 64)
    if type_ == 'uint32':
        return v & MASK32
    if type_ == 'uint64':
        return v
    if type_ == 'sint32':
        return zigzag_decode(v & MASK32)
    if type_ == 'sint64':
        return zigzag_decode(v)
    if type_ == 'bool':
        return v != 0
    raise AssertionError(type_)


def read_fixed(data, pos, end, size, type_):
    if end - pos < size:
        raise Error('truncated fixed')
    v = int.from_bytes(data[pos:pos + size], 'little')
    if type_ in ('sfixed32', 'sfixed64'):
        v = to_signed(v, size * 8)
    return v, pos + size


def read_length(data, pos, end):
    length, pos = read_varint(data, pos, end, 5)
    if length > end - pos:
        raise Error('length exceeds data')
    return length, pos


def skip_field(data, pos, end, wire, number):
    if wire == 0:
        _, pos = read_varint(data, pos, end)
    elif wire == 1:
        if end - pos < 8:
            raise Error('truncated')
        pos += 8
    elif wire == 5:
        if end - pos < 4:
            raise Error('truncated')
        pos += 4
    elif wire == 2:
        length, pos = read_length(data, pos, end)
        pos += length
    elif wire == 3:
        # A group: skip fields until the matching end-group tag.
        while True:
            if pos >= end:
                raise Error('unterminated group')
            tag, pos = read_varint(data, pos, end, 5)
            if tag > MASK32:
                raise Error('bad tag')
            inner_wire = tag & 7
            inner_number = tag >> 3
            if inner_number == 0 or inner_wire in (6, 7):
                raise Error('bad tag')
            if inner_wire == 4:
                if inner_number != number:
                    raise Error('mismatched end group')
                return pos
            pos = skip_field(data, pos, end, inner_wire, inner_number)
    else:
        raise Error('bad wire type')
    return pos


def decode_message(messages, mtype, data, pos, end, into=None):
    schema = messages[mtype]
    values = {} if into is None else into
    while pos < end:
        tag, pos = read_varint(data, pos, end, 5)
        if tag > MASK32:
            raise Error('bad tag')
        wire = tag & 7
        number = tag >> 3
        if number == 0 or wire in (4, 6, 7):
            raise Error('bad tag')
        field = schema['by_number'].get(number)
        if field is None or not (wire == field.wire or (field.packable() and wire == 2)):
            pos = skip_field(data, pos, end, wire, number)
            continue
        t = field.type
        if field.is_message():
            length, pos = read_length(data, pos, end)
            if field.repeated:
                sub = decode_message(messages, t, data, pos, pos + length)
                values.setdefault(field.name, []).append(sub)
            else:
                existing = values.get(field.name)
                values[field.name] = decode_message(messages, t, data, pos, pos + length, existing)
            pos += length
        elif t in ('string', 'bytes'):
            length, pos = read_length(data, pos, end)
            raw = data[pos:pos + length]
            pos += length
            if t == 'string':
                try:
                    raw = raw.decode('utf-8')
                except UnicodeDecodeError:
                    raise Error('bad utf-8')
            if field.repeated:
                values.setdefault(field.name, []).append(raw)
            else:
                values[field.name] = raw
        elif wire == 2:
            # Packed repeated numeric field.
            length, pos = read_length(data, pos, end)
            stop = pos + length
            lst = values.setdefault(field.name, [])
            if field.wire == 0:
                while pos < stop:
                    v, pos = read_varint(data, pos, stop)
                    lst.append(convert_varint(t, v))
            else:
                size = 4 if field.wire == 5 else 8
                if length % size:
                    raise Error('bad packed length')
                while pos < stop:
                    v, pos = read_fixed(data, pos, stop, size, t)
                    lst.append(v)
        else:
            if wire == 0:
                v, pos = read_varint(data, pos, end)
                v = convert_varint(t, v)
            else:
                v, pos = read_fixed(data, pos, end, 4 if wire == 5 else 8, t)
            if field.repeated:
                values.setdefault(field.name, []).append(v)
            else:
                values[field.name] = v
    return values


# ---------------------------------------------------------------------------
# Wire encoding
# ---------------------------------------------------------------------------
def write_varint(out, v):
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return


def zigzag_encode(v, bits):
    return ((v << 1) ^ (v >> (bits - 1))) & ((1 << bits) - 1)


def encode_scalar(out, t, v):
    if t in ('int32', 'int64'):
        write_varint(out, v & MASK64)
    elif t in ('uint32', 'uint64'):
        write_varint(out, v)
    elif t == 'sint32':
        write_varint(out, zigzag_encode(v, 32))
    elif t == 'sint64':
        write_varint(out, zigzag_encode(v, 64))
    elif t == 'bool':
        write_varint(out, 1 if v else 0)
    elif t in ('fixed32', 'sfixed32'):
        out += (v & MASK32).to_bytes(4, 'little')
    elif t in ('fixed64', 'sfixed64'):
        out += (v & MASK64).to_bytes(8, 'little')
    else:
        raise AssertionError(t)


def encode_message(messages, mtype, values, out):
    for field in messages[mtype]['fields']:
        if field.name not in values:
            continue
        v = values[field.name]
        t = field.type
        if field.repeated:
            if not v:
                continue
            if field.is_message():
                for item in v:
                    write_varint(out, (field.number << 3) | 2)
                    sub = bytearray()
                    encode_message(messages, t, item, sub)
                    write_varint(out, len(sub))
                    out += sub
            elif t in ('string', 'bytes'):
                for item in v:
                    raw = item.encode('utf-8') if t == 'string' else item
                    write_varint(out, (field.number << 3) | 2)
                    write_varint(out, len(raw))
                    out += raw
            else:
                packed = bytearray()
                for item in v:
                    encode_scalar(packed, t, item)
                write_varint(out, (field.number << 3) | 2)
                write_varint(out, len(packed))
                out += packed
        elif field.is_message():
            write_varint(out, (field.number << 3) | 2)
            sub = bytearray()
            encode_message(messages, t, v, sub)
            write_varint(out, len(sub))
            out += sub
        elif t in ('string', 'bytes'):
            raw = v.encode('utf-8') if t == 'string' else v
            if not raw:
                continue
            write_varint(out, (field.number << 3) | 2)
            write_varint(out, len(raw))
            out += raw
        else:
            if v == 0 or v is False:
                continue
            write_varint(out, (field.number << 3) | field.wire)
            encode_scalar(out, t, v)


# ---------------------------------------------------------------------------
# Text rendering
# ---------------------------------------------------------------------------
def render_string(s):
    parts = ['"']
    for ch in s:
        c = ord(ch)
        if ch == '"':
            parts.append('\\"')
        elif ch == '\\':
            parts.append('\\\\')
        elif ch == '\n':
            parts.append('\\n')
        elif ch == '\r':
            parts.append('\\r')
        elif ch == '\t':
            parts.append('\\t')
        elif c < 0x20 or c == 0x7F:
            parts.append('\\x%02x' % c)
        else:
            parts.append(ch)
    parts.append('"')
    return ''.join(parts)


def render_value(messages, t, v):
    if t not in SCALARS:
        return render_message(messages, t, v)
    if t == 'bool':
        return 'true' if v else 'false'
    if t == 'string':
        return render_string(v)
    if t == 'bytes':
        return 'x"' + v.hex() + '"'
    return str(v)


def render_message(messages, mtype, values):
    parts = []
    for field in messages[mtype]['fields']:
        if field.name not in values:
            continue
        v = values[field.name]
        if field.repeated:
            if not v:
                continue
            text = '[' + ', '.join(render_value(messages, field.type, x) for x in v) + ']'
        elif field.is_message():
            text = render_message(messages, field.type, v)
        else:
            if v == 0 or v == '' or v == b'' or v is False:
                continue
            text = render_value(messages, field.type, v)
        parts.append(field.name + ': ' + text)
    return '{' + ', '.join(parts) + '}'


# ---------------------------------------------------------------------------
# Text parsing (for encode requests)
# ---------------------------------------------------------------------------
class TextParser:
    def __init__(self, messages, text):
        self.messages = messages
        self.text = text
        self.pos = 0

    def skip_spaces(self):
        while self.pos < len(self.text) and self.text[self.pos] == ' ':
            self.pos += 1

    def peek(self):
        self.skip_spaces()
        if self.pos >= len(self.text):
            raise Error('unexpected end')
        return self.text[self.pos]

    def expect(self, ch):
        if self.peek() != ch:
            raise Error('expected ' + ch)
        self.pos += 1

    def ident(self):
        self.skip_spaces()
        start = self.pos
        while self.pos < len(self.text) and (self.text[self.pos].isalnum() or self.text[self.pos] == '_'):
            self.pos += 1
        if start == self.pos:
            raise Error('expected identifier')
        return self.text[start:self.pos]

    def parse_message(self, mtype):
        schema = self.messages[mtype]
        self.expect('{')
        values = {}
        if self.peek() == '}':
            self.pos += 1
            return values
        while True:
            name = self.ident()
            field = schema['by_name'].get(name)
            if field is None or name in values:
                raise Error('bad field name')
            self.expect(':')
            if field.repeated:
                self.expect('[')
                items = []
                if self.peek() == ']':
                    self.pos += 1
                else:
                    while True:
                        items.append(self.parse_value(field.type))
                        c = self.peek()
                        self.pos += 1
                        if c == ']':
                            break
                        if c != ',':
                            raise Error('expected , or ]')
                values[name] = items
            else:
                values[name] = self.parse_value(field.type)
            c = self.peek()
            self.pos += 1
            if c == '}':
                return values
            if c != ',':
                raise Error('expected , or }')

    def parse_value(self, t):
        if t not in SCALARS:
            return self.parse_message(t)
        c = self.peek()
        if t == 'bool':
            for word, val in (('true', True), ('false', False)):
                if self.text.startswith(word, self.pos):
                    self.pos += len(word)
                    return val
            raise Error('expected bool')
        if t == 'string':
            return self.parse_string()
        if t == 'bytes':
            if not self.text.startswith('x"', self.pos):
                raise Error('expected bytes')
            self.pos += 2
            start = self.pos
            while self.pos < len(self.text) and self.text[self.pos] in '0123456789abcdef':
                self.pos += 1
            hexdigits = self.text[start:self.pos]
            if self.pos >= len(self.text) or self.text[self.pos] != '"' or len(hexdigits) % 2:
                raise Error('bad bytes literal')
            self.pos += 1
            return bytes.fromhex(hexdigits)
        return self.parse_int(t)

    def parse_int(self, t):
        start = self.pos
        if self.text[self.pos] == '-':
            self.pos += 1
        digits_start = self.pos
        while self.pos < len(self.text) and self.text[self.pos].isdigit() and self.text[self.pos].isascii():
            self.pos += 1
        digits = self.text[digits_start:self.pos]
        if not digits or (len(digits) > 1 and digits[0] == '0'):
            raise Error('bad integer')
        v = int(self.text[start:self.pos])
        if self.text[start] == '-' and (v == 0 or t not in SIGNED_TYPES):
            raise Error('bad sign')
        lo, hi = INT_RANGE[t]
        if not lo <= v <= hi:
            raise Error('out of range')
        return v

    def parse_string(self):
        self.expect('"')
        buf = bytearray()
        text = self.text
        while True:
            if self.pos >= len(text):
                raise Error('unterminated string')
            ch = text[self.pos]
            self.pos += 1
            if ch == '"':
                break
            if ch == '\\':
                if self.pos >= len(text):
                    raise Error('bad escape')
                e = text[self.pos]
                self.pos += 1
                if e == 'n':
                    buf.append(10)
                elif e == 'r':
                    buf.append(13)
                elif e == 't':
                    buf.append(9)
                elif e == '"':
                    buf.append(34)
                elif e == '\\':
                    buf.append(92)
                elif e == 'x':
                    hh = text[self.pos:self.pos + 2]
                    if len(hh) != 2 or any(c not in '0123456789abcdefABCDEF' for c in hh):
                        raise Error('bad hex escape')
                    buf.append(int(hh, 16))
                    self.pos += 2
                else:
                    raise Error('bad escape')
            elif ord(ch) < 0x20:
                raise Error('control char in string')
            else:
                buf += ch.encode('utf-8')
        try:
            return buf.decode('utf-8')
        except UnicodeDecodeError:
            raise Error('bad utf-8')

    def parse_top(self, mtype):
        values = self.parse_message(mtype)
        self.skip_spaces()
        if self.pos != len(self.text):
            raise Error('trailing text')
        return values


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def handle(messages, line):
    if line.startswith('decode '):
        # Exactly `decode <Name>` or `decode <Name> <hex>`; a trailing space
        # (an empty third token) or any further token is an error.
        parts = line.split(' ')
        if len(parts) > 3 or (len(parts) == 3 and parts[2] == ''):
            raise Error('bad request')
        mtype = parts[1]
        hexstr = parts[2] if len(parts) > 2 else ''
        if len(hexstr) % 2 or any(c not in '0123456789abcdef' for c in hexstr):
            raise Error('bad hex')
        data = bytes.fromhex(hexstr)
        values = decode_message(messages, mtype, data, 0, len(data))
        return render_message(messages, mtype, values)
    if line.startswith('encode '):
        parts = line.split(' ', 2)
        if len(parts) < 3:
            raise Error('bad request')
        mtype = parts[1]
        values = TextParser(messages, parts[2]).parse_top(mtype)
        out = bytearray()
        encode_message(messages, mtype, values, out)
        return out.hex()
    raise Error('bad request')


def main():
    sys.setrecursionlimit(10000)
    data = sys.stdin.buffer.read().decode('utf-8')
    sep = data.index('\n--\n') if not data.startswith('--\n') else -1
    if sep < 0:
        schema_text, rest = '', data[3:]
    else:
        schema_text, rest = data[:sep], data[sep + 4:]
    messages = parse_schema(schema_text)
    out = []
    for line in rest.split('\n'):
        if line == '':
            continue
        try:
            out.append(handle(messages, line))
        except Error:
            out.append('error')
    sys.stdout.write('\n'.join(out) + ('\n' if out else ''))


if __name__ == '__main__':
    main()
