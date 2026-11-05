#!/usr/bin/env python3
"""Generates the performance benchmark inputs for the `webhooks` problem.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as tests/,
so `python3 run_tests.py webhooks --tests-dir problems/webhooks/bench -- <cmd>`
runs them. Inputs are seeded and reproducible byte for byte. Expected outputs
come from reference/main.py (pass --no-expected to write only the inputs).

--long writes the long tier to ../bench-long/ (see NOTES.md); its expected
outputs also come from the reference, which needs over an hour on 002.

Payload bodies are the real GitHub webhook payloads vendored in
corpus/github-webhooks plus small synthetic JSON bodies.
"""
import base64
import hashlib
import hmac
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
CORPUS = os.path.join(PROBLEM, 'corpus', 'github-webhooks')
REF = os.path.join(PROBLEM, 'reference', 'main.py')


def hexs(data):
    return data.hex() if data else '-'


def load_payloads():
    out = []
    for dirpath, dirnames, filenames in os.walk(CORPUS):
        dirnames.sort()
        for fn in sorted(filenames):
            if fn.endswith('.payload.json'):
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, CORPUS)[:-len('.payload.json')]
                with open(full, 'rb') as f:
                    out.append((rel.replace(os.sep, '.'), f.read()))
    out.sort()
    return out


PAYLOADS = load_payloads()


def make_secret(rng):
    """A whsec_ secret over a random 24..32-byte key, as providers issue them."""
    key = bytes(rng.randrange(256) for _ in range(rng.randrange(24, 33)))
    return 'whsec_' + base64.b64encode(key).decode(), key


def signature(key, msg_id, ts, body):
    mac = hmac.new(key, msg_id.encode() + b'.' + ts.encode() + b'.' + body,
                   hashlib.sha256).digest()
    return 'v1,' + base64.b64encode(mac).decode()


def event_type(name):
    return name.split('.')[0][:64]


# ---------------------------------------------------------------------------
# 001: a signing/verification gateway over real GitHub payloads
# ---------------------------------------------------------------------------

def gateway_stream(seed, count):
    """Sign and verify real GitHub payloads under key-rotation sets.

    Each tenant owns a rotation set of 4..16 secrets. Senders sign with the
    whole set; receivers verify a header that carries the newest one or two
    signatures, so the match is usually found after trying several older keys.
    About a fifth of the verifies are tampered or stale and fail.
    """
    rng = random.Random(seed)
    tenants = []
    for _ in range(40):
        k = rng.choice([4, 6, 8, 12, 16, 16])
        tenants.append([make_secret(rng) for _ in range(k)])
    lines = []
    for i in range(count):
        name, body = PAYLOADS[rng.randrange(len(PAYLOADS))]
        secrets = tenants[rng.randrange(len(tenants))]
        field = ','.join(s for s, _ in secrets)
        msg_id = 'msg_%s_%06d' % (event_type(name), i)
        ts = 1700000000 + i * 3 + rng.randrange(60)
        r = rng.random()
        if r < 0.40:
            lines.append('sign %s %s %d %s' % (field, msg_id, ts, hexs(body)))
        elif r < 0.45:
            lines.append('sha256 ' + hexs(body))
        else:
            ntok = min(len(secrets), rng.randrange(1, 3))
            toks = [signature(key, msg_id, str(ts), body) for _, key in secrets[-ntok:]]
            rng.shuffle(toks)
            now = ts + rng.randrange(-120, 240)
            q = rng.random()
            if q < 0.12:
                body = body[:-1] + b' '          # tampered in transit
            elif q < 0.17:
                now = ts + 301 + rng.randrange(3600)  # replayed late
            elif q < 0.22:
                toks.insert(0, 'v1a,' + toks[0][3:])  # unknown version prefix
            header = ' '.join(toks)
            lines.append('verify %s %s %d %d %s %s'
                         % (field, msg_id, ts, now, hexs(header.encode()), hexs(body)))
    return lines


# ---------------------------------------------------------------------------
# 002: broadcast fan-out of real payloads to many subscribers
# ---------------------------------------------------------------------------

TYPES = sorted({event_type(n) for n, _ in PAYLOADS})


def fanout_block(seed, n_endpoints, n_events):
    """One simulate block: GitHub events fanned out to 64 subscriber endpoints.

    Most subscribers take every event or a broad filter, several rotate two or
    three secrets, and their scripts mix healthy, flaky and dead endpoints.
    """
    rng = random.Random(seed)
    scripts = ['200', '200', '201', '500,200', 'timeout,200', '503,503,200',
               '429,429,429,200', '500,500,500,500,500,500,500,500', '502,timeout,410',
               'timeout,timeout,timeout,200', '404', '200,200,200,500,200']
    lines = ['simulate']
    for e in range(n_endpoints):
        k = rng.choice([1, 1, 2, 2, 3])
        secrets = ','.join(make_secret(rng)[0] for _ in range(k))
        if rng.random() < 0.6:
            filt = '*'
        else:
            filt = ','.join(rng.sample(TYPES, min(len(TYPES), rng.randrange(4, 16))))
        lines.append('endpoint sub-%02d.example %s %s %s'
                     % (e, secrets, filt, rng.choice(scripts)))
    for i in range(n_events):
        name, body = PAYLOADS[rng.randrange(len(PAYLOADS))]
        lines.append('event evt_%05d %d %s %s'
                     % (i, 1700000000 + rng.randrange(0, 86400), event_type(name), hexs(body)))
    lines.append('end')
    return lines


# ---------------------------------------------------------------------------
# 003: a busy dispatcher: retry storm plus interleaved API traffic
# ---------------------------------------------------------------------------

