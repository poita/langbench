#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `webhooks` problem.

Every case is either an embedded literal or the product of a seeded generator,
so re-running this script reproduces the suite byte for byte. Expected outputs
come from reference/main.py.

Three independent oracles then check every expected output before it is
written, and any disagreement aborts generation:

1. An independent re-implementation of the whole command stream lives in this
   file (`oracle_run`). It parses with regular expressions instead of character
   loops, hashes with `hashlib`/`hmac`, encodes with `base64`, and simulates
   deliveries with a linear scan over pending attempts instead of a heap. Its
   output must equal the reference's for every test, line for line.
2. `standardwebhooks` 1.1.0 from .oracle-venv signs and verifies every `sign`
   and `verify` command it is able to express, including the published spec
   test vector. Its clock is pinned so timestamp tolerance is exercised too.
   Commands it cannot express are skipped and counted: payloads that are not
   valid UTF-8 (its API takes `str`), non-canonical timestamps and signature
   headers whose tokens the library cannot split (it raises `ValueError` on a
   token without exactly one comma, and `binascii.Error` on a token whose
   value is not valid Base64, where this spec skips the token and keeps
   looking).
3. The NIST CAVP byte-oriented SHA-256 vectors in corpus/nist-sha256 carry
   their own expected digests; those are compared directly.
