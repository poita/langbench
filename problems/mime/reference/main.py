#!/usr/bin/env python3
"""Reference implementation of the `mime` problem.

Parses an mbox file or a directory of .eml files as RFC 5322 / RFC 2045-2047
email and writes the normalised dump described in SPEC.md.

Only the Python standard library is used, and nothing from the `email`,
`mailbox`, `base64`, `quopri`, `binascii` or `zlib` packages: every decoder
is written out here so that the reference exercises the same work an
implementation in another language has to do.
"""
import os
import sys

# ---------------------------------------------------------------------------
# Character sets
# ---------------------------------------------------------------------------

CP1252_HIGH = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
]

ASCII_NAMES = {'us-ascii', 'ascii', 'iso-ir-6', 'ansi_x3.4-1968', 'iso646-us'}
UTF8_NAMES = {'utf-8', 'utf8', 'unicode-1-1-utf-8'}
LATIN1_NAMES = {'iso-8859-1', 'iso8859-1', 'latin-1', 'latin1', 'l1', '8859-1',
                'iso_8859-1'}
CP1252_NAMES = {'windows-1252', 'cp1252', 'windows1252', 'ansi'}


def norm_charset(name):
    """Normalise a charset name: strip blanks and lower-case it."""
    return name.strip(' \t').lower()


def decode_utf8(data):
    """UTF-8 decoding with U+FFFD for each maximal invalid subpart."""
    out = []
    i = 0
    n = len(data)
    while i < n:
        b0 = data[i]
        if b0 < 0x80:
            out.append(chr(b0))
            i += 1
            continue
        if 0xC2 <= b0 <= 0xDF:
            length, lo, hi = 2, 0x80, 0xBF
        elif b0 == 0xE0:
            length, lo, hi = 3, 0xA0, 0xBF
        elif 0xE1 <= b0 <= 0xEC:
            length, lo, hi = 3, 0x80, 0xBF
        elif b0 == 0xED:
            length, lo, hi = 3, 0x80, 0x9F
        elif 0xEE <= b0 <= 0xEF:
            length, lo, hi = 3, 0x80, 0xBF
        elif b0 == 0xF0:
            length, lo, hi = 4, 0x90, 0xBF
        elif 0xF1 <= b0 <= 0xF3:
            length, lo, hi = 4, 0x80, 0xBF
        elif b0 == 0xF4:
            length, lo, hi = 4, 0x80, 0x8F
        else:
            out.append('�')
            i += 1
            continue
        cp = b0 & (0x1F if length == 2 else (0x0F if length == 3 else 0x07))
        k = 1
        bad = False
        while k < length:
            if i + k >= n:
                bad = True
                break
            b = data[i + k]
            if k == 1:
                if not (lo <= b <= hi):
                    bad = True
                    break
            elif not (0x80 <= b <= 0xBF):
                bad = True
                break
            cp = (cp << 6) | (b & 0x3F)
            k += 1
        if bad:
            out.append('�')
            i += k
            continue
        out.append(chr(cp))
        i += length
    return ''.join(out)


def decode(data, charset):
    """Decode bytes with a named charset (see SPEC.md)."""
    cs = norm_charset(charset)
    if cs in UTF8_NAMES:
        return decode_utf8(data)
    if cs in ASCII_NAMES:
        return ''.join(chr(b) if b < 0x80 else '�' for b in data)
    if cs in LATIN1_NAMES:
        return ''.join(chr(b) for b in data)
    # CP1252_NAMES and every unrecognised name share the cp1252 table.
    return ''.join(chr(b) if b < 0x80 or b >= 0xA0 else chr(CP1252_HIGH[b - 0x80])
                   for b in data)


# ---------------------------------------------------------------------------
# Transfer decoding
# ---------------------------------------------------------------------------

B64_ALPHABET = ('ABCDEFGHIJKLMNOPQRSTUVWXYZ'
                'abcdefghijklmnopqrstuvwxyz0123456789+/')
B64_VALUE = {c: i for i, c in enumerate(B64_ALPHABET)}


def decode_base64(data):
    """Decode base64, ignoring every character outside the alphabet."""
    if isinstance(data, bytes):
        data = data.decode('latin-1')
    vals = [B64_VALUE[c] for c in data if c in B64_VALUE]
    out = bytearray()
    n = len(vals)
    full = n - (n % 4)
    for i in range(0, full, 4):
        acc = (vals[i] << 18) | (vals[i + 1] << 12) | (vals[i + 2] << 6) | vals[i + 3]
        out.append((acc >> 16) & 0xFF)
        out.append((acc >> 8) & 0xFF)
        out.append(acc & 0xFF)
    rem = n - full
    if rem == 2:
        acc = (vals[full] << 6) | vals[full + 1]
        out.append((acc >> 4) & 0xFF)
    elif rem == 3:
        acc = (vals[full] << 12) | (vals[full + 1] << 6) | vals[full + 2]
        out.append((acc >> 10) & 0xFF)
        out.append((acc >> 2) & 0xFF)
    return bytes(out)


