#!/usr/bin/env python3
"""Reference implementation of the `webhooks` problem.

SHA-256, HMAC-SHA-256 and Base64 are written out here rather than taken from
the standard library, because they are what the problem asks an implementer to
build. On top of them sit the Standard Webhooks signature scheme and a
discrete-event delivery simulator.
"""
import heapq
import sys

# ---------------------------------------------------------------------------
# SHA-256 (FIPS 180-4)
# ---------------------------------------------------------------------------

_K = [
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1,
    0x923F82A4, 0xAB1C5ED5, 0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
    0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174, 0xE49B69C1, 0xEFBE4786,
    0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147,
    0x06CA6351, 0x14292967, 0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
    0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85, 0xA2BFE8A1, 0xA81A664B,
    0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A,
    0x5B9CCA4F, 0x682E6FF3, 0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
    0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
]

_H0 = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
       0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]

_MASK = 0xFFFFFFFF


def _ror(x, n):
    return ((x >> n) | (x << (32 - n))) & _MASK


def sha256(data):
    """Return the 32-byte SHA-256 digest of the byte string `data`."""
    bitlen = len(data) * 8
    msg = bytearray(data)
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0x00)
    msg += bitlen.to_bytes(8, 'big')

    h = list(_H0)
    w = [0] * 64
    for off in range(0, len(msg), 64):
        block = msg[off:off + 64]
        for t in range(16):
            i = t * 4
            w[t] = (block[i] << 24) | (block[i + 1] << 16) | (block[i + 2] << 8) | block[i + 3]
        for t in range(16, 64):
            x, y = w[t - 15], w[t - 2]
            s0 = _ror(x, 7) ^ _ror(x, 18) ^ (x >> 3)
            s1 = _ror(y, 17) ^ _ror(y, 19) ^ (y >> 10)
            w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & _MASK

        a, b, c, d, e, f, g, hh = h
        for t in range(64):
            s1 = _ror(e, 6) ^ _ror(e, 11) ^ _ror(e, 25)
            ch = (e & f) ^ (~e & g)
            temp1 = (hh + s1 + ch + _K[t] + w[t]) & _MASK
            s0 = _ror(a, 2) ^ _ror(a, 13) ^ _ror(a, 22)
            maj = (a & b) ^ (a & c) ^ (b & c)
            temp2 = (s0 + maj) & _MASK
            hh, g, f = g, f, e
            e = (d + temp1) & _MASK
            d, c, b = c, b, a
            a = (temp1 + temp2) & _MASK
        for i, v in enumerate((a, b, c, d, e, f, g, hh)):
            h[i] = (h[i] + v) & _MASK

    out = bytearray()
    for v in h:
        out += v.to_bytes(4, 'big')
    return bytes(out)


# ---------------------------------------------------------------------------
# HMAC-SHA-256 (RFC 2104)
# ---------------------------------------------------------------------------

_BLOCK = 64


def hmac_sha256(key, msg):
    """Return the 32-byte HMAC-SHA-256 of `msg` under `key`."""
    if len(key) > _BLOCK:
        key = sha256(key)
    key = key + b'\x00' * (_BLOCK - len(key))
    ipad = bytes(b ^ 0x36 for b in key)
    opad = bytes(b ^ 0x5C for b in key)
    return sha256(opad + sha256(ipad + msg))


# ---------------------------------------------------------------------------
# Base64
# ---------------------------------------------------------------------------

_STD = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
_URL = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
_STD_INDEX = {ord(c): i for i, c in enumerate(_STD)}
_URL_INDEX = {ord(c): i for i, c in enumerate(_URL)}
_PLUS_SLASH = (ord('+'), ord('/'))
_PAD = ord('=')


def _b64_encode(data, alphabet, pad):
    out = []
    for i in range(0, len(data), 3):
        chunk = data[i:i + 3]
        n = len(chunk)
        v = chunk[0] << 16
        if n > 1:
            v |= chunk[1] << 8
        if n > 2:
            v |= chunk[2]
        out.append(alphabet[(v >> 18) & 63])
        out.append(alphabet[(v >> 12) & 63])
        if n > 1:
            out.append(alphabet[(v >> 6) & 63])
        elif pad:
            out.append('=')
        if n > 2:
            out.append(alphabet[v & 63])
        elif pad:
            out.append('=')
    return ''.join(out)


def b64_standard(data):
    return _b64_encode(data, _STD, True)


def b64_urlsafe(data):
    return _b64_encode(data, _URL, False)