"""
import base64
import hashlib
import hmac
import json
import os
import shutil
import random
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
CORPUS = os.path.join(HERE, 'corpus')
REF = os.path.join(HERE, 'reference', 'main.py')
ORACLE_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".oracle-venv", "bin", "python")

TOLERANCE = 300
RETRY_DELAYS = [5, 300, 1800, 7200, 18000, 36000, 36000]
MAX_ATTEMPTS = 8

cases = []


def add(name, lines):
    cases.append((name, '\n'.join(lines) + '\n'))


def hexs(data):
    """Hex-encode a byte string the way a <hex> field spells it."""
    return data.hex() if data else '-'


# ---------------------------------------------------------------------------
# Oracle 1: an independent implementation of the command stream.
# ---------------------------------------------------------------------------

HEX_RE = re.compile(r'\A(?:-|(?:[0-9a-f]{2})+)\Z')
INT_RE = re.compile(r'\A(?:0|-?[1-9][0-9]*)\Z')
ID_RE = re.compile(r'\A[\x21-\x7e]{1,256}\Z')
TS_RE = re.compile(r'\A[\x21-\x7e]{1,64}\Z')
NAME_RE = re.compile(r'\A[A-Za-z0-9_.\-]{1,64}\Z')
SECRET_RE = re.compile(r'\A[\x21-\x7e]{1,512}\Z')
B64_RE = re.compile(rb'\A(?:[A-Za-z0-9+/]*|[A-Za-z0-9\-_]*)(=*)\Z')
CODE_RE = re.compile(r'\A[1-5][0-9][0-9]\Z')


class Bad(Exception):
    pass


def o_hex(field):
    if not HEX_RE.match(field):
        raise Bad()
    return b'' if field == '-' else bytes.fromhex(field)


def o_int(field):
    if not INT_RE.match(field) or abs(int(field)) > 10 ** 15:
        raise Bad()
    return int(field)


def o_b64decode(text):
    """Decode Base64 bytes, returning None when the input is not valid.

    The stdlib decoder does the work; the rules of SPEC.md 1.3 that the stdlib
    does not enforce (alphabet mixing, exact padding) are checked here first.
    """
    m = B64_RE.match(text)
    if not m:
        return None
    pad = len(m.group(1))
    n = len(text) - pad
    if n % 4 == 1 or pad > 2:
        return None
    if pad and (n % 4 == 0 or (4 - n % 4) % 4 != pad):
        return None
    body = text[:n].replace(b'-', b'+').replace(b'_', b'/')
    return base64.b64decode(body + b'=' * ((4 - n % 4) % 4))


def o_secret(field):
    if not SECRET_RE.match(field) or ',' in field:
        raise Bad()
    body = field[6:] if field.startswith('whsec_') else field
    key = o_b64decode(body.encode('ascii'))
    if not key:
        raise Bad()
    return key


def o_secrets(field):
    parts = field.split(',')
    if not 1 <= len(parts) <= 16:
        raise Bad()
    return [o_secret(p) for p in parts]


def o_content(msg_id, ts_text, body):
    return msg_id.encode('utf-8') + b'.' + ts_text.encode('ascii') + b'.' + body


def o_sign(keys, msg_id, ts_text, body):
    content = o_content(msg_id, ts_text, body)
    return ' '.join('v1,' + base64.b64encode(hmac.new(k, content, hashlib.sha256).digest()).decode()
                    for k in keys)


def o_verify(keys, msg_id, ts_text, now, header, body):
    tokens = header.split(b' ')
    if not any(tokens):
        return 'fail missing-signature'
    if not INT_RE.match(ts_text) or abs(int(ts_text)) > 10 ** 15:
        return 'fail invalid-timestamp'
    ts = int(ts_text)
    if now - ts > TOLERANCE:
        return 'fail timestamp-too-old'
    if ts - now > TOLERANCE:
        return 'fail timestamp-too-new'
    content = o_content(msg_id, ts_text, body)
    for i, key in enumerate(keys):
        want = hmac.new(key, content, hashlib.sha256).digest()
        for j, token in enumerate(tokens):
            version, sep, value = token.partition(b',')
            if not sep or version != b'v1':
                continue
            got = o_b64decode(value)
            if got is not None and hmac.compare_digest(got, want):
                return 'ok %d %d' % (i, j)
    return 'fail no-match'


def o_simulate(block):
    """Run a simulate block given its already-validated endpoints and events."""
    endpoints, events = block
    deliveries = []
    for event in events:
        for ep in endpoints:
            if ep['filter'] is None or event['type'] in ep['filter']:
                deliveries.append({
                    'event': event, 'ep': ep, 'attempts': 0, 'last': None,
                    'status': None,
                    'header': o_sign(ep['keys'], event['id'], event['ts_text'], event['body']),
                })

    # Pending attempts are kept in a plain list and the earliest is found by a
    # linear scan, which is a different mechanism from the reference's heap.
    pending = [[d['event']['ts'], i, 1] for i, d in enumerate(deliveries)]
    attempt_lines = []
    while pending:
        best = min(range(len(pending)), key=lambda k: (pending[k][0], pending[k][1]))
        ts, index, number = pending.pop(best)
        d = deliveries[index]
        ep = d['ep']
        if ep['disabled']:
            d['status'] = 'disabled'
            continue
        response = ep['script'][min(ep['cursor'], len(ep['script']) - 1)]
        ep['cursor'] += 1
        d['attempts'] = number
        d['last'] = ts
        retryable = False
        if response is None:
            outcome, code = 'timeout', '-'
            retryable = True
        elif 200 <= response <= 299:
            outcome, code = 'success', str(response)
            d['status'] = 'delivered'
        elif response == 410:
            outcome, code = 'gone', '410'
            d['status'] = 'failed'
            ep['disabled'] = True
        else:
            outcome, code = 'failure', str(response)
            retryable = True
        attempt_lines.append('attempt %d %s %s %d %d %s %s' % (
            len(attempt_lines) + 1, d['event']['id'], ep['id'], number, ts, outcome, code))
        if retryable:
            if number >= MAX_ATTEMPTS:
                d['status'] = 'failed'
            else:
                pending.append([ts + RETRY_DELAYS[number - 1], index, number + 1])

    lines = ['sim %d %d' % (len(attempt_lines), len(deliveries))]
    lines += attempt_lines
    for d in deliveries:
        lines.append('delivery %s %s %s %d %s %s' % (
            d['event']['id'], d['ep']['id'], d['status'], d['attempts'],
            '-' if d['last'] is None else str(d['last']), d['header']))
    return lines


def o_parse_block(reader):
    endpoints, events = [], []
    ep_ids, ev_ids = set(), set()
    seen_event = False
    ok = True
    while True:
        line = reader()
        if line is None:
            return None
        if line == 'end':
            break
        if not ok:
            continue
        f = line.split(' ')
        try:
            if f[0] == 'endpoint':
                if seen_event or len(f) != 5 or not NAME_RE.match(f[1]):
                    raise Bad()
                if f[1] in ep_ids or len(endpoints) >= 64:
                    raise Bad()
                ep_ids.add(f[1])
                keys = o_secrets(f[2])
                if f[3] == '*':
                    filt = None
                else:
                    parts = f[3].split(',')
                    if not 1 <= len(parts) <= 16 or not all(NAME_RE.match(p) for p in parts):
                        raise Bad()
                    filt = set(parts)
                script_parts = f[4].split(',')
                if not 1 <= len(script_parts) <= 64:
                    raise Bad()
                script = []
                for part in script_parts:
                    if part == 'timeout':
                        script.append(None)
                    elif CODE_RE.match(part):
                        script.append(int(part))
                    else:
                        raise Bad()
                endpoints.append({'id': f[1], 'keys': keys, 'filter': filt,
                                  'script': script, 'cursor': 0, 'disabled': False})
            elif f[0] == 'event':
                if len(f) != 5 or not NAME_RE.match(f[1]) or not NAME_RE.match(f[3]):
                    raise Bad()
                seen_event = True
                if f[1] in ev_ids or len(events) >= 20000:
                    raise Bad()
                ev_ids.add(f[1])
                events.append({'id': f[1], 'ts': o_int(f[2]), 'ts_text': f[2],
                               'type': f[3], 'body': o_hex(f[4])})
            else:
                raise Bad()
        except Bad:
            ok = False
    if not ok or not endpoints:
        return None
    return (endpoints, events)


def oracle_run(text):
    """Independently produce the expected output for a whole command stream."""
    raw = text.split('\n')
    pos = [0]

    def reader():
        while pos[0] < len(raw):
            line = raw[pos[0]]
            pos[0] += 1
            if line.strip(' ') == '':
                continue
            return line
        return None

    out = []
    while True:
        line = reader()
        if line is None:
            break
        f = line.split(' ')
        try:
            if f[0] == 'simulate':
                if len(f) != 1:
                    out.append('error')
                    continue
                block = o_parse_block(reader)
                out.extend(['error'] if block is None else o_simulate(block))
            elif f[0] == 'sha256':
                if len(f) != 2:
                    raise Bad()
                out.append(hashlib.sha256(o_hex(f[1])).hexdigest())
            elif f[0] == 'hmac':
                if len(f) != 3:
                    raise Bad()
                out.append(hmac.new(o_hex(f[1]), o_hex(f[2]), hashlib.sha256).hexdigest())
            elif f[0] == 'b64enc':
                if len(f) != 2:
                    raise Bad()
                data = o_hex(f[1])
                out.append(base64.b64encode(data).decode() if data else '-')
            elif f[0] == 'b64urlenc':
                if len(f) != 2:
                    raise Bad()
                data = o_hex(f[1])
                out.append(base64.urlsafe_b64encode(data).decode().rstrip('=') if data else '-')
            elif f[0] == 'b64dec':
                if len(f) != 2:
                    raise Bad()
                decoded = o_b64decode(o_hex(f[1]))
                if decoded is None:
                    raise Bad()
                out.append(hexs(decoded))
            elif f[0] == 'secret':
                if len(f) != 2:
                    raise Bad()
                out.append(hexs(o_secret(f[1])))
            elif f[0] == 'sign':
                if len(f) != 5 or not ID_RE.match(f[2]):
                    raise Bad()
                keys = o_secrets(f[1])
                o_int(f[3])
                out.append(o_sign(keys, f[2], f[3], o_hex(f[4])))
            elif f[0] == 'verify':
                if len(f) != 7 or not ID_RE.match(f[2]) or not TS_RE.match(f[3]):
                    raise Bad()
                keys = o_secrets(f[1])
                now = o_int(f[4])
                out.append(o_verify(keys, f[2], f[3], now, o_hex(f[5]), o_hex(f[6])))
            else:
                raise Bad()
        except Bad:
            out.append('error')
    return out


# ---------------------------------------------------------------------------
# Oracle 2: the standardwebhooks package, driven out of process.
# ---------------------------------------------------------------------------

ORACLE_SCRIPT = r'''
import base64, json, sys
from datetime import datetime, timezone
import standardwebhooks.webhooks as W


class PinnedClock(datetime):
    fixed = 0

    @classmethod
    def now(cls, tz=None):
        return datetime.fromtimestamp(cls.fixed, tz=timezone.utc)


W.datetime = PinnedClock

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    task = json.loads(line)
    result = {}
    try:
        wh = W.Webhook(task['secret'])
        key = wh._whsecret
        result['key'] = key.hex()
        if task['op'] == 'sign':
            content = bytes.fromhex(task['content_hex'])
            result['sig'] = 'v1,' + base64.b64encode(W.hmac_data(key, content)).decode()
            if task.get('api'):
                ts = datetime.fromtimestamp(task['ts'], tz=timezone.utc)
                result['api_sig'] = wh.sign(task['id'], ts, task['payload'])
        elif task['op'] == 'verify':
            PinnedClock.fixed = task['now']
            headers = {'webhook-id': task['id'], 'webhook-timestamp': task['ts'],
                       'webhook-signature': task['header']}
            try:
                wh.verify(task['payload'], headers, json_parse=False)
                result['verified'] = True
            except Exception as exc:
                result['verified'] = False
                result['why'] = type(exc).__name__ + ': ' + str(exc)
    except Exception as exc:
        result['error'] = type(exc).__name__ + ': ' + str(exc)
    sys.stdout.write(json.dumps(result) + '\n')
    sys.stdout.flush()
'''


class SwOracle:
    """Batched access to the standardwebhooks package in .oracle-venv."""

    def __init__(self):
        self.tasks = []
        self.expect = []
        self.skipped = 0
        self.checked = 0

    def submit(self, task, expect):
        self.tasks.append(task)
        self.expect.append(expect)

    def skip(self):
        self.skipped += 1

    def flush(self):
        if not self.tasks:
            return
        with tempfile.NamedTemporaryFile('w', suffix='.py', delete=False) as tf:
            tf.write(ORACLE_SCRIPT)
            script = tf.name
        try:
            payload = ''.join(json.dumps(t) + '\n' for t in self.tasks)
            proc = subprocess.run([ORACLE_PY, script], input=payload,
                                  capture_output=True, text=True)
            if proc.returncode != 0:
                die('standardwebhooks oracle failed: ' + proc.stderr[-2000:])
            lines = [l for l in proc.stdout.split('\n') if l]
            if len(lines) != len(self.tasks):
                die('oracle returned %d results for %d tasks' % (len(lines), len(self.tasks)))
            for task, want, line in zip(self.tasks, self.expect, lines):
                got = json.loads(line)
                if 'error' in got:
                    die('oracle rejected %r: %s' % (task, got['error']))
                for field, value in want.items():
                    if got.get(field) != value:
                        die('standardwebhooks disagrees on %s for %r: oracle %r, ours %r'
                            % (field, task, got.get(field), value))
                if 'api_sig' in got and got['api_sig'] != got['sig']:
                    die('standardwebhooks sign() disagrees with hmac_data for %r' % (task,))
                self.checked += 1
        finally:
            os.unlink(script)
        self.tasks = []
        self.expect = []


SW = SwOracle()


def die(message):
    sys.stderr.write('ABORT: ' + message + '\n')
    sys.exit(1)


def is_utf8(data):
    try:
        data.decode('utf-8')
        return True
    except UnicodeDecodeError:
        return False


def oracle_sign_check(secrets_field, msg_id, ts_text, body):
    """Queue a standardwebhooks check for one sign command."""
    try:
        keys = o_secrets(secrets_field)
    except Bad:
        return
    if not INT_RE.match(ts_text):
        return
    content = o_content(msg_id, ts_text, body)
    for secret, key in zip(secrets_field.split(','), keys):
        secret = standard_spelling(secret, key)
        sig = 'v1,' + base64.b64encode(hmac.new(key, content, hashlib.sha256).digest()).decode()
        task = {'op': 'sign', 'secret': secret, 'content_hex': content.hex()}
        expect = {'key': key.hex(), 'sig': sig}
        if is_utf8(body) and INT_RE.match(ts_text) and 0 <= int(ts_text) <= 4 * 10 ** 9:
            task['api'] = True
            task['ts'] = int(ts_text)
            task['id'] = msg_id
            task['payload'] = body.decode('utf-8')
        SW.submit(task, expect)


# A token the library can handle: one comma, and a value that its own Base64
# decoder accepts, i.e. correctly padded standard Base64.
SINGLE_TOKEN_RE = re.compile(rb'\A[!-+.-~]*,(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}=='
                             rb'|[A-Za-z0-9+/]{3}=)?\Z')


def standard_spelling(secret, key):
    """Spell a secret the way the library's lax decoder would read it.

    Its decoder silently drops characters outside the standard alphabet, so a
    URL-safe secret is handed over re-encoded in the standard alphabet.
    """
    body = secret[6:] if secret.startswith('whsec_') else secret
    if re.search(r'[-_]', body):
        return base64.b64encode(key).decode()
    return secret


def oracle_verify_check(secrets_field, msg_id, ts_text, now, header, body, ours):
    """Queue a standardwebhooks check for one verify command, when expressible."""
    try:
        keys = o_secrets(secrets_field)
    except Bad:
        return
    tokens = header.split(b' ')
    expressible = (
        is_utf8(body) and is_utf8(header) and bool(INT_RE.match(ts_text))
        and 0 <= int(ts_text) <= 4 * 10 ** 9 and 0 <= now <= 4 * 10 ** 9
        and all(SINGLE_TOKEN_RE.match(t) for t in tokens)
        and any(tokens))
    if not expressible:
        SW.skip()
        return
    within_tolerance = abs(now - int(ts_text)) <= TOLERANCE
    content = o_content(msg_id, ts_text, body)
    for secret, key in zip(secrets_field.split(','), keys):
        want = hmac.new(key, content, hashlib.sha256).digest()
        matches = any(
            t.partition(b',')[0] == b'v1' and o_b64decode(t.partition(b',')[2]) == want
            for t in tokens if b',' in t)
        SW.submit({'op': 'verify', 'secret': standard_spelling(secret, key), 'id': msg_id,
                   'ts': ts_text, 'now': now, 'header': header.decode('utf-8'),
                   'payload': body.decode('utf-8')},
                  {'key': key.hex(), 'verified': bool(within_tolerance and matches)})
    del ours


def oracle_scan(text, out_lines):
    """Walk a finished test case and queue every standardwebhooks check in it."""
    raw = text.split('\n')
    pos = [0]

    def reader():
        while pos[0] < len(raw):
            line = raw[pos[0]]
            pos[0] += 1
            if line.strip(' ') == '':
                continue
            return line
        return None

    cursor = [0]

    def take():
        line = out_lines[cursor[0]]
        cursor[0] += 1
        return line

    while True:
        line = reader()
        if line is None:
            break
        f = line.split(' ')
        if f[0] == 'simulate' and len(f) == 1:
            block = o_parse_block(reader)
            if block is None:
                take()
                continue
            header = take()
            count = int(header.split(' ')[1]) + int(header.split(' ')[2])
            for _ in range(count):
                take()
            for event in block[1]:
                for ep in block[0]:
                    if ep['filter'] is None or event['type'] in ep['filter']:
                        oracle_sign_check(
                            ','.join(base64.b64encode(k).decode() for k in ep['keys']),
                            event['id'], event['ts_text'], event['body'])
            continue
        result = take()
        if f[0] == 'sign' and len(f) == 5 and result != 'error':
            oracle_sign_check(f[1], f[2], f[3], o_hex(f[4]))
        elif f[0] == 'verify' and len(f) == 7 and result != 'error':
            oracle_verify_check(f[1], f[2], f[3], o_int(f[4]), o_hex(f[5]), o_hex(f[6]), result)
    if cursor[0] != len(out_lines):
        die('oracle scan consumed %d of %d output lines' % (cursor[0], len(out_lines)))


# ---------------------------------------------------------------------------
# Corpus loading
# ---------------------------------------------------------------------------

def load_nist(path):
    """Return the (message bytes, expected digest hex) pairs of a CAVP .rsp."""
    vectors = []
    length = None
    msg = None
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if line.startswith('Len = '):
                length = int(line[6:])
            elif line.startswith('Msg = '):
                msg = line[6:]
            elif line.startswith('MD = '):
                data = b'' if length == 0 else bytes.fromhex(msg)
                if len(data) * 8 != length:
                    die('NIST vector length mismatch in ' + path)
                vectors.append((data, line[5:]))
    return vectors


def load_github_payloads():
    """Return (name, body bytes) for every vendored GitHub webhook payload."""
    root = os.path.join(CORPUS, 'github-webhooks')
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            if not fn.endswith('.payload.json'):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            name = rel[:-len('.payload.json')].replace(os.sep, '.')
            with open(full, 'rb') as f:
                out.append((name, f.read()))
    out.sort()
    return out


NIST_SHORT = load_nist(os.path.join(CORPUS, 'nist-sha256', 'SHA256ShortMsg.rsp'))
NIST_LONG = load_nist(os.path.join(CORPUS, 'nist-sha256', 'SHA256LongMsg.rsp'))
PAYLOADS = load_github_payloads()


def check_nist():
    for data, want in NIST_SHORT + NIST_LONG:
        if hashlib.sha256(data).hexdigest() != want:
            die('NIST vector disagrees with hashlib, corpus is corrupt')


# ---------------------------------------------------------------------------
# Handy constants for the hand-written cases
# ---------------------------------------------------------------------------

SPEC_SECRET = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw'
SPEC_ID = 'msg_p5jXN8AQM9LWM0D4loKWxJek'
SPEC_TS = '1614265330'
SPEC_BODY = b'{"test": 2432232314}'
SPEC_SIG = 'v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE='

S1 = 'whsec_c2VjcmV0'                     # key b"secret"
S2 = 'whsec_b3RoZXItc2VjcmV0'             # key b"other-secret"
S3 = 'whsec_dGhpcmQta2V5'                 # key b"third-key"


def sig_of(secret, msg_id, ts_text, body):
    key = o_secret(secret)
    return o_sign([key], msg_id, ts_text, body)


def header_hex(text):
    return hexs(text.encode('utf-8'))


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

P_HEX = SPEC_BODY.hex()
H_HEX = header_hex(SPEC_SIG)

add('001_spec_examples', [
    'sha256 -',
    'sha256 616263',
    'hmac - -',
    'b64enc 666f6f',
    'b64urlenc fbff',
    'b64dec 5a6d3976',
    'b64dec -',
    'secret ' + SPEC_SECRET,
    'sign %s %s %s %s' % (SPEC_SECRET, SPEC_ID, SPEC_TS, P_HEX),
    'verify %s %s %s 1614265400 %s %s' % (SPEC_SECRET, SPEC_ID, SPEC_TS, H_HEX, P_HEX),
    'verify %s %s %s 1614265631 %s %s' % (SPEC_SECRET, SPEC_ID, SPEC_TS, H_HEX, P_HEX),
    'verify %s %s %s 1614265400 %s 7b7d' % (SPEC_SECRET, SPEC_ID, SPEC_TS, H_HEX),
    'verify %s %s %s 1614265400 - %s' % (SPEC_SECRET, SPEC_ID, SPEC_TS, P_HEX),
    'sha256 ABCD',
    'sha256 abc',
    'frobnicate 1',
])

add('002_simulate_example', [
    'simulate',
    'endpoint ep_a %s * 500,timeout,200' % SPEC_SECRET,
    'endpoint ep_b whsec_c2VjcmV0,whsec_b3RoZXI user.created 200',
    'event msg_1 1700000000 user.created 7b7d',
    'event msg_2 1700000100 repo.pushed 7b7d',
    'end',
])

add('003_spec_vector', [
    # The published Standard Webhooks test vector, in every secret spelling.
    'sign %s %s %s %s' % (SPEC_SECRET, SPEC_ID, SPEC_TS, P_HEX),
    'sign MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw %s %s %s' % (SPEC_ID, SPEC_TS, P_HEX),
    'secret MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw',
    'secret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr',
    'secret whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr==',
    'secret MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr=',
    'verify %s %s %s %s %s %s' % (SPEC_SECRET, SPEC_ID, SPEC_TS, SPEC_TS, H_HEX, P_HEX),
    'verify MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw %s %s %s %s %s' % (
        SPEC_ID, SPEC_TS, SPEC_TS, H_HEX, P_HEX),
    'verify %s %s %s %s %s %s' % (
        SPEC_SECRET, SPEC_ID, SPEC_TS, SPEC_TS, header_hex('v2,abc ' + SPEC_SIG), P_HEX),
])


def sha_block_case():
    lines = []
    for n in [0, 1, 2, 3, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 1000]:
        lines.append('sha256 ' + hexs(bytes((i * 37 + 11) & 255 for i in range(n))))
    lines.append('sha256 ' + hexs(b'\x00' * 200))
    lines.append('sha256 ' + hexs(b'\xff' * 200))
    return lines


add('004_sha256_block_boundaries', sha_block_case())

RFC4231 = [
    (b'\x0b' * 20, b'Hi There'),
    (b'Jefe', b'what do ya want for nothing?'),
    (b'\xaa' * 20, b'\xdd' * 50),
    (bytes(range(1, 26)), b'\xcd' * 50),
    (b'\x0c' * 20, b'Test With Truncation'),
    (b'\xaa' * 131, b'Test Using Larger Than Block-Size Key - Hash Key First'),
    (b'\xaa' * 131, b'This is a test using a larger than block-size key and a larger '
                    b'than block-size data. The key needs to be hashed before being used'
                    b' by the HMAC algorithm.'),
]
add('005_hmac_rfc4231', ['hmac %s %s' % (hexs(k), hexs(m)) for k, m in RFC4231])

add('006_hmac_key_lengths', [
    'hmac %s %s' % (hexs(bytes((i * 17 + 3) & 255 for i in range(n))), hexs(b'message'))
    for n in [0, 1, 20, 31, 32, 33, 63, 64, 65, 100, 128, 200]
] + [
    'hmac %s -' % hexs(b'k'),
    'hmac - %s' % hexs(b'\x00' * 64),
])


def b64_encode_case(command):
    lines = []
    for n in range(0, 13):
        lines.append('%s %s' % (command, hexs(bytes(range(240, 240 + n)) if n else b'')))
    for data in [b'f', b'fo', b'foo', b'foob', b'fooba', b'foobar', b'\x00', b'\x00\x00',
                 b'\xfb\xff', b'\xff\xff\xff', b'\xfb\xef\xbe', bytes(range(256))]:
        lines.append('%s %s' % (command, hexs(data)))
    return lines


add('007_base64_encode_standard', b64_encode_case('b64enc'))
add('008_base64_encode_urlsafe', b64_encode_case('b64urlenc'))

VALID_B64 = ['', 'Zg==', 'Zm8=', 'Zm9v', 'Zg', 'Zm8', 'QQ==', 'QR==', 'QV==', 'Qf==',
             '+/8=', '-_8', '-_8=', 'AAAA', '////', '____', 'AQIDBAUGBwgJ',
             'MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw', 'MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr',
             'MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSwBr==', 'aGVsbG8gd29ybGQ']
add('009_base64_decode_valid', ['b64dec ' + header_hex(s) for s in VALID_B64])

INVALID_B64 = ['A', 'AAAAA', '=', '==', 'A=', 'AA=', 'AAA==', 'AAAA=', 'AAAA==', 'Zg=',
               'Zg===', 'Z=g=', 'a b', 'a\tb', 'ab-+', '-_+/', 'ab_/', 'Zm9v!', 'Zm9v~',
               'Zm 9v', '.', 'Zm9v\n', 'ab==cd']
def b64_decode_invalid_case():
    # Each rejected string is followed by the accepted string it is a mangling
    # of, so an implementation that answers `error` to everything fails here.
    lines = []
    for i, bad in enumerate(INVALID_B64):
        lines.append('b64dec ' + header_hex(bad))
        lines.append('b64dec ' + header_hex(VALID_B64[i % len(VALID_B64)]))
    return lines


add('010_base64_decode_invalid', b64_decode_invalid_case())

add('011_secret_forms', [
    'secret whsec_c2VjcmV0',
    'secret c2VjcmV0',
    'secret whsec_whsec_c2VjcmV0',
    'secret ' + base64.b64encode(bytes(range(64))).decode(),
    'secret ' + base64.urlsafe_b64encode(b'\xfb\xef\xbe\xff').decode().rstrip('='),
    'secret whsec_',
    'secret whsec_=',
    'secret whsec_A',
    'secret whsec_!!!!',
    'secret -',
    'secret AA==AA',
    'secret ' + base64.b64encode(b'\x00').decode(),
    'secret ' + ('A' * 512),
    'secret ' + ('A' * 513),
])


def sign_case():
    lines = []
    for body in [b'', b'{}', b'{"a":1}', SPEC_BODY, b'\x00\x01\x02', bytes(range(256)),
                 'héllo wörld'.encode('utf-8'), b'x' * 1000]:
        lines.append('sign %s evt_1 1700000000 %s' % (S1, hexs(body)))
    for ts in ['0', '-1', '-1000000', '999999999999999', '1']:
        lines.append('sign %s evt_1 %s %s' % (S1, ts, hexs(b'body')))
    for msg_id in ['a', 'msg_' + 'z' * 200, '!@#$%^&*()', 'v1,x', '-']:
        lines.append('sign %s %s 1700000000 %s' % (S1, msg_id, hexs(b'body')))
    lines.append('sign %s,%s,%s evt_1 1700000000 %s' % (S1, S2, S3, hexs(b'body')))
    return lines


add('012_sign_basic', sign_case())

add('013_sign_errors', [
    'sign %s evt_1 1700000000' % S1,
    'sign %s evt_1 1700000000 7b7d extra' % S1,
    'sign %s evt_1 01700000000 7b7d' % S1,
    'sign %s evt_1 +1700000000 7b7d' % S1,
    'sign %s evt_1 -0 7b7d' % S1,
    'sign %s evt_1 1700000000.0 7b7d' % S1,
    'sign %s evt_1 1000000000000000 7b7d' % S1,
    'sign %s evt_1 1000000000000001 7b7d' % S1,
    'sign %s, evt_1 1700000000 7b7d' % S1,
    'sign ,%s evt_1 1700000000 7b7d' % S1,
    'sign %s evt_1 1700000000 7b7' % S1,
    'sign %s evt_1 1700000000 7B7D' % S1,
    'sign %s evt_1 1700000000 ' % S1,
    'sign %s  evt_1 1700000000 7b7d' % S1,
    'sign whsec_!!! evt_1 1700000000 7b7d',
    'sign %s evt_1 1700000000 7b7d' % ','.join([S1] * 16),
    'sign %s evt_1 1700000000 7b7d' % ','.join([S1] * 17),
    'sign',
])


def verify_roundtrip_case():
    lines = []
    for body in [b'', b'{}', SPEC_BODY, bytes(range(256)), 'ünïcödé'.encode('utf-8')]:
        sig = sig_of(S1, 'evt_9', '1700000000', body)
        lines.append('verify %s evt_9 1700000000 1700000000 %s %s'
                     % (S1, header_hex(sig), hexs(body)))
        lines.append('verify %s evt_9 1700000000 1700000000 %s %s'
                     % (S2, header_hex(sig), hexs(body)))
    return lines


add('014_verify_roundtrip', verify_roundtrip_case())


def tampered_case():
    body = b'{"amount": 100, "currency": "usd"}'
    sig = sig_of(S1, 'evt_t', '1700000000', body)
    raw = base64.b64decode(sig[3:])
    lines = ['verify %s evt_t 1700000000 1700000000 %s %s' % (S1, header_hex(sig), hexs(body))]
    # A tampered body, id or timestamp all break the signature.
    lines.append('verify %s evt_t 1700000000 1700000000 %s %s'
                 % (S1, header_hex(sig), hexs(b'{"amount": 900, "currency": "usd"}')))
    lines.append('verify %s evt_u 1700000000 1700000000 %s %s' % (S1, header_hex(sig), hexs(body)))
    lines.append('verify %s evt_t 1700000001 1700000000 %s %s' % (S1, header_hex(sig), hexs(body)))
    for bit in [0, 7, 127, 255]:
        flipped = bytearray(raw)
        flipped[bit // 8] ^= 1 << (bit % 8)
        token = 'v1,' + base64.b64encode(bytes(flipped)).decode()
        lines.append('verify %s evt_t 1700000000 1700000000 %s %s'
                     % (S1, header_hex(token), hexs(body)))
    # Truncated and over-long signature values never match.
    lines.append('verify %s evt_t 1700000000 1700000000 %s %s'
                 % (S1, header_hex('v1,' + base64.b64encode(raw[:16]).decode()), hexs(body)))
    lines.append('verify %s evt_t 1700000000 1700000000 %s %s'
                 % (S1, header_hex('v1,' + base64.b64encode(raw + b'\x00').decode()), hexs(body)))
    return lines


add('015_verify_tampered', tampered_case())


def timestamp_case():
    body = b'{"ok":true}'
    lines = []
    for ts in ['1700000000', '0', '-500']:
        sig = sig_of(S1, 'evt_ts', ts, body)
        base = int(ts)
        for now in [base, base + 299, base + 300, base + 301, base + 100000,
                    base - 299, base - 300, base - 301]:
            lines.append('verify %s evt_ts %s %d %s %s'
                         % (S1, ts, now, header_hex(sig), hexs(body)))
    for ts in ['01700000000', '+1700000000', '1700000000.5', 'abc', '', '1e9', '-0',
               '1000000000000001', ' ']:
        sig = sig_of(S1, 'evt_ts', ts if ts else '0', body)
        field = ts if ts else '-'
        lines.append('verify %s evt_ts %s 1700000000 %s %s'
                     % (S1, field, header_hex(sig), hexs(body)))
    return lines


add('016_verify_timestamps', timestamp_case())


def rotation_case():
    body = b'{"event":"rotate"}'
    lines = []
    s1 = sig_of(S1, 'evt_r', '1700000000', body)
    s2 = sig_of(S2, 'evt_r', '1700000000', body)
    s3 = sig_of(S3, 'evt_r', '1700000000', body)
    for secrets in ['%s,%s' % (S1, S2), '%s,%s' % (S2, S1), '%s,%s,%s' % (S3, S2, S1)]:
        for header in [s1, s2, s3, s1 + ' ' + s2, s2 + ' ' + s1, s1 + ' ' + s2 + ' ' + s3]:
            lines.append('verify %s evt_r 1700000000 1700000000 %s %s'
                         % (secrets, header_hex(header), hexs(body)))
    lines.append('verify %s,%s evt_r 1700000000 1700000000 %s %s'
                 % (S1, S1, header_hex(s1), hexs(body)))
    return lines


add('017_verify_rotation', rotation_case())


def multi_signature_case():
    body = b'{"n":1}'
    good = sig_of(S1, 'evt_m', '1700000000', body)
    other = sig_of(S2, 'evt_m', '1700000000', body)
    headers = [
        good,
        other + ' ' + good,
        'v2,' + good[3:] + ' ' + good,
        'garbage ' + good,
        'v1,!!!! ' + good,
        'v1,A ' + good,
        good + ' ' + good,
        '  ' + good,
        good + '  ',
        'v1,' + base64.b64encode(b'\x00' * 32).decode() + ' ' + good,
        ' '.join(['v1,' + base64.b64encode(bytes([i]) * 32).decode() for i in range(8)])
        + ' ' + good,
    ]
    return ['verify %s evt_m 1700000000 1700000000 %s %s' % (S1, header_hex(h), hexs(body))
            for h in headers]


add('018_verify_multi_signature', multi_signature_case())


def malformed_header_case():
    body = b'{"n":2}'
    good = sig_of(S1, 'evt_h', '1700000000', body)
    headers = ['', ' ', '   ', 'v1', 'v1,', ',', 'v1,,', ',abc', 'v1,abc,def',
               'v1,' + good[3:-1], 'V1,' + good[3:], 'v10,' + good[3:],
               ' ' + good, good + ' ', '\t' + good, good + '\n',
               'v1,' + good[3:].replace('+', '-').replace('/', '_')]
    lines = ['verify %s evt_h 1700000000 1700000000 %s %s' % (S1, header_hex(h), hexs(body))
             for h in headers]
    lines.append('verify %s evt_h 1700000000 1700000000 %s %s'
                 % (S1, hexs(b'v1,' + b'\xff\xfe'), hexs(body)))
    return lines


add('019_verify_malformed_headers', malformed_header_case())

add('020_command_errors', [
    '',
    ' ',
    '   ',
    'sha256',
    'sha256 -',
    'sha256 - -',
    'sha256  -',
    ' sha256 -',
    'sha256 - ',
    'SHA256 -',
    'sha256\t-',
    'hmac -',
    'hmac - - -',
    'b64enc',
    'b64enc - -',
    'b64urlenc 0',
    'b64dec',
    'b64dec 2b',
    'secret',
    'secret a b',
    'verify %s evt 1700000000 1700000000 - -' % S1,
    'verify %s evt 1700000000 1700000000 - - -' % S1,
    'verify %s evt %s 1700000000 - 7b7d' % (S1, 'z' * 64),
    'verify %s evt %s 1700000000 - 7b7d' % (S1, 'z' * 65),
    'verify %s %s 1700000000 1700000000 - 7b7d' % (S1, 'i' * 256),
    'verify %s %s 1700000000 1700000000 - 7b7d' % (S1, 'i' * 257),
    'verify %s evt 1700000000 01 - 7b7d' % S1,
    'simulate now',
    'end',
    'endpoint ep %s * 200' % S1,
    'event ev 1 t 7b7d',
    '#comment',
])

add('021_blank_lines_and_spacing', [
    '',
    'sha256 -',
    '',
    '   ',
    'sha256 616263',
    '',
    'simulate',
    '',
    'endpoint ep_1 %s * 200' % S1,
    '',
    'event ev_1 100 t 7b7d',
    '',
    'end',
    '',
    'sha256 00',
    '',
])

add('022_simulate_retry_schedule', [
    'simulate',
    'endpoint ep_fail %s * 500' % S1,
    'endpoint ep_slow %s * timeout' % S2,
    'endpoint ep_ok %s * 200' % S3,
    'event ev_1 1000000 alpha 7b7d',
    'end',
])

add('023_simulate_outcomes', [
    'simulate',
    'endpoint ep_a %s * 200,201,299,300,400,404,429,500,503,100,199,410' % S1,
    'event ev_1 0 t 61',
    'event ev_2 1000000 t 62',
    'event ev_3 2000000 t 63',
    'event ev_4 3000000 t 64',
    'end',
])

add('024_simulate_disable', [
    'simulate',
    'endpoint ep_gone %s * 500,410,200' % S1,
    'endpoint ep_live %s * 200' % S2,
    'event ev_1 1000 t 7b7d',
    'event ev_2 1002 t 7b7d',
    'event ev_3 2000 t 7b7d',
    'event ev_4 3000000 t 7b7d',
    'end',
])

add('025_simulate_filters', [
    'simulate',
    'endpoint ep_all %s * 200' % S1,
    'endpoint ep_user %s user.created,user.deleted 200' % S2,
    'endpoint ep_repo %s repo.pushed 200' % S3,
    'endpoint ep_none %s no.such.type 200' % S1,
    'event ev_1 100 user.created 7b7d',
    'event ev_2 200 user.deleted 7b7d',
    'event ev_3 300 repo.pushed 7b7d',
    'event ev_4 400 billing.paid 7b7d',
    'end',
])

add('026_simulate_script_exhaustion', [
    'simulate',
    'endpoint ep_a %s * 500,429' % S1,
    'endpoint ep_b %s * 200' % S2,
    'event ev_1 0 t 7b7d',
    'event ev_2 1 t 7b7d',
    'end',
])

add('027_simulate_errors', [
    'simulate',
    'endpoint ep_a %s * 200' % S1,
    'event ev_1 0 t 7b7d',
    'endpoint ep_b %s * 200' % S2,
    'end',
    'simulate',
    'endpoint ep_a %s * 600' % S1,
    'end',
    'simulate',
    'endpoint ep_a %s * 099' % S1,
    'end',
    'simulate',
    'endpoint ep_a %s * 20' % S1,
    'end',
    'simulate',
    'endpoint ep_a %s * 200,' % S1,
    'end',
    'simulate',
    'endpoint ep_a %s  200' % S1,
    'end',
    'simulate',
    'endpoint ep_a %s * 200' % S1,
    'endpoint ep_a %s * 200' % S2,
    'end',
    'simulate',
    'endpoint ep_a %s * 200' % S1,
    'event ev_1 0 t 7b7d',
    'event ev_1 1 t 7b7d',
    'end',
    'simulate',
    'event ev_1 0 t 7b7d',
    'end',
    'simulate',
    'endpoint ep_a %s * 200' % S1,
    'delete everything',
    'end',
    'simulate',
    'endpoint ep_a %s * 200' % S1,
    'simulate',
    'end',
    'sha256 -',
    'simulate',
    'endpoint ep_a %s * 200' % S1,
    'event ev_1 0 t 7b7d',
])

add('028_simulate_ordering', [
    'simulate',
    'endpoint ep_a %s * 500,500,200' % S1,
    'endpoint ep_b %s * 200' % S2,
    'event ev_late 5000 t 7b7d',
    'event ev_early 0 t 7b7d',
    'event ev_same 0 t 7b7d',
    'event ev_neg -10000 t 7b7d',
    'end',
])


def nist_case(vectors, limit=None):
    chosen = vectors if limit is None else vectors[:limit]
    return ['sha256 ' + hexs(data) for data, _ in chosen]


add('029_nist_sha256_short', nist_case(NIST_SHORT))
add('030_nist_sha256_long', nist_case(NIST_LONG))


def payload_sign_case(payloads):
    lines = []
    for i, (name, body) in enumerate(payloads):
        msg_id = 'msg_' + name.replace('.', '_')[:60]
        ts = str(1700000000 + i * 17)
        lines.append('sha256 ' + hexs(body))
        lines.append('sign %s %s %s %s' % (S1, msg_id, ts, hexs(body)))
        lines.append('sign %s,%s %s %s %s' % (S1, S2, msg_id, ts, hexs(body)))
    return lines


SMALL_PAYLOADS = [p for p in PAYLOADS if len(p[1]) <= 16000]
BIG_PAYLOADS = sorted(PAYLOADS, key=lambda p: -len(p[1]))[:6]

add('031_github_payload_sign', payload_sign_case(SMALL_PAYLOADS[:60]))
add('032_github_payload_sign_more', payload_sign_case(SMALL_PAYLOADS[60:130]))
add('033_github_payload_large', payload_sign_case(BIG_PAYLOADS))


def payload_verify_case(payloads):
    lines = []
    for i, (name, body) in enumerate(payloads):
        msg_id = 'msg_' + name.replace('.', '_')[:60]
        ts = str(1700000000 + i * 17)
        secret = [S1, S2, S3][i % 3]
        sig = sig_of(secret, msg_id, ts, body)
        other = sig_of(S3 if secret != S3 else S1, msg_id, ts, body)
        lines.append('verify %s %s %s %s %s %s'
                     % (secret, msg_id, ts, ts, header_hex(sig), hexs(body)))
        lines.append('verify %s,%s,%s %s %s %s %s %s'
                     % (S1, S2, S3, msg_id, ts, ts, header_hex(other + ' ' + sig), hexs(body)))
        lines.append('verify %s %s %s %s %s %s'
                     % (S2 if secret != S2 else S1, msg_id, ts, ts,
                        header_hex(sig), hexs(body)))
        lines.append('verify %s %s %s %d %s %s'
                     % (secret, msg_id, ts, int(ts) + 301, header_hex(sig), hexs(body)))
    return lines


add('034_github_payload_verify', payload_verify_case(SMALL_PAYLOADS[130:180]))


def binary_payload_case():
    rng = random.Random(20240917)
    lines = []
    for n in [1, 2, 3, 17, 64, 65, 255, 256, 1024]:
        body = bytes(rng.randrange(256) for _ in range(n))
        sig = sig_of(S1, 'bin_%d' % n, '1700000000', body)
        lines.append('sha256 ' + hexs(body))
        lines.append('sign %s bin_%d 1700000000 %s' % (S1, n, hexs(body)))
        lines.append('verify %s bin_%d 1700000000 1700000000 %s %s'
                     % (S1, n, header_hex(sig), hexs(body)))
    for text in ['', 'ascii', 'ünïcödé', '日本語のペイロード', '🎉🎉🎉', 'line\nbreak\ttab',
                 'quote"and\\backslash']:
        body = text.encode('utf-8')
        sig = sig_of(S2, 'txt', '1700000000', body)
        lines.append('sign %s txt 1700000000 %s' % (S2, hexs(body)))
        lines.append('verify %s txt 1700000000 1700000000 %s %s'
                     % (S2, header_hex(sig), hexs(body)))
    return lines


add('035_binary_and_unicode_payloads', binary_payload_case())


def mixed_stream_case(seed, count):
    rng = random.Random(seed)
    secrets = [S1, S2, S3, SPEC_SECRET, 'c2hvcnQ', base64.b64encode(b'\x00\x01\x02').decode()]
    lines = []
    for i in range(count):
        kind = rng.randrange(8)
        body = bytes(rng.randrange(256) for _ in range(rng.randrange(0, 80)))
        if kind == 0:
            lines.append('sha256 ' + hexs(body))
        elif kind == 1:
            key = bytes(rng.randrange(256) for _ in range(rng.randrange(0, 90)))
            lines.append('hmac %s %s' % (hexs(key), hexs(body)))
        elif kind == 2:
            lines.append('b64enc ' + hexs(body))
        elif kind == 3:
            lines.append('b64urlenc ' + hexs(body))
        elif kind == 4:
            lines.append('b64dec ' + header_hex(base64.b64encode(body).decode()))
        elif kind == 5:
            lines.append('secret ' + rng.choice(secrets))
        elif kind == 6:
            picked = rng.sample(secrets, rng.randrange(1, 4))
            lines.append('sign %s evt_%d %d %s'
                         % (','.join(picked), i, rng.randrange(-10 ** 6, 2 * 10 ** 9), hexs(body)))
        else:
            secret = rng.choice(secrets)
            ts = rng.randrange(0, 2 * 10 ** 9)
            msg_id = 'evt_%d' % i
            sig = sig_of(secret, msg_id, str(ts), body)
            if rng.random() < 0.3:
                body = body + b'!'
            header = sig if rng.random() < 0.7 else 'v2,zz ' + sig
            now = ts + rng.choice([0, 1, 299, 300, 301, -301, 5000])
            lines.append('verify %s %s %d %d %s %s'
                         % (secret, msg_id, ts, now, header_hex(header), hexs(body)))
    return lines


add('036_mixed_stream', mixed_stream_case(1, 300))


def simulate_github_case():
    lines = ['simulate']
    scripts = ['200', '500,200', '500,500,500,200', 'timeout,200', '429,429,200',
               '500,410', '503,timeout,500,200', '404,404,404,404,404,404,404,404']
    types = ['push', 'pull_request', 'issues', 'release', 'star']
    for i in range(8):
        secrets = S1 if i % 3 else '%s,%s' % (S1, S2)
        filt = '*' if i % 4 == 0 else ','.join(types[i % len(types):i % len(types) + 2])
        lines.append('endpoint ep_%d %s %s %s' % (i, secrets, filt, scripts[i]))
    for i, (name, body) in enumerate(SMALL_PAYLOADS[:40]):
        lines.append('event ev_%03d %d %s %s'
                     % (i, 1700000000 + i * 137, types[i % len(types)], hexs(body)))
    lines.append('end')
    return lines


add('037_simulate_github_events', simulate_github_case())


def simulate_volume_case(seed, n_endpoints, n_events, body_size):
    rng = random.Random(seed)
    scripts = ['200', '500,200', '500,500,200', 'timeout,timeout,200', '429,200',
               '503,503,503,503,503,503,503,503', '500,500,410,200', '404,200',
               'timeout,500,429,200', '201,202,203']
    types = ['t%d' % i for i in range(6)]
    lines = ['simulate']
    for i in range(n_endpoints):
        secrets = ','.join(rng.sample([S1, S2, S3], rng.randrange(1, 3)))
        filt = '*' if rng.random() < 0.3 else ','.join(rng.sample(types, rng.randrange(1, 4)))
        lines.append('endpoint ep_%02d %s %s %s' % (i, secrets, filt, rng.choice(scripts)))
    for i in range(n_events):
        body = bytes(rng.randrange(32, 127) for _ in range(rng.randrange(1, body_size)))
        lines.append('event ev_%05d %d %s %s'
                     % (i, 1700000000 + rng.randrange(0, 200000),
                        rng.choice(types), hexs(body)))
    lines.append('end')
    return lines


add('038_simulate_batch', simulate_volume_case(7, 6, 200, 120))
add('039_simulate_large_batch', simulate_volume_case(11, 9, 800, 200))


def hash_volume_case(seed, count):
    rng = random.Random(seed)
    lines = []
    for _ in range(count):
        n = rng.randrange(0, 2000)
        data = bytes(rng.randrange(256) for _ in range(n))
        lines.append('sha256 ' + hexs(data))
        key = bytes(rng.randrange(256) for _ in range(rng.randrange(0, 130)))
        lines.append('hmac %s %s' % (hexs(key), hexs(data)))
    return lines


add('040_hash_volume', hash_volume_case(3, 150))
add('041_mixed_stream_large', mixed_stream_case(5, 1500))


def grammar_limits_case():
    """Pin every count and length limit the grammar states, on both sides."""
    ev = 'event ev_1 1000 t.type 7b7d'
    n64 = 'e' * 64
    n65 = 'e' * 65
    sixteen = ','.join('f%02d' % i for i in range(15)) + ',t.type'
    seventeen = ','.join('f%02d' % i for i in range(16)) + ',t.type'
    lines = [
        # A <secret> is a single secret: a comma is not a separator here.
        'secret %s,%s' % (S1, S2),
        'secret %s,' % S1,
        'secret ,%s' % S1,
        'secret ' + S1,
        # 64 endpoints is the maximum.
        'simulate',
    ]
    lines += ['endpoint ep_%02d %s * 200' % (i, S1) for i in range(64)]
    lines += [ev, 'end', 'simulate']
    lines += ['endpoint ep_%02d %s * 200' % (i, S1) for i in range(65)]
    lines += [ev, 'end']
    # 16 filter entries, then 17.
    lines += ['simulate', 'endpoint ep_a %s %s 200' % (S1, sixteen), ev, 'end',
              'simulate', 'endpoint ep_a %s %s 200' % (S1, seventeen), ev, 'end']
    # 16 secrets on an endpoint, then 17.
    lines += ['simulate', 'endpoint ep_a %s * 200' % ','.join([S1] * 16), ev, 'end',
              'simulate', 'endpoint ep_a %s * 200' % ','.join([S1] * 17), ev, 'end']
    # 64 script entries, then 65.  The first eight entries decide the run.
    script64 = ','.join(['500'] * 63 + ['200'])
    script65 = ','.join(['500'] * 64 + ['200'])
    lines += ['simulate', 'endpoint ep_a %s * %s' % (S1, script64), ev, 'end',
              'simulate', 'endpoint ep_a %s * %s' % (S1, script65), ev, 'end']
    # 64-character endpoint id, event id and event type, then 65 of each.
    lines += ['simulate', 'endpoint %s %s %s 200' % (n64, S1, n64),
              'event %s 1000 %s 7b7d' % (n64, n64), 'end']
    for bad in [('endpoint %s %s * 200' % (n65, S1), ev),
                ('endpoint ep_a %s * 200' % S1, 'event %s 1000 t.type 7b7d' % n65),
                ('endpoint ep_a %s * 200' % S1, 'event ev_1 1000 %s 7b7d' % n65),
                ('endpoint ep_a %s %s 200' % (S1, n65), ev)]:
        lines += ['simulate', bad[0], bad[1], 'end']
    # A block with no endpoint at all, and an empty block.
    lines += ['simulate', ev, 'end', 'simulate', 'end']
    return lines


add('042_grammar_limits', grammar_limits_case())


def event_cap_case():
    """20000 events is the maximum; the 20001st breaks the block."""
    lines = ['simulate', 'endpoint ep_a %s no.such.type 200' % S1]
    lines += ['event e%05d %d t 61' % (i, i) for i in range(20000)]
    lines += ['end', 'simulate', 'endpoint ep_a %s no.such.type 200' % S1]
    lines += ['event e%05d %d t 61' % (i, i) for i in range(20001)]
    lines += ['end', 'sha256 616263']
    return lines


add('043_simulate_event_cap', event_cap_case())


# ---------------------------------------------------------------------------
# Generate, cross-check, write
# ---------------------------------------------------------------------------

def run_reference(text):
    proc = subprocess.run([sys.executable, REF], input=text.encode('utf-8'),
                          capture_output=True)
    if proc.returncode != 0:
        die('reference failed: ' + proc.stderr.decode('utf-8', 'replace')[-2000:])
    return proc.stdout.decode('utf-8')


def check_nist_in_output(text, out_lines):
    """Check sha256 lines whose input is a NIST vector against the vector's own MD."""
    if 'simulate' in text:
        return 0
    want = {data.hex() if data else '-': digest for data, digest in NIST_SHORT + NIST_LONG}
    matched = 0
    idx = 0
    for line in text.split('\n'):
        if line.strip(' ') == '':
            continue
        f = line.split(' ')
        if f[0] == 'sha256' and len(f) == 2 and f[1] in want:
            if out_lines[idx] != want[f[1]]:
                die('NIST vector disagrees with the reference for %r' % (f[1][:40],))
            matched += 1
        idx += 1
    return matched