HEX_DIGITS = '0123456789abcdefABCDEF'


def is_digits(s):
    """True when s is a non-empty run of ASCII digits."""
    return bool(s) and all('0' <= c <= '9' for c in s)


def is_hex(ch):
    return ch in HEX_DIGITS


def decode_qp(data):
    """Decode quoted-printable body bytes."""
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        b = data[i]
        if b != 0x3D:
            out.append(b)
            i += 1
            continue
        if i + 1 < n and data[i + 1] == 0x0A:
            i += 2
            continue
        if (i + 2 < n and is_hex(chr(data[i + 1])) and is_hex(chr(data[i + 2]))):
            out.append(int(chr(data[i + 1]) + chr(data[i + 2]), 16))
            i += 3
            continue
        if i + 1 == n:
            i += 1
            continue
        out.append(b)
        i += 1
    return bytes(out)


def decode_body(data, encoding):
    if encoding == 'base64':
        return decode_base64(data)
    if encoding == 'quoted-printable':
        return decode_qp(data)
    return data


def adler32(data):
    a, b = 1, 0
    for x in data:
        a = (a + x) % 65521
        b = (b + a) % 65521
    return (b << 16) | a


# ---------------------------------------------------------------------------
# RFC 2047 encoded words
# ---------------------------------------------------------------------------

def q_decode(text):
    out = bytearray()
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '_':
            out.append(0x20)
            i += 1
        elif c == '=' and i + 3 <= n and is_hex(text[i + 1]) and is_hex(text[i + 2]):
            out.append(int(text[i + 1:i + 3], 16))
            i += 3
        else:
            out.extend(c.encode('utf-8'))
            i += 1
    return bytes(out)


def scan_encoded_word(v, i):
    """Return (end, text) when a valid encoded word starts at v[i], else None."""
    if not v.startswith('=?', i):
        return None
    j = v.find('?', i + 2)
    if j < 0:
        return None
    charset_field = v[i + 2:j]
    if not charset_field or ' ' in charset_field or '\t' in charset_field:
        return None
    if j + 2 >= len(v) or v[j + 1] not in 'QqBb' or v[j + 2] != '?':
        return None
    m = v.find('?', j + 3)
    if m < 0:
        return None
    text = v[j + 3:m]
    if ' ' in text or '\t' in text:
        return None
    if m + 1 >= len(v) or v[m + 1] != '=':
        return None
    charset = charset_field.split('*')[0].strip(' \t').lower() or 'us-ascii'
    raw = q_decode(text) if v[j + 1] in 'Qq' else decode_base64(text)
    return m + 2, decode(raw, charset)


# Item kinds used when assembling an unstructured value or a phrase.
ENCODED, LITERAL, SPACE = 0, 1, 2


def _join_items(items):
    """Join scanned items, dropping whitespace between two encoded words."""
    out = []
    for k, (kind, text) in enumerate(items):
        if kind == SPACE:
            prev = items[k - 1][0] if k > 0 else None
            nxt = items[k + 1][0] if k + 1 < len(items) else None
            if prev == ENCODED and nxt == ENCODED:
                continue
        out.append(text)
    return ''.join(out).strip(' \t')


def _scan_items(v, comments=False, quotes=False):
    """Split a header value into encoded / literal / whitespace items."""
    items = []
    buf = []

    def flush():
        if buf:
            items.append((LITERAL, ''.join(buf)))
            del buf[:]

    i = 0
    n = len(v)
    while i < n:
        c = v[i]
        if c in ' \t':
            flush()
            j = i
            while j < n and v[j] in ' \t':
                j += 1
            items.append((SPACE, v[i:j]))
            i = j
            continue
        if comments and c == '(':
            flush()
            i = skip_comment(v, i)
            items.append((SPACE, ' '))
            continue
        if quotes and c == '"':
            flush()
            text, i = scan_quoted(v, i)
            items.append((LITERAL, text))
            continue
        r = scan_encoded_word(v, i)
        if r is not None:
            flush()
            items.append((ENCODED, r[1]))
            i = r[0]
            continue
        buf.append(c)
        i += 1
    flush()
    return items