def b64_decode(text):
    """Decode standard or URL-safe Base64 from a byte string.

    Returns the decoded bytes, or None when `text` is not valid Base64.
    """
    n_pad = 0
    while n_pad < len(text) and text[len(text) - 1 - n_pad] == _PAD:
        n_pad += 1
    body = text[:len(text) - n_pad]
    if _PAD in body or n_pad > 2:
        return None

    saw_std = saw_url = False
    values = []
    for c in body:
        if c in _STD_INDEX:
            if c in _PLUS_SLASH:
                saw_std = True
            values.append(_STD_INDEX[c])
        elif c in _URL_INDEX:
            saw_url = True
            values.append(_URL_INDEX[c])
        else:
            return None
    if saw_std and saw_url:
        return None

    n = len(values)
    if n % 4 == 1:
        return None
    if n_pad > 0 and (n % 4 == 0 or (4 - n % 4) % 4 != n_pad):
        return None

    out = bytearray()
    for i in range(0, n - n % 4, 4):
        v = (values[i] << 18) | (values[i + 1] << 12) | (values[i + 2] << 6) | values[i + 3]
        out += bytes(((v >> 16) & 255, (v >> 8) & 255, v & 255))
    rem = n % 4
    if rem == 2:
        out.append((values[n - 2] << 2 | values[n - 1] >> 4) & 255)
    elif rem == 3:
        out.append((values[n - 3] << 2 | values[n - 2] >> 4) & 255)
        out.append((values[n - 2] << 4 | values[n - 1] >> 2) & 255)
    return bytes(out)


# ---------------------------------------------------------------------------
# Field parsing
# ---------------------------------------------------------------------------

_HEX_DIGITS = set('0123456789abcdef')
_ID_CHARS = set(chr(c) for c in range(0x21, 0x7F))
_NAME_CHARS = set('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-')
MAX_INT = 10 ** 15
TOLERANCE = 300
SECRET_PREFIX = 'whsec_'
RETRY_DELAYS = [5, 300, 1800, 7200, 18000, 36000, 36000]
MAX_ATTEMPTS = len(RETRY_DELAYS) + 1


class BadField(Exception):
    pass


def parse_hex(field):
    """Decode a <hex> field; `-` means the empty byte string."""
    if field == '-':
        return b''
    if len(field) % 2 != 0 or len(field) == 0:
        raise BadField(field)
    for c in field:
        if c not in _HEX_DIGITS:
            raise BadField(field)
    return bytes.fromhex(field)


def to_hex(data):
    return data.hex() if data else '-'


def parse_int(field):
    """Parse a canonical decimal integer field."""
    body = field[1:] if field.startswith('-') else field
    if not body or not body.isdigit() or not body.isascii():
        raise BadField(field)
    if len(body) > 1 and body[0] == '0':
        raise BadField(field)
    if body == '0' and field.startswith('-'):
        raise BadField(field)
    value = int(field)
    if abs(value) > MAX_INT:
        raise BadField(field)
    return value


def parse_id(field, limit=256):
    if not 1 <= len(field) <= limit:
        raise BadField(field)
    for c in field:
        if c not in _ID_CHARS:
            raise BadField(field)
    return field


def parse_name(field, limit=64):
    """Parse an endpoint id, event id or event type."""
    if not 1 <= len(field) <= limit:
        raise BadField(field)
    for c in field:
        if c not in _NAME_CHARS:
            raise BadField(field)
    return field


def parse_secret(field):
    """Return the raw key bytes of one secret, or raise BadField."""
    if not 1 <= len(field) <= 512:
        raise BadField(field)
    for c in field:
        if c not in _ID_CHARS or c == ',':
            raise BadField(field)
    body = field[len(SECRET_PREFIX):] if field.startswith(SECRET_PREFIX) else field
    key = b64_decode(body.encode('ascii'))
    if key is None or not key:
        raise BadField(field)
    return key


def parse_secrets(field):
    parts = field.split(',')
    if not 1 <= len(parts) <= 16:
        raise BadField(field)
    return [parse_secret(p) for p in parts]


# ---------------------------------------------------------------------------
# Standard Webhooks signing and verification
# ---------------------------------------------------------------------------

def signed_content(msg_id, timestamp_text, body):
    return msg_id.encode('utf-8') + b'.' + timestamp_text.encode('ascii') + b'.' + body


def sign_one(key, msg_id, timestamp_text, body):
    return 'v1,' + b64_standard(hmac_sha256(key, signed_content(msg_id, timestamp_text, body)))