def main():
    check_nist()
    if os.path.isdir(TESTS):
        for fn in sorted(os.listdir(TESTS)):
            if fn.endswith('.in') or fn.endswith('.out'):
                os.unlink(os.path.join(TESTS, fn))
    else:
        os.makedirs(TESTS)

    names = set()
    nist_checked = 0
    total_lines = 0
    for name, text in cases:
        if name in names:
            die('duplicate case name ' + name)
        names.add(name)
        out = run_reference(text)
        out_lines = out.split('\n')
        if out_lines and out_lines[-1] == '':
            out_lines.pop()

        expected = oracle_run(text)
        if expected != out_lines:
            for i, (a, b) in enumerate(zip(expected, out_lines)):
                if a != b:
                    die('%s: line %d: oracle %r, reference %r' % (name, i + 1, a, b))
            die('%s: oracle produced %d lines, reference %d'
                % (name, len(expected), len(out_lines)))

        nist_checked += check_nist_in_output(text, out_lines)
        oracle_scan(text, out_lines)
        SW.flush()

        with open(os.path.join(TESTS, name + '.in'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        with open(os.path.join(TESTS, name + '.out'), 'w', encoding='utf-8', newline='\n') as f:
            f.write('\n'.join(out_lines) + '\n')
        total_lines += len(out_lines)
        print('%-36s %6d input lines %7d output lines' %
              (name, text.count('\n'), len(out_lines)))

    SW.flush()
    size = sum(os.path.getsize(os.path.join(TESTS, fn)) for fn in os.listdir(TESTS))
    print()
    print('%d cases, %d output lines, tests/ is %.1f MB' % (len(cases), total_lines, size / 1e6))
    print('standardwebhooks checks: %d run, %d verify commands not expressible in its API'
          % (SW.checked, SW.skipped))
    print('NIST CAVP vectors matched against the reference: %d' % nist_checked)


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/github-webhooks/LICENSE',
     'LICENSE-octokit-webhooks.txt'),
    ('corpus/LICENSE.standard-webhooks',
     'LICENSE-standard-webhooks.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == '__main__':
    main()
    copy_licences()