def decode_unstructured(v):
    """Decode encoded words in an unstructured header value."""
    return _join_items(_scan_items(v))


def collapse(s):
    """Collapse runs of blanks to one space and strip the ends."""
    out = []
    run = False
    for ch in s:
        if ch in ' \t':
            run = True
            continue
        if run and out:
            out.append(' ')
        run = False
        out.append(ch)
    return ''.join(out).strip(' ')


# ---------------------------------------------------------------------------
# Quoted strings and comments
# ---------------------------------------------------------------------------

def scan_quoted(v, i):
    """Scan a quoted string starting at v[i] == '"'. Returns (text, end)."""
    i += 1
    n = len(v)
    buf = []
    while i < n:
        c = v[i]
        if c == '\\' and i + 1 < n:
            buf.append(v[i + 1])
            i += 2
            continue
        if c == '"':
            i += 1
            break
        buf.append(c)
        i += 1
    return ''.join(buf), i


def skip_comment(v, i):
    """Skip a comment starting at v[i] == '('. Returns the index after it."""
    n = len(v)
    depth = 0
    while i < n:
        c = v[i]
        if c == '\\':
            i += 2
            continue
        i += 1
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                break
    return i


# ---------------------------------------------------------------------------
# Structured values: Content-Type, Content-Disposition, RFC 2231
# ---------------------------------------------------------------------------

def split_segments(v):
    """Split a structured value at top-level semicolons."""
    segs = []
    start = 0
    i = 0
    n = len(v)
    while i < n:
        c = v[i]
        if c == '"':
            _, i = scan_quoted(v, i)
            continue
        if c == ';':
            segs.append(v[start:i])
            i += 1
            start = i
            continue
        i += 1
    segs.append(v[start:])
    return segs


def parse_structured(v):
    """Return (value proper, ordered list of (raw name, value)) for a header."""
    segs = split_segments(v)
    params = []
    for seg in segs[1:]:
        eq = seg.find('=')
        if eq < 0:
            continue
        name = seg[:eq].strip(' \t').lower()
        rest = seg[eq + 1:].strip(' \t')
        if rest.startswith('"'):
            rest, _ = scan_quoted(rest, 0)
        params.append((name, rest))
    return segs[0], params


def percent_decode(s):
    out = bytearray()
    i = 0
    n = len(s)
    while i < n:
        if s[i] == '%' and i + 3 <= n and is_hex(s[i + 1]) and is_hex(s[i + 2]):
            out.append(int(s[i + 1:i + 3], 16))
            i += 3
        else:
            out.extend(s[i].encode('utf-8'))
            i += 1
    return bytes(out)


def split_extended(value):
    """Split charset'language'text; returns (charset, text)."""
    first = value.find("'")
    if first < 0:
        return 'us-ascii', value
    second = value.find("'", first + 1)
    if second < 0:
        return 'us-ascii', value
    return value[:first] or 'us-ascii', value[second + 1:]


def assemble_params(raw_params):
    """Apply RFC 2231 assembly to the raw parameter list."""
    plain = {}
    extended = {}
    segments = {}
    for name, value in raw_params:
        star = name.endswith('*')
        base = name[:-1] if star else name
        cut = base.rfind('*')
        index = None
        if cut > 0 and is_digits(base[cut + 1:]):
            index = int(base[cut + 1:])
            base = base[:cut]
        if index is not None:
            segments.setdefault(base, {}).setdefault(index, (value, star))
        elif star:
            if base not in extended:
                extended[base] = value
        else:
            if name not in plain:
                plain[name] = value
    out = {}
    for base, plain_value in plain.items():
        out[base] = decode_unstructured(plain_value)
    for base, value in extended.items():
        charset, text = split_extended(value)
        out[base] = decode(percent_decode(text), charset)
    for base, parts in segments.items():
        charset = 'us-ascii'
        if 0 in parts and parts[0][1]:
            charset, _ = split_extended(parts[0][0])
        data = bytearray()
        for index in sorted(parts):
            value, star = parts[index]
            if star:
                if index == 0:
                    _, value = split_extended(value)
                data.extend(percent_decode(value))
            else:
                data.extend(value.encode('utf-8'))
        out[base] = decode(bytes(data), charset)
    return out


TOKEN_STOP = set(' \t()<>@,;:\\"/[]?=')


def valid_mime_type(value):
    slash = value.find('/')
    if slash <= 0 or slash == len(value) - 1:
        return False
    for part in (value[:slash], value[slash + 1:]):
        if not part or any(c in TOKEN_STOP for c in part):
            return False
    return True