def small_body(rng, i):
    kind = rng.choice(['invoice.paid', 'invoice.failed', 'user.created', 'user.updated',
                       'order.shipped', 'order.refunded', 'payment.captured'])
    body = ('{"type":"%s","id":"obj_%07d","amount":%d,"currency":"usd","attempt":%d}'
            % (kind, i, rng.randrange(100, 10 ** 6), rng.randrange(1, 4)))
    return kind, body.encode()


def dispatcher_block(rng, n_endpoints, n_events, t0):
    """A full 20000-event simulate block with flaky endpoints.

    Each endpoint subscribes to one or two event types, so an event matches
    about two to three endpoints. Endpoint scripts
    include long failure runs, timeouts and 410s, so many deliveries go through
    the whole retry ladder and the pending queue stays large.
    """
    kinds = ['invoice.paid', 'invoice.failed', 'user.created', 'user.updated',
             'order.shipped', 'order.refunded', 'payment.captured']
    scripts = ['200', '500,200', '500,500,200', 'timeout,timeout,timeout,200',
               '429,429,429,429,200', '503,503,503,503,503,503,503,503',
               '500,500,500,500,500,410', 'timeout,500,timeout,500,timeout,500,200',
               '200,500,200,500,500,200', '502,502,200', '404,404,404,200',
               ','.join(['500'] * 40 + ['200'])]
    lines = ['simulate']
    for e in range(n_endpoints):
        secrets = ','.join(make_secret(rng)[0] for _ in range(rng.choice([1, 1, 2])))
        filt = ','.join(rng.sample(kinds, rng.choice([1, 1, 1, 2])))
        lines.append('endpoint hook_%02d %s %s %s' % (e, secrets, filt, rng.choice(scripts)))
    for i in range(n_events):
        kind, body = small_body(rng, i)
        lines.append('event ev_%05d %d %s %s'
                     % (i, t0 + rng.randrange(0, 172800), kind, hexs(body)))
    lines.append('end')
    return lines


def api_traffic(rng, count):
    """Interleaved single commands a webhook service handles between batches."""
    secrets = [make_secret(rng) for _ in range(8)]
    lines = []
    for i in range(count):
        kind, body = small_body(rng, i)
        r = rng.random()
        s, key = secrets[rng.randrange(len(secrets))]
        msg_id = 'msg_%07d' % i
        ts = 1700000000 + i
        if r < 0.35:
            sig = signature(key, msg_id, str(ts), body)
            lines.append('verify %s %s %d %d %s %s'
                         % (s, msg_id, ts, ts + rng.randrange(0, 30), hexs(sig.encode()),
                            hexs(body)))
        elif r < 0.55:
            lines.append('sign %s %s %d %s' % (s, msg_id, ts, hexs(body)))
        elif r < 0.65:
            lines.append('secret ' + s)
        elif r < 0.75:
            lines.append('b64enc ' + hexs(body))
        elif r < 0.85:
            lines.append('b64dec ' + hexs(base64.urlsafe_b64encode(body).rstrip(b'=')))
        elif r < 0.93:
            lines.append('hmac %s %s' % (key.hex(), hexs(body)))
        else:
            lines.append('sha256 ' + hexs(body))
    return lines


def dispatcher_mixed(seed):
    rng = random.Random(seed)
    lines = []
    lines += api_traffic(rng, 5000)
    lines += dispatcher_block(rng, 12, 20000, 1700000000)
    lines += api_traffic(rng, 5000)
    return lines


CASES = [
    ('001_gateway_sign_verify', lambda: gateway_stream(1001, 380)),
    ('002_simulate_fanout', lambda: fanout_block(2002, 64, 150)),
    ('003_dispatcher_mixed', lambda: dispatcher_mixed(3003)),
]


def fanout_sessions(seed, n_blocks):
    """Long tier: n_blocks independent fan-out blocks, each like 002's."""
    lines = []
    for k in range(n_blocks):
        lines += fanout_block(seed + k, 64, 150)
    return lines


def dispatcher_sessions(seed, n_sessions):
    """Long tier: n_sessions dispatcher sessions, each like 003's."""
    lines = []
    for k in range(n_sessions):
        lines += dispatcher_mixed(seed + k)
    return lines


# Long tier (--long, written to ../bench-long).
LONG_CASES = [
    ('001_gateway_sign_verify', lambda: gateway_stream(1001, 1200)),
    ('002_simulate_fanout', lambda: fanout_sessions(2002, 14)),
    ('003_dispatcher_mixed', lambda: dispatcher_sessions(3003, 3)),
]


def main():
    want_expected = '--no-expected' not in sys.argv
    long_tier = '--long' in sys.argv
    out_dir = os.path.join(PROBLEM, 'bench-long') if long_tier else HERE
    os.makedirs(out_dir, exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith('--')]
    for name, build in (LONG_CASES if long_tier else CASES):
        if only and not any(o in name for o in only):
            continue
        text = '\n'.join(build()) + '\n'
        with open(os.path.join(out_dir, name + '.in'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
        msg = '%-28s %8.2f MB in' % (name, len(text) / 1e6)
        if want_expected:
            proc = subprocess.run([sys.executable, REF], input=text.encode(), capture_output=True)
            if proc.returncode != 0:
                sys.exit('reference failed on %s: %s' % (name, proc.stderr.decode()[-2000:]))
            with open(os.path.join(out_dir, name + '.out'), 'wb') as f:
                f.write(proc.stdout)
            msg += ' %8.2f MB out' % (len(proc.stdout) / 1e6)
        print(msg)


if __name__ == '__main__':
    main()