def sign_header(keys, msg_id, timestamp_text, body):
    return ' '.join(sign_one(k, msg_id, timestamp_text, body) for k in keys)


def verify(keys, msg_id, timestamp_text, now, header, body):
    """Return `ok <i> <j>` or `fail <reason>` per SPEC.md 2.3.

    `header` is the raw bytes of the received webhook-signature header.
    """
    tokens = header.split(b' ')
    if all(t == b'' for t in tokens):
        return 'fail missing-signature'
    try:
        timestamp = parse_int(timestamp_text)
    except BadField:
        return 'fail invalid-timestamp'
    if now - timestamp > TOLERANCE:
        return 'fail timestamp-too-old'
    if timestamp - now > TOLERANCE:
        return 'fail timestamp-too-new'

    content = signed_content(msg_id, timestamp_text, body)
    for i, key in enumerate(keys):
        expected = hmac_sha256(key, content)
        for j, token in enumerate(tokens):
            comma = token.find(b',')
            if comma < 0 or token[:comma] != b'v1':
                continue
            got = b64_decode(token[comma + 1:])
            if got is not None and got == expected:
                return f'ok {i} {j}'
    return 'fail no-match'


# ---------------------------------------------------------------------------
# Delivery simulator
# ---------------------------------------------------------------------------

class Endpoint:
    def __init__(self, ep_id, keys, filt, script):
        self.ep_id = ep_id
        self.keys = keys
        self.filter = filt          # None means "*"
        self.script = script        # list of ints, or None for a timeout
        self.cursor = 0
        self.disabled = False

    def matches(self, event_type):
        return self.filter is None or event_type in self.filter

    def next_response(self):
        index = min(self.cursor, len(self.script) - 1)
        self.cursor += 1
        return self.script[index]


class Delivery:
    def __init__(self, index, event, endpoint):
        self.index = index
        self.event = event
        self.endpoint = endpoint
        self.header = sign_header(endpoint.keys, event.ev_id, event.ts_text, event.body)
        self.attempts = 0
        self.last_ts = None
        self.status = None


class Event:
    def __init__(self, ev_id, ts, ts_text, event_type, body):
        self.ev_id = ev_id
        self.ts = ts
        self.ts_text = ts_text
        self.type = event_type
        self.body = body


def parse_script(field):
    parts = field.split(',')
    if not 1 <= len(parts) <= 64:
        raise BadField(field)
    script = []
    for part in parts:
        if part == 'timeout':
            script.append(None)
            continue
        if len(part) != 3 or not part.isdigit() or not part.isascii():
            raise BadField(field)
        code = int(part)
        if not 100 <= code <= 599:
            raise BadField(field)
        script.append(code)
    return script


def parse_filter(field):
    if field == '*':
        return None
    parts = field.split(',')
    if not 1 <= len(parts) <= 16:
        raise BadField(field)
    return set(parse_name(p) for p in parts)


def run_simulation(endpoints, events):
    """Return the output lines of a well-formed simulate block."""
    deliveries = []
    for event in events:
        for endpoint in endpoints:
            if endpoint.matches(event.type):
                deliveries.append(Delivery(len(deliveries), event, endpoint))

    queue = [(d.event.ts, d.index, 1) for d in deliveries]
    heapq.heapify(queue)

    attempt_lines = []
    while queue:
        ts, index, number = heapq.heappop(queue)
        delivery = deliveries[index]
        endpoint = delivery.endpoint
        if endpoint.disabled:
            delivery.status = 'disabled'
            continue

        response = endpoint.next_response()
        delivery.attempts = number
        delivery.last_ts = ts
        if response is None:
            outcome, code, retryable = 'timeout', '-', True
        elif 200 <= response <= 299:
            outcome, code, retryable = 'success', str(response), False
            delivery.status = 'delivered'
        elif response == 410:
            outcome, code, retryable = 'gone', '410', False
            delivery.status = 'failed'
            endpoint.disabled = True
        else:
            outcome, code, retryable = 'failure', str(response), True
        attempt_lines.append(
            f'attempt {len(attempt_lines) + 1} {delivery.event.ev_id} {endpoint.ep_id} '
            f'{number} {ts} {outcome} {code}')

        if retryable:
            if number >= MAX_ATTEMPTS:
                delivery.status = 'failed'
            else:
                heapq.heappush(queue, (ts + RETRY_DELAYS[number - 1], index, number + 1))

    lines = [f'sim {len(attempt_lines)} {len(deliveries)}']
    lines.extend(attempt_lines)
    for d in deliveries:
        last = '-' if d.last_ts is None else str(d.last_ts)
        lines.append(f'delivery {d.event.ev_id} {d.endpoint.ep_id} {d.status} '
                     f'{d.attempts} {last} {d.header}')
    return lines