# ---------------------------------------------------------------------------
# Addresses
# ---------------------------------------------------------------------------

ADDR_SPECIALS = '<>@,:;.'
ATOM_STOP = set(' \t()<>[]@,:;."\\')


def tokenize_address(v):
    """Tokenise an address list. Returns (kind, text, start, end) tuples."""
    toks = []
    i = 0
    n = len(v)
    while i < n:
        c = v[i]
        if c in ' \t':
            i += 1
            continue
        if c == '(':
            i = skip_comment(v, i)
            continue
        if c == '"':
            text, j = scan_quoted(v, i)
            toks.append(('QUOTED', text, i, j))
            i = j
            continue
        if c == '[':
            start = i
            i += 1
            while i < n:
                if v[i] == '\\':
                    i += 2
                    continue
                if v[i] == ']':
                    i += 1
                    break
                i += 1
            toks.append(('LITERAL', v[start:i], start, i))
            continue
        r = scan_encoded_word(v, i)
        if r is not None:
            toks.append(('ENCODED', r[1], i, r[0]))
            i = r[0]
            continue
        if c in ADDR_SPECIALS:
            toks.append(('SPECIAL', c, i, i + 1))
            i += 1
            continue
        if c in ')]\\':
            toks.append(('ATOM', c, i, i + 1))
            i += 1
            continue
        start = i
        while i < n and v[i] not in ATOM_STOP:
            i += 1
        toks.append(('ATOM', v[start:i], start, i))
    return toks


def split_elements(toks):
    """Split a token list at top-level commas."""
    elements = []
    current = []
    angle = 0
    for tok in toks:
        if tok[0] == 'SPECIAL':
            if tok[1] == '<':
                angle += 1
            elif tok[1] == '>':
                angle = max(0, angle - 1)
            elif tok[1] == ',' and angle == 0:
                elements.append(current)
                current = []
                continue
        current.append(tok)
    elements.append(current)
    return elements


def render_dotted(toks, allow_quoted):
    """Render a dot-separated run of atoms (and quoted strings)."""
    if not toks:
        return None
    parts = []
    expect = True
    for kind, text, _s, _e in toks:
        if expect:
            if kind == 'ATOM' or (allow_quoted and kind == 'QUOTED'):
                parts.append(text)
                expect = False
            else:
                return None
        else:
            if kind == 'SPECIAL' and text == '.':
                expect = True
            else:
                return None
    if expect:
        return None
    return '.'.join(parts)


def render_addr_spec(toks):
    """Render an addr-spec token run, or None when it does not parse."""
    if not toks:
        return None
    at = None
    for k, tok in enumerate(toks):
        if tok[0] == 'SPECIAL' and tok[1] == '@':
            at = k
            break
    if at is None:
        local = render_dotted(toks, True)
        return local
    local = render_dotted(toks[:at], True)
    if local is None:
        return None
    domain_toks = toks[at + 1:]
    if len(domain_toks) == 1 and domain_toks[0][0] == 'LITERAL':
        domain = domain_toks[0][1]
    else:
        domain = render_dotted(domain_toks, False)
    if domain is None:
        return None
    return local + '@' + domain


def render_phrase(src):
    """Render a display name from its source text."""
    return _join_items(_scan_items(src, comments=True, quotes=True))


def parse_address_list(v):
    """Parse an address list into (display name, addr-spec) pairs."""
    out = []
    for element in split_elements(tokenize_address(v)):
        # Drop a group name and its colon, and any trailing semicolons.
        for k, tok in enumerate(element):
            if tok[0] == 'SPECIAL' and tok[1] in ':<@':
                if tok[1] == ':':
                    element = element[k + 1:]
                break
        while element and element[-1][0] == 'SPECIAL' and element[-1][1] == ';':
            element = element[:-1]
        if not element:
            continue
        angle = None
        for k, tok in enumerate(element):
            if tok[0] == 'SPECIAL' and tok[1] == '<':
                angle = k
                break
        spec = None
        display = ''
        if angle is not None:
            close = None
            for k in range(len(element) - 1, angle, -1):
                if element[k][0] == 'SPECIAL' and element[k][1] == '>':
                    close = k
                    break
            if close is not None:
                spec = render_addr_spec(element[angle + 1:close])
                if spec is not None:
                    display = render_phrase(v[element[0][2]:element[angle][2]])
        else:
            spec = render_addr_spec(element)
        if spec is None:
            spec = ''.join(tok[1] for tok in element)
            display = ''
        out.append((display, spec))
    return out


# ---------------------------------------------------------------------------
# Dates
# ---------------------------------------------------------------------------

MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun',
          'jul', 'aug', 'sep', 'oct', 'nov', 'dec']
WEEKDAYS = {'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'}
NAMED_ZONES = {'ut': 0, 'gmt': 0, 'z': 0, 'est': -300, 'edt': -240,
               'cst': -360, 'cdt': -300, 'mst': -420, 'mdt': -360,
               'pst': -480, 'pdt': -420}


def days_from_civil(y, m, d):
    """Days between 1970-01-01 and the given proleptic Gregorian date."""
    y -= 1 if m <= 2 else 0
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def civil_from_days(z):
    z += 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + (3 if mp < 10 else -9)
    return (y + (1 if m <= 2 else 0)), m, d


def is_leap(y):
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)


DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]


def strip_comments(v):
    out = []
    i = 0
    n = len(v)
    while i < n:
        if v[i] == '(':
            i = skip_comment(v, i)
            continue
        out.append(v[i])
        i += 1
    return ''.join(out)


def parse_date(v):
    """Parse a Date header value; returns (epoch, offset_minutes) or None."""
    toks = []
    for chunk in strip_comments(v).replace(',', ' ').replace('\t', ' ').split(' '):
        if chunk:
            toks.append(chunk)
    if toks and toks[0].lower() in WEEKDAYS:
        toks = toks[1:]
    if len(toks) < 4:
        return None
    day_s, month_s, year_s, time_s = toks[0], toks[1], toks[2], toks[3]
    zone_s = toks[4] if len(toks) > 4 else ''
    if not (1 <= len(day_s) <= 2) or not is_digits(day_s):
        return None
    day = int(day_s)
    if month_s.lower() not in MONTHS:
        return None
    month = MONTHS.index(month_s.lower()) + 1
    if not is_digits(year_s) or not (2 <= len(year_s) <= 4):
        return None
    year = int(year_s)
    if len(year_s) == 2:
        year = 1900 + year if year >= 50 else 2000 + year
    elif len(year_s) == 3:
        year = 1900 + year
    if not (1 <= year <= 9999):
        return None
    fields = time_s.split(':')
    if len(fields) not in (2, 3):
        return None
    for f in fields:
        if not is_digits(f) or not (1 <= len(f) <= 2):
            return None
    hh, mm = int(fields[0]), int(fields[1])
    ss = int(fields[2]) if len(fields) == 3 else 0
    if hh > 23 or mm > 59 or ss > 60:
        return None
    limit = DAYS_IN_MONTH[month - 1]
    if month == 2 and is_leap(year):
        limit = 29
    if day < 1 or day > limit:
        return None
    offset = 0
    if zone_s:
        if zone_s[0] in '+-' and len(zone_s) == 5 and is_digits(zone_s[1:]):
            magnitude = int(zone_s[1:3]) * 60 + int(zone_s[3:5])
            offset = -magnitude if zone_s[0] == '-' else magnitude
        else:
            offset = NAMED_ZONES.get(zone_s.lower(), 0)
    epoch = days_from_civil(year, month, day) * 86400 + hh * 3600 + mm * 60 + ss
    return epoch - offset * 60, offset


def format_utc(epoch):
    days, rem = divmod(epoch, 86400)
    y, m, d = civil_from_days(days)
    hh, rem = divmod(rem, 3600)
    mm, ss = divmod(rem, 60)
    return '%04d-%02d-%02dT%02d:%02d:%02dZ' % (y, m, d, hh, mm, ss)