def parse_simulate_block(reader):
    """Consume a simulate block. Return its output lines, or None if malformed."""
    endpoints = []
    events = []
    ep_ids = set()
    ev_ids = set()
    seen_event = False
    ok = True
    while True:
        line = reader.next_line()
        if line is None:
            return None
        if line == 'end':
            break
        if not ok:
            continue
        fields = line.split(' ')
        try:
            if fields[0] == 'endpoint':
                if seen_event or len(fields) != 5:
                    raise BadField(line)
                ep_id = parse_name(fields[1])
                if ep_id in ep_ids or len(endpoints) >= 64:
                    raise BadField(line)
                ep_ids.add(ep_id)
                endpoints.append(Endpoint(ep_id, parse_secrets(fields[2]),
                                          parse_filter(fields[3]), parse_script(fields[4])))
            elif fields[0] == 'event':
                if len(fields) != 5:
                    raise BadField(line)
                seen_event = True
                ev_id = parse_name(fields[1])
                if ev_id in ev_ids or len(events) >= 20000:
                    raise BadField(line)
                ev_ids.add(ev_id)
                events.append(Event(ev_id, parse_int(fields[2]), fields[2],
                                    parse_name(fields[3]), parse_hex(fields[4])))
            else:
                raise BadField(line)
        except BadField:
            ok = False
    if not ok or not endpoints:
        return None
    return run_simulation(endpoints, events)


# ---------------------------------------------------------------------------
# Command dispatch
# ---------------------------------------------------------------------------

class Reader:
    """Line source that skips blank lines."""

    def __init__(self, text):
        self.lines = text.split('\n')
        self.pos = 0

    def next_line(self):
        while self.pos < len(self.lines):
            line = self.lines[self.pos]
            self.pos += 1
            if line.strip(' ') == '':
                continue
            return line
        return None


def run_command(line, reader, out):
    fields = line.split(' ')
    name = fields[0]

    if name == 'simulate':
        if len(fields) != 1:
            out.append('error')
            return
        lines = parse_simulate_block(reader)
        out.extend(['error'] if lines is None else lines)
        return

    try:
        if name == 'sha256':
            if len(fields) != 2:
                raise BadField(line)
            out.append(sha256(parse_hex(fields[1])).hex())
        elif name == 'hmac':
            if len(fields) != 3:
                raise BadField(line)
            out.append(hmac_sha256(parse_hex(fields[1]), parse_hex(fields[2])).hex())
        elif name == 'b64enc':
            if len(fields) != 2:
                raise BadField(line)
            encoded = b64_standard(parse_hex(fields[1]))
            out.append(encoded if encoded else '-')
        elif name == 'b64urlenc':
            if len(fields) != 2:
                raise BadField(line)
            encoded = b64_urlsafe(parse_hex(fields[1]))
            out.append(encoded if encoded else '-')
        elif name == 'b64dec':
            if len(fields) != 2:
                raise BadField(line)
            decoded = b64_decode(parse_hex(fields[1]))
            if decoded is None:
                raise BadField(line)
            out.append(to_hex(decoded))
        elif name == 'secret':
            if len(fields) != 2:
                raise BadField(line)
            out.append(to_hex(parse_secret(fields[1])))
        elif name == 'sign':
            if len(fields) != 5:
                raise BadField(line)
            keys = parse_secrets(fields[1])
            msg_id = parse_id(fields[2])
            parse_int(fields[3])
            body = parse_hex(fields[4])
            out.append(sign_header(keys, msg_id, fields[3], body))
        elif name == 'verify':
            if len(fields) != 7:
                raise BadField(line)
            keys = parse_secrets(fields[1])
            msg_id = parse_id(fields[2])
            ts_text = parse_id(fields[3], 64)
            now = parse_int(fields[4])
            header = parse_hex(fields[5])
            body = parse_hex(fields[6])
            out.append(verify(keys, msg_id, ts_text, now, header, body))
        else:
            raise BadField(line)
    except BadField:
        out.append('error')


def main():
    text = sys.stdin.buffer.read().decode('utf-8', 'replace')
    reader = Reader(text)
    out = []
    while True:
        line = reader.next_line()
        if line is None:
            break
        run_command(line, reader, out)
    sys.stdout.write('\n'.join(out) + ('\n' if out else ''))


if __name__ == '__main__':
    main()