def format_offset(minutes):
    sign = '-' if minutes < 0 else '+'
    magnitude = abs(minutes)
    return '%s%02d%02d' % (sign, magnitude // 60, magnitude % 60)


# ---------------------------------------------------------------------------
# Message parsing
# ---------------------------------------------------------------------------

class Part:
    def __init__(self):
        self.index = 0
        self.depth = 0
        self.raw = b''            # the part's own bytes
        self.body = b''           # the bytes after the header block
        self.fields = []          # (name, raw value) in message order
        self.ctype = 'text/plain'
        self.ct_params = {}
        self.cd_params = {}
        self.has_cd = False
        self.disposition = 'inline'
        self.cte = '7bit'
        self.kind = 'leaf'        # leaf | multipart | message
        self.children = []
        self.content = b''
        self.preamble = 0
        self.epilogue = None
        self.boundary = None
        self.filename = None
        self.role = 'attachment'


def field_colon(line):
    """The colon position when the line starts a header field, else None.

    A field name is one or more printable ASCII characters other than `:`
    and SPACE.
    """
    colon = line.find(b':')
    if colon <= 0:
        return None
    for b in line[:colon]:
        if not (0x21 <= b <= 0x39 or 0x3B <= b <= 0x7E):
            return None
    return colon


def split_message(data):
    """Split a message into its header fields and its body bytes."""
    fields = []
    current = None
    pos = 0
    n = len(data)
    body_start = n
    index = 0
    while pos < n:
        nl = data.find(b'\n', pos)
        end = n if nl < 0 else nl
        nxt = n if nl < 0 else nl + 1
        line = data[pos:end]
        if not line:
            body_start = nxt
            break
        if index > 0 and current is not None and line[:1] in (b' ', b'\t'):
            current.append(line)
        elif field_colon(line) is not None:
            if current is not None:
                fields.append(current)
            current = [line]
        else:
            body_start = pos
            break
        index += 1
        pos = nxt
    if current is not None:
        fields.append(current)
    out = []
    for lines in fields:
        text = decode_utf8(b''.join(lines))
        colon = text.find(':')
        out.append((text[:colon], text[colon + 1:]))
    return out, data[body_start:]


def find_field(fields, name):
    for field_name, value in fields:
        if field_name.strip(' \t').lower() == name:
            return value
    return None


def delimiter_kind(line, marker):
    """Return None, 'open' or 'close' for a candidate boundary line."""
    if not line.startswith(marker):
        return None
    rest = line[len(marker):]
    close = False
    if rest.startswith(b'--'):
        close = True
        rest = rest[2:]
    if rest.strip(b' \t'):
        return None
    return 'close' if close else 'open'


def split_multipart(body, boundary):
    """Split a multipart body. Returns (preamble, parts, epilogue)."""
    marker = b'--' + boundary.encode('utf-8', 'surrogateescape')
    lines = []
    pos = 0
    n = len(body)
    while pos < n:
        nl = body.find(b'\n', pos)
        end = n if nl < 0 else nl
        nxt = n if nl < 0 else nl + 1
        lines.append((pos, end, nxt))
        pos = nxt
    delims = []
    for start, end, nxt in lines:
        kind = delimiter_kind(body[start:end], marker)
        if kind is not None:
            delims.append((start, nxt, kind))
    if not delims:
        return body, [], None
    first_start, first_next, first_kind = delims[0]
    preamble = body[:first_start]
    if preamble.endswith(b'\n'):
        preamble = preamble[:-1]
    if first_kind == 'close':
        return preamble, [], body[first_next:]
    parts = []
    epilogue = None
    for k in range(len(delims)):
        start, nxt, kind = delims[k]
        if kind == 'close':
            epilogue = body[nxt:]
            break
        stop = delims[k + 1][0] if k + 1 < len(delims) else n
        chunk = body[nxt:stop]
        if chunk.endswith(b'\n'):
            chunk = chunk[:-1]
        parts.append(chunk)
    return preamble, parts, epilogue


def parse_part(data, default_type, state):
    """Parse one part, numbering it and its children in pre-order."""
    part = Part()
    part.index = state['next']
    state['next'] += 1
    part.depth = state['depth']
    part.raw = data
    part.fields, body = split_message(data)
    part.body = body

    raw_ct = find_field(part.fields, 'content-type')
    if raw_ct is not None:
        value, raw_params = parse_structured(raw_ct)
        part.ct_params = assemble_params(raw_params)
        value = value.strip(' \t').lower()
        part.ctype = value if valid_mime_type(value) else default_type
    else:
        part.ctype = default_type

    raw_cd = find_field(part.fields, 'content-disposition')
    if raw_cd is not None:
        part.has_cd = True
        value, raw_params = parse_structured(raw_cd)
        part.cd_params = assemble_params(raw_params)
        part.disposition = value.strip(' \t').lower() or 'inline'

    raw_cte = find_field(part.fields, 'content-transfer-encoding')
    if raw_cte is not None:
        value, _ = parse_structured(raw_cte)
        part.cte = value.strip(' \t').lower()

    if 'filename' in part.cd_params:
        part.filename = part.cd_params['filename']
    elif 'name' in part.ct_params:
        part.filename = part.ct_params['name']

    maintype = part.ctype.split('/')[0]
    boundary = part.ct_params.get('boundary')
    if maintype == 'multipart' and boundary:
        part.kind = 'multipart'
        part.boundary = boundary
        preamble, chunks, epilogue = split_multipart(body, boundary)
        part.preamble = len(preamble)
        part.epilogue = None if epilogue is None else len(epilogue)
        child_default = ('message/rfc822' if part.ctype == 'multipart/digest'
                         else 'text/plain')
        state['depth'] += 1
        for chunk in chunks:
            part.children.append(parse_part(chunk, child_default, state))
        state['depth'] -= 1
    elif part.ctype == 'message/rfc822':
        part.kind = 'message'
        state['depth'] += 1
        part.children.append(
            parse_part(decode_body(body, part.cte), 'text/plain', state))
        state['depth'] -= 1
    else:
        part.kind = 'leaf'
        part.content = decode_body(body, part.cte)
    return part


def walk(part):
    yield part
    for child in part.children:
        yield from walk(child)


def charset_of(part):
    if 'charset' in part.ct_params:
        return norm_charset(part.ct_params['charset'])
    return 'us-ascii'


def select_bodies(root):
    """Choose the text and html bodies; returns (text part, html part)."""
    text_part = None
    html_part = None

    def visit(part):
        nonlocal text_part, html_part
        if part.kind == 'leaf':
            if not (part.has_cd and part.disposition == 'attachment'):
                if part.ctype == 'text/plain' and text_part is None:
                    text_part = part
                elif part.ctype == 'text/html' and html_part is None:
                    html_part = part
            return
        if part.kind == 'message':
            return
        for child in part.children:
            visit(child)

    visit(root)
    return text_part, html_part


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

NO_DECODE = {'content-disposition', 'content-id', 'content-transfer-encoding',
             'content-type', 'date', 'in-reply-to', 'message-id',
             'mime-version', 'received', 'references', 'return-path'}

ADDRESS_FIELDS = ['from', 'sender', 'reply-to', 'to', 'cc', 'bcc']

SIMPLE_ESCAPES = {'\\': '\\\\', '\n': '\\n', '\r': '\\r', '\t': '\\t',
                  '"': '\\"'}


def esc(s):
    out = []
    for ch in s:
        if ch in SIMPLE_ESCAPES:
            out.append(SIMPLE_ESCAPES[ch])
            continue
        cp = ord(ch)
        if cp < 0x20 or cp == 0x7F or 0x80 <= cp <= 0x9F:
            out.append('\\x%02x' % cp)
        else:
            out.append(ch)
    return ''.join(out)


def q(s):
    return '"' + esc(s) + '"'


def structure_lines(part, text_part, html_part, out):
    attrs = []
    if part.ctype.startswith('text/'):
        attrs.append('charset=' + charset_of(part))
    attrs.append('cte=' + part.cte)
    if part.has_cd:
        attrs.append('disposition=' + part.disposition)
    if part.filename is not None:
        attrs.append('filename=' + q(part.filename))
    if part.kind == 'multipart':
        attrs.append('boundary=' + q(part.boundary))
    if part.kind in ('multipart', 'message'):
        attrs.append('parts=%d' % len(part.children))
    if part.kind == 'multipart':
        attrs.append('preamble=%d' % part.preamble)
        attrs.append('epilogue=' +
                     ('none' if part.epilogue is None else str(part.epilogue)))
    if part.kind == 'leaf':
        attrs.append('size=%d' % len(part.content))
        attrs.append('adler32=%08x' % adler32(part.content))
        role = ('text' if part is text_part else
                'html' if part is html_part else 'attachment')
        attrs.append('role=' + role)
    out.append('%s%d %s %s' % ('  ' * part.depth, part.index, part.ctype,
                               ' '.join(attrs)))
    for child in part.children:
        structure_lines(child, text_part, html_part, out)


def body_lines(label, part, out):
    if part is None:
        out.append(label + ' none')
        return
    text = decode(part.content, charset_of(part))
    out.append('%s %d chars %d' % (label, part.index, len(text)))
    if text:
        pieces = text.split('\n')
        if pieces and pieces[-1] == '':
            pieces.pop()
        for line in pieces:
            out.append('| ' + esc(line))


def dump_message(number, source, root, text_part, html_part):
    """Build the message dump and the list of attachments."""
    out = ['[message]', 'id %04d' % number, 'source ' + q(source), '']

    out.append('[headers]')
    for name, value in root.fields:
        key = name.strip(' \t').lower()
        text = collapse(value) if key in NO_DECODE else decode_unstructured(value)
        out.append('%s: %s' % (key, q(text)))
    out.append('')

    out.append('[addresses]')
    for field in ADDRESS_FIELDS:
        counter = 0
        for name, value in root.fields:
            if name.strip(' \t').lower() != field:
                continue
            for display, spec in parse_address_list(value):
                out.append('%s %d display=%s spec=%s'
                           % (field, counter, q(display), q(spec)))
                counter += 1
    out.append('')

    out.append('[date]')
    raw_date = find_field(root.fields, 'date')
    if raw_date is None:
        out.append('none')
    else:
        out.append('raw ' + q(raw_date))
        parsed = parse_date(raw_date)
        if parsed is None:
            out.append('valid no')
        else:
            epoch, offset = parsed
            out.append('valid yes')
            out.append('utc ' + format_utc(epoch))
            out.append('offset ' + format_offset(offset))
            out.append('epoch %d' % epoch)
    out.append('')

    out.append('[structure]')
    structure_lines(root, text_part, html_part, out)
    out.append('')

    out.append('[body]')
    body_lines('text', text_part, out)
    body_lines('html', html_part, out)
    out.append('')

    out.append('[attachments]')
    attachments = []
    for part in walk(root):
        if part.kind != 'leaf' or part is text_part or part is html_part:
            continue
        path = 'parts/%04d/%03d.bin' % (number, part.index)
        attachments.append((path, part.content))
        out.append('%d type=%s filename=%s size=%d adler32=%08x file=%s'
                   % (part.index, part.ctype,
                      '-' if part.filename is None else q(part.filename),
                      len(part.content), adler32(part.content), path))
    return '\n'.join(out) + '\n', attachments


# ---------------------------------------------------------------------------
# Mailbox reading
# ---------------------------------------------------------------------------

def split_mbox(data):
    """Split an mbox file into message byte strings."""
    starts = []
    pos = 0
    n = len(data)
    previous_blank = True
    first = True
    while pos < n:
        nl = data.find(b'\n', pos)
        end = n if nl < 0 else nl
        nxt = n if nl < 0 else nl + 1
        line = data[pos:end]
        if line.startswith(b'From ') and (first or previous_blank):
            starts.append((pos, nxt))
        previous_blank = not line
        first = False
        pos = nxt
    messages = []
    for k, (start, after) in enumerate(starts):
        stop = starts[k + 1][0] if k + 1 < len(starts) else n
        chunk = data[after:stop]
        if chunk.endswith(b'\n\n'):
            chunk = chunk[:-1]
        messages.append(chunk)
    return messages


def read_mailbox(path):
    """Return a list of (source id, raw message bytes)."""
    if os.path.isdir(path):
        names = sorted((n for n in os.listdir(path) if n.endswith('.eml')),
                       key=lambda s: s.encode('utf-8', 'surrogateescape'))
        out = []
        for name in names:
            full = os.path.join(path, name)
            if not os.path.isfile(full):
                continue
            with open(full, 'rb') as f:
                out.append((name, f.read()))
        return out
    with open(path, 'rb') as f:
        data = f.read()
    return [('mbox:%d' % (i + 1), m) for i, m in enumerate(split_mbox(data))]


def main(argv):
    if len(argv) != 3:
        sys.stderr.write('usage: main.py <input> <output dir>\n')
        return 2
    in_path, out_dir = argv[1], argv[2]
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(os.path.join(out_dir, 'messages'), exist_ok=True)

    messages = read_mailbox(in_path)
    summary = ['messages %d' % len(messages)]
    for number, (source, raw) in enumerate(messages, start=1):
        data = raw.replace(b'\r\n', b'\n')
        state = {'next': 0, 'depth': 0}
        root = parse_part(data, 'text/plain', state)
        text_part, html_part = select_bodies(root)
        dump, attachments = dump_message(number, source, root,
                                         text_part, html_part)
        with open(os.path.join(out_dir, 'messages', '%04d.txt' % number),
                  'w', encoding='utf-8', newline='\n') as f:
            f.write(dump)
        if attachments:
            os.makedirs(os.path.join(out_dir, 'parts', '%04d' % number),
                        exist_ok=True)
        for path, content in attachments:
            with open(os.path.join(out_dir, *path.split('/')), 'wb') as f:
                f.write(content)
        count = sum(1 for _ in walk(root))
        summary.append('%04d source=%s bytes=%d parts=%d attachments=%d '
                       'text=%s html=%s'
                       % (number, q(source), len(raw), count, len(attachments),
                          '-' if text_part is None else str(text_part.index),
                          '-' if html_part is None else str(html_part.index)))
    with open(os.path.join(out_dir, 'summary.txt'), 'w', encoding='utf-8',
              newline='\n') as f:
        f.write('\n'.join(summary) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
