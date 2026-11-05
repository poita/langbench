#!/usr/bin/env python3
"""Generates tests/NNN_name/{input,expected} for the `mime` problem.

Every test input is an embedded literal, a file copied from the vendored
corpora in corpus/, or a mailbox generated from fixed seeds by the
benchmark's message builders (bench/gen_bench.py), so re-running this script
reproduces the suite exactly. Expected outputs are produced by reference/main.py and every message
is cross-checked against Python's `email` package, which the reference itself
never uses:

  * `email.message_from_bytes` (compat32) supplies the MIME tree, the header
    list, the content types, boundaries, preamble and epilogue, and the
    transfer-decoded bytes of every leaf part;
  * the same parser with `policy.default` supplies RFC 2047 decoded header
    text, parsed addresses and RFC 2231 filenames;
  * `email.utils.parsedate_to_datetime` supplies dates;
  * `zlib.adler32`, `binascii.a2b_base64` and Python's own codecs supply the
    checksum, base64 and charset tables.

Every part of every message is compared, not just the root: header names and
raw values, decoded unstructured headers, addresses, the date, the content
type, charset, filename, boundary, preamble and epilogue lengths, the child
count, and the decoded bytes and Adler-32 of every leaf.

Any disagreement aborts the run. A corpus message whose shape the oracle
models differently from SPEC.md (see SKIP_REASONS) is dropped from the corpus
instead; hand-written tests may only hit a skip that is listed in ALLOW_SKIP,
and each of those is pinned by an explicit assertion in check_pinned_cases().

    python3 gen_tests.py
"""
import binascii
import datetime
import email
import email.policy
import email.utils
import os
import random
import re
import shutil
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
CORPUS = os.path.join(HERE, 'corpus')

sys.path.insert(0, os.path.join(HERE, 'reference'))
import main as ref  # noqa: E402

sys.path.insert(0, os.path.join(HERE, 'bench'))
import gen_bench as synth  # noqa: E402

# Generated mailboxes, from the benchmark's message builders with their own
# seeds: (name, seed, messages, builders cycled through in order).
SYNTHETIC_MBOXES = [
    ('034_list_traffic_mbox', 2004, 320, [synth.mailing_list_message]),
    ('035_business_mail_mbox', 2007, 90, [synth.rich_message]),
    ('036_mixed_mailbox', 2025, 300, [synth.mailing_list_message,
                                     synth.header_heavy_message,
                                     synth.mailing_list_message,
                                     synth.rich_message]),
]


class Mismatch(Exception):
    """The reference and the oracle disagree: the run must stop."""


class Skip(Exception):
    """The message is outside what SPEC.md defines; drop it from the corpus."""


SKIP_REASONS = {
    'composite-cte': 'base64/quoted-printable on a multipart or message part',
    'message-subtype': 'a message/* part other than message/rfc822',
    'base64-remainder-1': 'base64 payload with 4k+1 alphabet characters',
    'cp1252-undefined': 'a byte with no cp1252 mapping',
    'date-oracle': 'the oracle parses the Date differently',
    'address-oracle': 'the oracle parses an address differently',
    'header-oracle': 'the oracle decodes a header differently',
    'header-block-oracle': 'the oracle skips a malformed header line and keeps '
                           'reading the header block',
    'filename-oracle': 'the oracle assembles a filename differently',
    'ctype-oracle': 'the oracle resolves a content type differently',
    'tree-oracle': 'the two oracle policies build different trees',
    'folded-param': 'a Content-Type parameter folded across lines, which the '
                    'oracle leaves folded and SPEC.md unfolds',
    'no-open-delimiter': 'a multipart body whose first delimiter closes it, '
                         'which the oracle treats as a leaf',
    'adjacent-delimiters': 'two delimiter lines in a row, which the oracle '
                           'collapses and SPEC.md turns into an empty part',
    'boundary-nonascii': 'a boundary parameter holding a byte above 0x7F, '
                         'which the oracle re-decodes with `replace` and then '
                         'never matches against the body',
}

# Hand-written tests that deliberately exercise a shape the oracle models
# differently; each is pinned by an assertion in check_pinned_cases().
ALLOW_SKIP = {
    '013_multipart_degenerate': {'no-open-delimiter'},
    '017_addresses_odd': {'address-oracle'},
    '018_dates': {'date-oracle'},
    '020_message_other': {'message-subtype'},
    '026_oracle_divergences': {'folded-param', 'adjacent-delimiters',
                               'header-block-oracle', 'filename-oracle'},
    '027_ambiguities': {'address-oracle', 'filename-oracle', 'date-oracle',
                        'boundary-nonascii'},
}


def check(cond, what):
    if not cond:
        raise Mismatch(what)


def skip(reason):
    raise Skip(reason)


def fix(s):
    """Undo the oracle's surrogateescape and apply SPEC.md's UTF-8 rule."""
    return s.encode('utf-8', 'surrogateescape').decode('utf-8', 'replace')


def header_text(value):
    """The oracle's raw header value as text.

    compat32 hands back an `email.header.Header` instead of a string when the
    field carries bytes above 0x7F; its chunks hold the surrogate-escaped text.
    """
    if isinstance(value, str):
        return value
    return ''.join(chunk for chunk, _charset in value._chunks)


def unfolded(s):
    """The oracle keeps the folding line breaks; SPEC.md removes them."""
    return ref.collapse(fix(header_text(s)).replace('\r', '').replace('\n', ''))


def oracle_decode(data, charset):
    """Decode bytes with Python's codecs, following SPEC.md's charset table."""
    cs = ref.norm_charset(charset)
    if cs in ref.UTF8_NAMES:
        return data.decode('utf-8', 'replace')
    if cs in ref.ASCII_NAMES:
        return data.decode('ascii', 'replace')
    if cs in ref.LATIN1_NAMES:
        return data.decode('latin-1')
    for b in data:
        if b in (0x81, 0x8D, 0x8F, 0x90, 0x9D):
            skip('cp1252-undefined')
    return data.decode('cp1252')


# ---------------------------------------------------------------------------
# Per-message cross-check
# ---------------------------------------------------------------------------

def adjacent_delimiters(body, boundary):
    """True when an opening delimiter line is followed by another delimiter.

    The oracle drops the empty part between them; SPEC.md keeps it.
    """
    marker = b'--' + boundary.encode('utf-8', 'surrogateescape')
    kinds = [ref.delimiter_kind(line, marker) for line in body.split(b'\n')]
    return any(kinds[i] == 'open' and kinds[i + 1] is not None
               for i in range(len(kinds) - 1))


def header_block_stop(raw):
    """The line that ends a part's header block, or None when a blank one does."""
    for index, line in enumerate(raw.split(b'\n')):
        if not line:
            return None
        if index > 0 and line[:1] in (b' ', b'\t'):
            continue
        if ref.field_colon(line) is None:
            return line
    return None


def oracle_payload(pm):
    """The transfer-decoded bytes of a leaf part, as the oracle sees them."""
    data = pm.get_payload(decode=True)
    return b'' if data is None else data


def cmp_part(part, pm, dm):
    """Compare one part of the reference tree with the oracle's."""
    cmp_headers(part, pm, dm)
    ptype = pm.get_content_type()
    if part.ctype != ptype:
        skip('ctype-oracle')
    if part.cte in ('base64', 'quoted-printable') and part.kind != 'leaf':
        skip('composite-cte')
    if part.kind == 'leaf' and ptype.startswith('message/') and pm.is_multipart():
        skip('message-subtype')

    if part.cte == 'base64' and part.kind == 'leaf':
        alphabet = sum(1 for c in pm.get_payload() if c in ref.B64_VALUE)
        if alphabet % 4 == 1:
            skip('base64-remainder-1')

    # Filenames and charsets come from the policy.default tree.
    oracle_name = dm.get_filename()
    if oracle_name is not None:
        oracle_name = fix(oracle_name)
    if part.filename != oracle_name:
        # The oracle keeps a filename the reference reports as absent only
        # when neither Content-Disposition nor Content-Type carried one.
        skip('filename-oracle')
    if part.ctype.startswith('text/'):
        oracle_charset = pm.get_content_charset()
        mine = ref.charset_of(part)
        if oracle_charset is None:
            check(mine == 'us-ascii', 'default charset %r' % mine)
        else:
            check(mine == ref.norm_charset(fix(oracle_charset)),
                  'charset %r vs %r' % (mine, oracle_charset))

    if part.kind == 'multipart':
        boundary = fix(pm.get_boundary() or '')
        if '\n' in boundary or '\r' in boundary:
            skip('folded-param')
        if any(ord(c) > 0x7F for c in part.boundary):
            # compat32 re-decodes the boundary parameter with `replace`, so a
            # byte above 0x7F becomes U+FFFD there and the oracle then finds
            # no delimiter at all. SPEC.md matches the UTF-8 encoding of the
            # boundary against the body bytes.
            skip('boundary-nonascii')
        check(part.boundary == boundary, 'boundary %r' % part.boundary)
        if adjacent_delimiters(part.body, part.boundary):
            skip('adjacent-delimiters')
        if not pm.is_multipart():
            # The oracle found no opening delimiter and kept the raw body. It
            # does that for a body with no delimiter at all, which SPEC.md
            # models the same way, and also for a body whose first delimiter
            # is a close delimiter, which SPEC.md does not.
            check(not part.children, 'unexpected children')
            if (part.depth > 0 or part.epilogue is not None
                    or part.preamble != len(part.body)):
                # Inside a container the oracle hands back the part's lines
                # rejoined, which restores a line ending the delimiter scan
                # had removed, so only the whole message can be compared.
                skip('no-open-delimiter')
            check(part.preamble == len(oracle_payload(pm)),
                  'preamble %d vs %d' % (part.preamble, len(oracle_payload(pm))))
            return
        children = pm.get_payload()
        dchildren = dm.get_payload()
        if not dm.is_multipart() or len(dchildren) != len(children):
            # The two oracle policies disagree about the tree itself.
            skip('tree-oracle')
        check(len(part.children) == len(children),
              'child count %d vs %d' % (len(part.children), len(children)))
        preamble = b'' if pm.preamble is None else pm.preamble.encode(
            'utf-8', 'surrogateescape')
        check(part.preamble == len(preamble),
              'preamble %d vs %d' % (part.preamble, len(preamble)))
        # The oracle reports an epilogue of None both for a missing close
        # delimiter and for a close delimiter that ends a nested part's body,
        # so only a non-empty epilogue can be compared byte for byte.
        epilogue = (None if pm.epilogue is None
                    else pm.epilogue.encode('utf-8', 'surrogateescape'))
        if not epilogue:
            check(part.epilogue in (None, 0),
                  'epilogue %r vs empty' % (part.epilogue,))
        else:
            check(part.epilogue == len(epilogue),
                  'epilogue %r vs %d' % (part.epilogue, len(epilogue)))
        for mine, theirs, dtheirs in zip(part.children, children, dchildren):
            cmp_part(mine, theirs, dtheirs)
    elif part.kind == 'message':
        check(pm.is_multipart() and len(pm.get_payload()) == 1,
              'message/rfc822 payload')
        cmp_part(part.children[0], pm.get_payload()[0], dm.get_payload()[0])
    else:
        check(not pm.is_multipart(), 'leaf vs container')
        payload = oracle_payload(pm)
        check(part.content == payload,
              'content %d vs %d bytes' % (len(part.content), len(payload)))
        check('%08x' % ref.adler32(part.content) == '%08x' % zlib.adler32(payload),
              'adler32')
        if part.ctype.startswith('text/'):
            charset = ref.charset_of(part)
            check(ref.decode(payload, charset) == oracle_decode(payload, charset),
                  'charset decode for %s' % charset)


# Header names the oracle also models as unstructured text, so that its
# rendering can be compared with decode_unstructured. Address headers are
# excluded: policy.default re-renders them as addresses, adding quoting that
# SPEC.md's unstructured decoding never introduces; cmp_addresses checks those.
ORACLE_HEADERS = ('subject', 'comments', 'content-description',
                  'content-location', 'organization')


def unstructured_header(key):
    return key in ORACLE_HEADERS or key.startswith('x-')


def cmp_headers(part, pm, dm):
    # SPEC.md ends the header block at the first line that is neither a
    # continuation nor a field; the oracle skips such a line and keeps reading
    # when it still looks like a field (an empty name) or like an mbox
    # envelope line.
    stop = header_block_stop(part.raw)
    if stop is not None and (stop.startswith(b':') or stop.startswith(b'From ')):
        skip('header-block-oracle')
    items = pm.items()
    check(len(part.fields) == len(items),
          'header count %d vs %d' % (len(part.fields), len(items)))
    for (name, value), (oname, ovalue) in zip(part.fields, items):
        check(name.strip(' \t').lower() == oname.lower(),
              'header name %r vs %r' % (name, oname))
        check(ref.collapse(value) == unfolded(ovalue),
              'header value %r vs %r' % (value, ovalue))
    seen = set()
    for name, value in part.fields:
        key = name.strip(' \t').lower()
        if not unstructured_header(key) or key in seen:
            continue
        seen.add(key)
        try:
            decoded = unfolded(str(dm[key]))
        except Exception:
            continue
        if ref.collapse(ref.decode_unstructured(value)) != decoded:
            skip('header-oracle')


def cmp_addresses(part, dm):
    for field in ref.ADDRESS_FIELDS:
        values = [v for n, v in part.fields if n.strip(' \t').lower() == field]
        if not values:
            continue
        mine = []
        for value in values:
            mine.extend(ref.parse_address_list(value))
        try:
            headers = dm.get_all(field, [])
            theirs = []
            for header in headers:
                theirs.extend((fix(a.display_name), fix(a.addr_spec))
                              for a in header.addresses)
        except Exception:
            skip('address-oracle')
        if len(mine) != len(theirs):
            skip('address-oracle')
        for (md, ms), (td, ts) in zip(mine, theirs):
            if ts in ('', '<>'):
                # The oracle gives up on this element; SPEC.md defines its own
                # recovery, which the hand-written tests pin down.
                continue
            if ref.collapse(md) != unfolded(td) or ms != unfolded(ts):
                skip('address-oracle')


def cmp_date(part):
    raw = ref.find_field(part.fields, 'date')
    if raw is None:
        return
    mine = ref.parse_date(raw)
    try:
        theirs = email.utils.parsedate_to_datetime(raw)
        if theirs.tzinfo is None:
            # The oracle drops the zone for `-0000`, which RFC 5322 reads as
            # "zone unknown"; SPEC.md reads it as an offset of zero.
            theirs = theirs.replace(tzinfo=datetime.timezone.utc)
        their_epoch = int(theirs.timestamp())
    except Exception:
        their_epoch = None
    if mine is None:
        if their_epoch is not None:
            skip('date-oracle')
        return
    if their_epoch is None or their_epoch != mine[0]:
        skip('date-oracle')


def crosscheck(raw):
    """Cross-check one message; raises Mismatch or Skip."""
    data = raw.replace(b'\r\n', b'\n')
    state = {'next': 0, 'depth': 0}
    root = ref.parse_part(data, 'text/plain', state)
    pm = email.message_from_bytes(data)
    dm = email.message_from_bytes(data, policy=email.policy.default)
    cmp_addresses(root, dm)
    cmp_date(root)
    cmp_part(root, pm, dm)


# ---------------------------------------------------------------------------
# Standalone cross-checks of the primitive decoders
# ---------------------------------------------------------------------------

def check_primitives():
    rng = random.Random(20260921)
    for _ in range(4000):
        n = rng.randrange(0, 12)
        data = bytes(rng.randrange(0, 256) for _ in range(n))
        check(ref.decode_utf8(data) == data.decode('utf-8', 'replace'),
              'utf-8 decode of %r' % data)
        check('%08x' % ref.adler32(data) == '%08x' % zlib.adler32(data),
              'adler32 of %r' % data)
    for text in ('', 'hello world', 'x' * 61, '\x00\xff\x80' * 7):
        raw = text.encode('utf-8')
        encoded = binascii.b2a_base64(raw).decode('ascii')
        check(ref.decode_base64(encoded) == raw, 'base64 of %r' % text)
        wrapped = '\n'.join(encoded[i:i + 4] for i in range(0, len(encoded), 4))
        check(ref.decode_base64(wrapped) == raw, 'wrapped base64 of %r' % text)
    for y in range(1, 2400):
        for m, d in ((1, 1), (2, 28), (3, 1), (12, 31)):
            days = ref.days_from_civil(y, m, d)
            check(ref.civil_from_days(days) == (y, m, d),
                  'civil round trip %d-%d-%d' % (y, m, d))
    import datetime
    for days in range(-20000, 20000, 7):
        y, m, d = ref.civil_from_days(days)
        real = datetime.date(1970, 1, 1) + datetime.timedelta(days=days)
        check((y, m, d) == (real.year, real.month, real.day),
              'civil_from_days %d' % days)
    for value, expected in (
            ('=?utf-8?Q?caf=C3=A9?=', 'café'),
            ('=?utf-8?Q?a?=   =?utf-8?Q?b?=', 'ab'),
            ('x =?utf-8?Q?a?= y', 'x a y'),
            ('=?utf-8?Q?a?=b', 'ab'),
            ('=?iso-8859-1?Q?caf=E9?=', 'café'),
            ('=?windows-1252?Q?smart=92quote?=', 'smart’quote'),
            ('=?utf-8?B?SsO2cmc=?=', 'Jörg'),
            ('=?utf-8*en?Q?hi?=', 'hi'),
            ('=?utf-8?X?hi?=', '=?utf-8?X?hi?='),
            ('  plain    spaced   text  ', 'plain    spaced   text'),
            ('=?utf-8?Q?a?= \t =?utf-8?Q?b?= \t c', 'ab \t c')):
        got = ref.decode_unstructured(value)
        check(got == expected, 'decode_unstructured(%r) = %r' % (value, got))


def check_pinned_cases():
    """Pin the behaviours the oracle models differently from SPEC.md."""
    # message/delivery-status is a leaf whose content is its raw body.
    raw = (b'Content-Type: multipart/report; boundary="R"\n\n--R\n'
           b'Content-Type: message/delivery-status\n\n'
           b'Action: failed\n--R--\n')
    state = {'next': 0, 'depth': 0}
    root = ref.parse_part(raw, 'text/plain', state)
    check(len(root.children) == 1, 'report child count')
    child = root.children[0]
    check(child.kind == 'leaf' and child.content == b'Action: failed',
          'delivery-status content %r' % child.content)

    # A malformed addr-spec falls back to the concatenated element text.
    check(ref.parse_address_list('broken <a@@b>') == [('', 'broken<a@@b>')],
          'malformed address fallback')
    check(ref.parse_address_list('Undisclosed recipients:;') == [],
          'empty group')
    check(ref.parse_address_list('a@b.com.') == [('', 'a@b.com.')],
          'trailing dot address')

    # Unfolding joins the lines of a field with nothing between them, so a
    # boundary folded inside its quoted string closes up again.
    raw = (b'Content-Type: multipart/mixed; boundary="simple\n boundary"\n\n'
           b'--simple boundary\n\nfirst\n--simple boundary--\n')
    state = {'next': 0, 'depth': 0}
    root = ref.parse_part(raw, 'text/plain', state)
    check(root.boundary == 'simple boundary', 'folded boundary %r' % root.boundary)
    check(len(root.children) == 1, 'folded boundary child count')

    # Two delimiter lines in a row bound an empty part.
    raw = (b'Content-Type: multipart/mixed; boundary="B"\n\n'
           b'--B\n--B\nContent-Type: text/plain\n\nsecond\n--B--\n')
    state = {'next': 0, 'depth': 0}
    root = ref.parse_part(raw, 'text/plain', state)
    check(len(root.children) == 2, 'adjacent delimiter child count')
    check(root.children[0].content == b'', 'empty part content')

    # The header block ends at the first line that is not a field or a
    # continuation, whatever that line looks like.
    raw = (b'Subject :obsolete\nX-Real: never seen\n\nbody\n')
    state = {'next': 0, 'depth': 0}
    root = ref.parse_part(raw, 'text/plain', state)
    check(root.fields == [], 'obsolete header syntax')
    check(root.body == raw, 'obsolete header body')

    # An unquoted parameter value keeps the spaces inside it.
    value, params = ref.parse_structured(' attachment; filename=two words.bin')
    check(ref.assemble_params(params)['filename'] == 'two words.bin',
          'unquoted parameter with spaces')

    # Obsolete two- and three-digit years and named zones.
    check(ref.parse_date('3 Jan 70 00:00:00 GMT') == (172800, 0), 'two-digit year')
    check(ref.parse_date('3 Jan 105 00:00:00 -0500')[1] == -300, 'three-digit year')
    check(ref.parse_date('Tue, 1 Jan 2036 00:00:60 +0000')[0] == 2082758460,
          'leap second')
    check(ref.parse_date('not a date') is None, 'invalid date')
    check(ref.parse_date('31 Feb 2004 00:00:00 +0000') is None, 'invalid day')

    # A four-digit zone can express more than 99 hours, and the rendering then
    # grows past four digits.
    epoch, offset = ref.parse_date('Sat, 1 Jan 2000 00:00:00 +9999')
    check((offset, ref.format_offset(offset)) == (6039, '+10039'),
          'huge zone offset %r' % (offset,))
    check(ref.format_utc(epoch) == '1999-12-27T19:21:00Z', 'huge zone utc')
    # Converting a negative epoch back needs flooring division.
    check(ref.format_utc(-26204400) == '1969-03-03T17:00:00Z', 'negative epoch')

    # `<` nests: the comma inside the outer angle brackets does not split.
    check(ref.parse_address_list('a <b <c@d.com> , e@f.com>, g@h.com')
          == [('', 'a<b<c@d.com>,e@f.com>'), ('', 'g@h.com')],
          'nested angle brackets')
    # A comment contributes one space on top of the blanks around it, and the
    # assembled phrase is stripped.
    check(ref.parse_address_list('John (the third) Public <jqp@x.com>')
          == [('John   Public', 'jqp@x.com')], 'mid-phrase comment')
    check(ref.parse_address_list('=?utf-8?Q?a?= (c) =?utf-8?Q?b?= <ab@x.com>')
          == [('a   b', 'ab@x.com')], 'comment between encoded words')

    # A `\` in a quoted string consumes the character after it, so the `"`
    # that follows `\\` closes the string.
    value, params = ref.parse_structured(
        ' attachment; filename="a\\\\"; creation-date="x"')
    built = ref.assemble_params(params)
    check(built['filename'] == 'a\\' and built['creation-date'] == 'x',
          'escaped backslash in a quoted parameter %r' % built)
    # A trailing `\` has no character to escape and stands for itself.
    value, params = ref.parse_structured(' attachment; filename="abc\\')
    check(ref.assemble_params(params)['filename'] == 'abc\\',
          'trailing backslash in an unterminated quoted string')

    # An empty extended charset means us-ascii, not the cp1252 fallback.
    value, params = ref.parse_structured(" attachment; filename*=''caf%E9.txt")
    check(ref.assemble_params(params)['filename'] == 'caf\ufffd.txt',
          'empty extended charset')
    # Segments are ordered numerically, leading zeros and all, gaps skipped.
    value, params = ref.parse_structured(
        ' attachment; filename*10=j; filename*2=c; filename*0=a;'
        ' filename*1=b; filename*07=h')
    check(ref.assemble_params(params)['filename'] == 'abchj',
          'numeric segment order')
    # A name that starts with `*` is a plain parameter under its own name.
    value, params = ref.parse_structured(' x; *0=a; *1=b')
    check(ref.assemble_params(params) == {'*0': 'a', '*1': 'b'},
          'star-prefixed parameter names')

    # The boundary is matched as its UTF-8 encoding, so a boundary parameter
    # that held bytes which are not valid UTF-8 never matches the body.
    raw = (b'Content-Type: multipart/mixed; boundary="b\xe9"\n\n'
           b'--b\xe9\nContent-Type: text/plain\n\nfirst\n--b\xe9--\n')
    state = {'next': 0, 'depth': 0}
    root = ref.parse_part(raw, 'text/plain', state)
    check(root.boundary == 'b\ufffd' and not root.children,
          'boundary with bytes that are not valid UTF-8')
    raw = ('Content-Type: multipart/mixed; boundary="b\u00e9"\n\n'
           '--b\u00e9\nContent-Type: text/plain\n\nfirst\n'
           '--b\u00e9--\n').encode('utf-8')
    state = {'next': 0, 'depth': 0}
    root = ref.parse_part(raw, 'text/plain', state)
    check(root.boundary == 'b\u00e9' and len(root.children) == 1,
          'boundary with valid UTF-8 bytes')


# ---------------------------------------------------------------------------
# Building tests
# ---------------------------------------------------------------------------

def mbox_body(message):
    """Normalise a message so that it round-trips through an mbox."""
    return message if message.endswith(b'\n') else message + b'\n'


def make_mbox(messages, senders=None):
    out = bytearray()
    for k, message in enumerate(messages):
        sender = (senders[k] if senders else
                  b'From nobody@localhost Mon Jan  1 00:00:00 2001')
        out += sender + b'\n' + mbox_body(message) + b'\n'
    return bytes(out)


def emit(name, files=None, mbox=None, senders=None):
    """Write one test case: its input tree and its expected output tree."""
    case = os.path.join(TESTS, name)
    if os.path.isdir(case):
        shutil.rmtree(case)
    os.makedirs(case)
    allowed = ALLOW_SKIP.get(name, set())
    if mbox is not None:
        messages = [mbox_body(m) for m in mbox]
        with open(os.path.join(case, 'input'), 'wb') as f:
            f.write(make_mbox(messages, senders))
        raws = messages
    else:
        os.makedirs(os.path.join(case, 'input'))
        for filename, data in files:
            with open(os.path.join(case, 'input', filename), 'wb') as f:
                f.write(data)
        raws = [data for _, data in files]
    skipped = []
    for k, raw in enumerate(raws):
        try:
            crosscheck(raw)
        except Skip as exc:
            reason = str(exc)
            if reason not in allowed:
                raise Mismatch('%s message %d: unallowed skip %r (%s)'
                               % (name, k + 1, reason, SKIP_REASONS[reason]))
            skipped.append(reason)
    out_dir = os.path.join(case, 'expected')
    os.makedirs(out_dir)
    rc = ref.main(['main.py', os.path.join(case, 'input'), out_dir])
    check(rc == 0, 'reference exit %d for %s' % (rc, name))
    size = sum(os.path.getsize(os.path.join(dp, f))
               for dp, _dn, fn in os.walk(case) for f in fn)
    note = (' [%d oracle skips]' % len(skipped)) if skipped else ''
    print('%-34s %5d messages %8.1f KB%s' % (name, len(raws), size / 1024, note))


def keep_messages(raws, label):
    """Drop the corpus messages whose shape SPEC.md does not model."""
    kept, dropped = [], {}
    for raw in raws:
        try:
            crosscheck(raw)
        except Skip as exc:
            dropped[str(exc)] = dropped.get(str(exc), 0) + 1
            continue
        kept.append(raw)
    if dropped:
        detail = ', '.join('%s x%d' % (k, v) for k, v in sorted(dropped.items()))
        print('  %-30s kept %3d of %3d (%s)'
              % (label, len(kept), len(raws), detail))
    return kept


def strip_envelope(data):
    """Drop a leading mbox `From ` envelope line.

    Several corpus messages were saved straight out of an mbox and kept the
    separator line, which belongs to the mailbox rather than to the message.
    """
    if data.startswith(b'From '):
        nl = data.find(b'\n')
        return b'' if nl < 0 else data[nl + 1:]
    return data


def corpus_files(subdir, suffix):
    directory = os.path.join(CORPUS, subdir)
    names = sorted(n for n in os.listdir(directory) if n.endswith(suffix))
    out = []
    for name in names:
        with open(os.path.join(directory, name), 'rb') as f:
            out.append((name, strip_envelope(f.read())))
    return out


def eml_name(name):
    """Map a corpus file name onto the .eml naming the tests use."""
    stem = name.rsplit('.', 1)[0]
    stem = ''.join(c if (c.isalnum() or c in '._+-') else '-' for c in stem)
    return stem + '.eml'


# ---------------------------------------------------------------------------
# Hand-written messages
# ---------------------------------------------------------------------------

def hand_written():
    """Return the hand-written test cases as (name, kwargs) pairs."""
    cases = []

    cases.append(('001_single_plain', dict(files=[
        ('plain.eml',
         b'From: ann@example.com\n'
         b'To: bob@example.org\n'
         b'Subject: hello\n'
         b'Date: Mon, 1 Sep 2025 12:30:00 +0200\n'
         b'\n'
         b'Hello, world.\n'),
    ])))

    cases.append(('002_degenerate', dict(files=[
        ('empty.eml', b''),
        ('headers-only.eml', b'Subject: no body\n'),
        ('headers-only-blank.eml', b'Subject: no body\n\n'),
        ('body-only.eml', b'\njust a body\n'),
        ('no-newline.eml', b'Subject: x\n\nno trailing newline'),
        ('blank-first.eml', b'\n'),
    ])))

    cases.append(('003_folding', dict(files=[
        ('folded.eml',
         b'Subject: a long subject\n that was folded\n\tand folded again\n'
         b'X-Empty:\n'
         b'X-Nospace:value\n'
         b'X-Spaced:   lots   of   space   \n'
         b'X-Dup: first\n'
         b'X-Dup: second\n'
         b'\n'
         b'body\n'),
        ('bad-separator.eml',
         b'Subject: ok\n'
         b'this line has no colon\n'
         b'Subject: never seen\n'
         b'\n'
         b'body\n'),
        ('odd-names.eml',
         b'X-a_b.c: dotted name\n'
         b'X-99: digits\n'
         b'CONTENT-TYPE: TEXT/PLAIN; CHARSET=US-ASCII\n'
         b'\nbody\n'),
    ])))

    cases.append(('004_encoded_words', dict(files=[
        ('q.eml',
         b'Subject: =?utf-8?Q?Caf=C3=A9_=E2=9C=93?=\n'
         b'X-One: =?iso-8859-1?Q?caf=E9?=\n'
         b'X-Two: =?windows-1252?Q?smart=92quote?=\n'
         b'\nbody\n'),
        ('b.eml',
         b'Subject: =?utf-8?B?SsO2cmc=?= =?utf-8?B?IHNheXM=?=\n'
         b'X-Lower: =?utf-8?b?aGVsbG8=?= and =?utf-8?q?there?=\n'
         b'\nbody\n'),
        ('mixed.eml',
         b'Subject: Re: =?utf-8?B?4pyT?= done\n'
         b'X-Glued: =?utf-8?Q?a?=b and a=?utf-8?Q?b?=\n'
         b'X-Lang: =?utf-8*en?Q?hi?= there\n'
         b'X-Broken: =?utf-8?X?hi?= =?utf-8?Q?ok?=\n'
         b'X-Spaces: =?utf-8?Q?a?=   =?utf-8?Q?b?=   c\n'
         b'\nbody\n'),
    ])))

    cases.append(('005_worked_example', dict(mbox=[
        b'Subject: =?utf-8?Q?Caf=C3=A9?= report\n'
        b'From: Ann Example <ann@example.com>\n'
        b'To: bob@example.org, Carl <carl@example.org>\n'
        b'Date: Mon, 1 Sep 2025 12:30:00 +0200\n'
        b'MIME-Version: 1.0\n'
        b'Content-Type: multipart/mixed; boundary="X"\n'
        b'\n'
        b'ignore me\n'
        b'--X\n'
        b'Content-Type: text/plain; charset=iso-8859-1\n'
        b'\n'
        b'caf\xe9\n'
        b'--X\n'
        b'Content-Type: application/octet-stream\n'
        b'Content-Disposition: attachment; filename="a.bin"\n'
        b'Content-Transfer-Encoding: base64\n'
        b'\n'
        b'AAECAw==\n'
        b'--X--\n',
    ], senders=[b'From nobody Mon Sep  1 00:00:00 2025'])))

    def body(ctype, payload, cte=None):
        out = b'Content-Type: ' + ctype + b'\n'
        if cte:
            out += b'Content-Transfer-Encoding: ' + cte + b'\n'
        return out + b'\n' + payload

    cases.append(('006_charsets', dict(files=[
        ('latin1.eml', body(b'text/plain; charset=iso-8859-1',
                            b'caf\xe9 na\xefve \xa9 1999\n')),
        ('cp1252.eml', body(b'text/plain; charset=windows-1252',
                            b'\x93quoted\x94 \x97 dash \x85 \x80\n')),
        ('ascii8bit.eml', body(b'text/plain; charset=us-ascii',
                               b'plain then \xe9\xff raw\n')),
        ('nocharset.eml', body(b'text/plain', b'ascii only\n')),
        ('unknown.eml', body(b'text/plain; charset=x-made-up',
                             b'fallback is cp1252\n')),
        ('upper.eml', body(b'TEXT/PLAIN; CHARSET=UTF-8',
                           b'\xc3\xa9\xc3\xa8\xc3\xaa\n')),
        ('quoted-charset.eml', body(b'text/plain; charset="ISO-8859-1"',
                                    b'caf\xe9\n')),
    ])))

    cases.append(('007_utf8_invalid', dict(files=[
        ('truncated.eml', body(b'text/plain; charset=utf-8',
                               b'start \xf0\x9f')),
        ('interrupted.eml', body(b'text/plain; charset=utf-8',
                                 b'a\xe2\x28\xa1b\n')),
        ('overlong.eml', body(b'text/plain; charset=utf-8',
                              b'\xc0\xaf\xe0\x80\xaf\n')),
        ('surrogate.eml', body(b'text/plain; charset=utf-8',
                               b'\xed\xa0\x80 and \xed\x9f\xbf\n')),
        ('toohigh.eml', body(b'text/plain; charset=utf-8',
                             b'\xf5\x80\x80\x80 \xf4\x90\x80\x80\n')),
        ('stray.eml', body(b'text/plain; charset=utf-8',
                           b'\x80\x81\xbf ok\n')),
    ])))

    cases.append(('008_quoted_printable', dict(files=[
        ('basic.eml', body(b'text/plain; charset=iso-8859-1',
                           b'caf=E9 and =3D signs\n', b'quoted-printable')),
        ('soft.eml', body(b'text/plain; charset=us-ascii',
                          b'a very long line that was=\n wrapped here\n',
                          b'quoted-printable')),
        ('odd.eml', body(b'text/plain; charset=us-ascii',
                         b'a=Zb\nc=3\nd=  \ne=0D=0Af\n',
                         b'quoted-printable')),
        ('trailing.eml', body(b'text/plain; charset=us-ascii',
                              b'trailing whitespace   \nkept=20\n',
                              b'quoted-printable')),
        ('case.eml', body(b'text/plain; charset=utf-8',
                          b'=c3=a9 and =C3=A8\n', b'QUOTED-PRINTABLE')),
    ])))

    cases.append(('009_base64', dict(files=[
        ('wrapped.eml', body(b'application/octet-stream',
                             b'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8g\n'
                             b'ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BB\n',
                             b'base64')),
        ('padded.eml', body(b'text/plain; charset=utf-8', b'aGVsbG8=\n',
                            b'base64')),
        ('nopad.eml', body(b'text/plain; charset=utf-8', b'aGVsbG8\n',
                           b'base64')),
        ('garbage.eml', body(b'text/plain; charset=utf-8',
                             b'aG *V s\tbG8=!!\n', b'base64')),
        ('empty.eml', body(b'application/octet-stream', b'\n', b'base64')),
        ('unknown-cte.eml', body(b'text/plain; charset=us-ascii',
                                 b'left alone\n', b'x-uuencode')),
    ])))

    cases.append(('010_multipart_basic', dict(files=[
        ('alternative.eml',
         b'Content-Type: multipart/alternative; boundary="alt"\n\n'
         b'--alt\nContent-Type: text/plain; charset=us-ascii\n\n'
         b'plain version\n'
         b'--alt\nContent-Type: text/html; charset=us-ascii\n\n'
         b'<p>html version</p>\n'
         b'--alt--\n'),
        ('mixed.eml',
         b'Content-Type: multipart/mixed; boundary=simple\n\n'
         b'--simple\n\nno content type here\n'
         b'--simple\nContent-Type: image/png\n'
         b'Content-Transfer-Encoding: base64\n\niVBORw==\n'
         b'--simple--\n'),
        ('spaced-delims.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B  \nContent-Type: text/plain\n\none\n'
         b'--B\t\nContent-Type: text/plain\n\ntwo\n'
         b'--B--   \n'),
        ('empty-parts.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\n\n--B\n\n--B--\n'),
    ])))

    cases.append(('011_preamble_epilogue', dict(files=[
        ('both.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'this is the preamble\nsecond line\n'
         b'--B\nContent-Type: text/plain\n\nbody\n'
         b'--B--\nepilogue line\nand another\n'),
        ('preamble-only.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'preamble\n--B\nContent-Type: text/plain\n\nbody\n--B--\n'),
        ('epilogue-only.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\nContent-Type: text/plain\n\nbody\n--B--\ntail\n'),
        ('neither.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\nContent-Type: text/plain\n\nbody\n--B--\n'),
        ('no-close.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\nContent-Type: text/plain\n\nbody runs to the end\n'),
    ])))

    cases.append(('012_multipart_nested', dict(files=[
        ('nested.eml',
         b'Subject: nested\n'
         b'Content-Type: multipart/mixed; boundary="outer"\n\n'
         b'--outer\n'
         b'Content-Type: multipart/alternative; boundary="inner"\n\n'
         b'--inner\nContent-Type: text/plain; charset=utf-8\n\n'
         b'plain \xc3\xa9\n'
         b'--inner\nContent-Type: text/html; charset=utf-8\n'
         b'Content-Transfer-Encoding: quoted-printable\n\n'
         b'<p>html =C3=A9</p>\n'
         b'--inner--\n'
         b'--outer\n'
         b'Content-Type: application/pdf; name="doc.pdf"\n'
         b'Content-Disposition: attachment; filename="doc.pdf"\n'
         b'Content-Transfer-Encoding: base64\n\n'
         b'JVBERi0xLjQK\n'
         b'--outer--\n'),
        ('prefix-boundaries.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\nContent-Type: multipart/mixed; boundary="BB"\n\n'
         b'--BB\nContent-Type: text/plain\n\ninner one\n'
         b'--BB--\n'
         b'--B\nContent-Type: text/plain\n\nouter two\n'
         b'--B--\n'),
        ('deep.eml',
         b'Content-Type: multipart/mixed; boundary="a"\n\n'
         b'--a\nContent-Type: multipart/mixed; boundary="b"\n\n'
         b'--b\nContent-Type: multipart/mixed; boundary="c"\n\n'
         b'--c\nContent-Type: text/plain\n\ndeep\n'
         b'--c--\n--b--\n--a--\n'),
    ])))

    cases.append(('013_multipart_degenerate', dict(files=[
        ('no-boundary.eml',
         b'Content-Type: multipart/mixed\n\nthe body is just text\n'),
        ('empty-boundary.eml',
         b'Content-Type: multipart/mixed; boundary=""\n\nalso just text\n'),
        ('no-delimiter.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\nnothing to see\n'),
        ('empty-body.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'),
        ('close-first.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n--B--\nafter\n'),
        ('unknown-subtype.eml',
         b'Content-Type: multipart/x-invented; boundary="B"\n\n'
         b'--B\nContent-Type: text/plain\n\nstill works\n--B--\n'),
    ])))

    cases.append(('014_filenames', dict(files=[
        ('disposition.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\nContent-Type: text/plain\n\nbody\n'
         b'--B\nContent-Type: application/octet-stream\n'
         b'Content-Disposition: attachment; filename="report.pdf"\n\ndata\n'
         b'--B\nContent-Type: application/octet-stream; name="fallback.bin"\n\n'
         b'more\n'
         b'--B\nContent-Type: application/octet-stream; name="ct.bin"\n'
         b'Content-Disposition: attachment; filename="cd.bin"\n\nboth\n'
         b'--B--\n'),
        ('quoting.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\nContent-Type: text/plain\n\nbody\n'
         b'--B\nContent-Type: application/octet-stream\n'
         b'Content-Disposition: attachment; filename="with space.txt"\n\na\n'
         b'--B\nContent-Type: application/octet-stream\n'
         b'Content-Disposition: attachment; filename=unquoted.txt\n\nb\n'
         b'--B\nContent-Type: application/octet-stream\n'
         b'Content-Disposition: attachment;\n filename="=?utf-8?Q?caf=C3=A9.txt?="\n\nc\n'
         b'--B--\n'),
        ('inline.eml',
         b'Content-Type: multipart/related; boundary="B"\n\n'
         b'--B\nContent-Type: text/html\n\n<img src="cid:x">\n'
         b'--B\nContent-Type: image/gif\nContent-ID: <x>\n'
         b'Content-Disposition: inline; filename="pic.gif"\n'
         b'Content-Transfer-Encoding: base64\n\nR0lGODlh\n'
         b'--B--\n'),
        ('attachment-text.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\nContent-Type: text/plain\n'
         b'Content-Disposition: attachment; filename="notes.txt"\n\n'
         b'this text part is an attachment, not the body\n'
         b'--B\nContent-Type: text/plain\n\nthis one is the body\n'
         b'--B--\n'),
    ])))

    cases.append(('015_rfc2231', dict(files=[
        ('extended.eml',
         b'Content-Type: application/octet-stream\n'
         b"Content-Disposition: attachment; filename*=utf-8''caf%C3%A9.txt\n"
         b'\ndata\n'),
        ('continued.eml',
         b'Content-Type: application/octet-stream\n'
         b'Content-Disposition: attachment; filename*0="a very ";\n'
         b' filename*1="long name.txt"\n'
         b'\ndata\n'),
        ('continued-extended.eml',
         b'Content-Type: application/octet-stream\n'
         b"Content-Disposition: attachment; filename*0*=utf-8'en'caf%C3%A9;\n"
         b' filename*1=" report.txt"\n'
         b'\ndata\n'),
        ('latin1-extended.eml',
         b'Content-Type: application/octet-stream\n'
         b"Content-Disposition: attachment; filename*=iso-8859-1''caf%E9.txt\n"
         b'\ndata\n'),
        ('no-charset.eml',
         b'Content-Type: application/octet-stream\n'
         b'Content-Disposition: attachment; filename*=plain%20name.txt\n'
         b'\ndata\n'),
    ])))

    cases.append(('016_addresses', dict(files=[
        ('simple.eml',
         b'From: Ann Example <ann@example.com>\n'
         b'To: bob@example.org\n'
         b'Cc: Carl <carl@example.org>, "Doe, John" <jd@example.net>\n'
         b'Reply-To: list@example.org\n'
         b'\nbody\n'),
        ('folded-list.eml',
         b'To: one@example.com,\n two@example.com,\n'
         b'\tThree Person <three@example.com>\n'
         b'\nbody\n'),
        ('encoded-names.eml',
         b'From: =?utf-8?B?SsO2cmc=?= <joerg@example.de>\n'
         b'To: =?utf-8?Q?A?= =?utf-8?Q?B?= <ab@example.com>,\n'
         b' =?iso-8859-1?Q?Ren=E9?= <rene@example.fr>\n'
         b'\nbody\n'),
        ('dots-and-quotes.eml',
         b'From: John Q. Public <jqp@example.com>\n'
         b'To: "quoted name" <qn@example.com>, plain.name@example.com\n'
         b'\nbody\n'),
        ('multiple-fields.eml',
         b'To: first@example.com\n'
         b'To: second@example.com\n'
         b'Cc: third@example.com\n'
         b'\nbody\n'),
    ])))

    cases.append(('017_addresses_odd', dict(files=[
        ('comments.eml',
         b'From: ann@example.com (Ann Example)\n'
         b'To: bob@example.org (Bob (the second) Example)\n'
         b'Cc: (leading) carl@example.org\n'
         b'\nbody\n'),
        ('groups.eml',
         b'To: Undisclosed recipients:;\n'
         b'Cc: friends: a@example.com, b@example.com;, c@example.com\n'
         b'\nbody\n'),
        ('domain-literal.eml',
         b'From: ed <ed@[10.0.0.1]>\n'
         b'To: root@[IPv6:::1]\n'
         b'\nbody\n'),
        ('malformed.eml',
         b'From: broken <a@@b>\n'
         b'To: no.at.sign, trailing@dot.com., <>\n'
         b'Cc: "unterminated <x@example.com>\n'
         b'\nbody\n'),
        ('empty-fields.eml',
         b'From:\n'
         b'To:  \n'
         b'Cc: ,,\n'
         b'\nbody\n'),
    ])))

    def dated(value):
        return b'Subject: date test\nDate: ' + value + b'\n\nbody\n'

    cases.append(('018_dates', dict(files=[
        ('rfc5322.eml', dated(b'Mon, 1 Sep 2025 12:30:00 +0200')),
        ('no-weekday.eml', dated(b'1 Sep 2025 12:30:00 +0200')),
        ('no-seconds.eml', dated(b'Mon, 1 Sep 2025 12:30 -0500')),
        ('two-digit-year.eml', dated(b'Sat, 3 Jan 70 00:00:00 GMT')),
        ('two-digit-year-50.eml', dated(b'Wed, 1 Jan 97 00:00:00 UT')),
        ('named-zone.eml', dated(b'Sun, 29 Feb 2004 22:03:22 PST')),
        ('unknown-zone.eml', dated(b'Sun, 29 Feb 2004 22:03:22 XYZ')),
        ('comment-zone.eml', dated(b'Sun, 29 Feb 2004 22:03:22 -0800 (PST)')),
        ('leap-second.eml', dated(b'Tue, 1 Jan 2036 00:00:60 +0000')),
        ('before-epoch.eml', dated(b'Mon, 3 Mar 1969 12:00:00 -0500')),
        ('folded.eml', b'Date: Mon, 1 Sep 2025\n 12:30:00 +0200\n\nbody\n'),
        ('invalid.eml', dated(b'not a date at all')),
        ('invalid-day.eml', dated(b'31 Feb 2004 00:00:00 +0000')),
        ('missing.eml', b'Subject: no date here\n\nbody\n'),
        ('big-offset.eml', dated(b'1 Jan 2000 00:00:00 +2359')),
    ])))

    cases.append(('019_message_rfc822', dict(files=[
        ('forwarded.eml',
         b'Subject: Fwd: original\n'
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\nContent-Type: text/plain\n\nsee attached\n'
         b'--B\nContent-Type: message/rfc822\n\n'
         b'Subject: =?utf-8?Q?the_original?=\n'
         b'From: orig@example.com\n'
         b'Date: Mon, 1 Sep 2025 00:00:00 +0000\n'
         b'Content-Type: text/plain; charset=utf-8\n\n'
         b'original body \xc3\xa9\n'
         b'--B--\n'),
        ('nested-multipart.eml',
         b'Content-Type: message/rfc822\n\n'
         b'Subject: inner\n'
         b'Content-Type: multipart/alternative; boundary="I"\n\n'
         b'--I\nContent-Type: text/plain\n\ninner plain\n'
         b'--I\nContent-Type: text/html\n\n<p>inner html</p>\n'
         b'--I--\n'),
    ])))

    cases.append(('020_message_other', dict(files=[
        ('delivery-status.eml',
         b'Content-Type: multipart/report; report-type=delivery-status;\n'
         b' boundary="R"\n\n'
         b'--R\nContent-Type: text/plain\n\nyour message bounced\n'
         b'--R\nContent-Type: message/delivery-status\n\n'
         b'Reporting-MTA: dns; mail.example.com\n\n'
         b'Final-Recipient: rfc822; nobody@example.com\n'
         b'Action: failed\n'
         b'--R--\n'),
        ('partial.eml',
         b'Content-Type: message/partial; id="x"; number=1; total=2\n\n'
         b'Subject: split\n\nfirst half\n'),
    ])))

    cases.append(('021_digest', dict(files=[
        ('digest.eml',
         b'Subject: weekly digest\n'
         b'Content-Type: multipart/digest; boundary="D"\n\n'
         b'--D\n\n'
         b'Subject: first message\nFrom: a@example.com\n\nfirst body\n'
         b'--D\n\n'
         b'Subject: second message\nFrom: b@example.com\n\nsecond body\n'
         b'--D\nContent-Type: text/plain\n\nan explicit text part\n'
         b'--D--\n'),
    ])))

    cases.append(('022_8bit_headers', dict(files=[
        ('utf8-headers.eml',
         b'Subject: caf\xc3\xa9 direct\n'
         b'From: Ren\xc3\xa9 <rene@example.fr>\n'
         b'X-Note: \xc3\xa9\xc3\xa8\xc3\xaa\n'
         b'\nbody\n'),
        ('invalid-headers.eml',
         b'Subject: latin1 caf\xe9 here\n'
         b'X-Broken: \xff\xfe\n'
         b'\nbody\n'),
    ])))

    cases.append(('023_crlf', dict(files=[
        ('crlf.eml',
         b'Subject: crlf message\r\n'
         b'Content-Type: multipart/mixed; boundary="B"\r\n'
         b'\r\n'
         b'preamble\r\n'
         b'--B\r\n'
         b'Content-Type: text/plain; charset=us-ascii\r\n'
         b'\r\n'
         b'line one\r\nline two\r\n'
         b'--B\r\n'
         b'Content-Type: application/octet-stream\r\n'
         b'Content-Transfer-Encoding: base64\r\n'
         b'\r\n'
         b'DQoNCg==\r\n'
         b'--B--\r\n'),
        ('qp-crlf.eml',
         b'Content-Type: text/plain; charset=us-ascii\r\n'
         b'Content-Transfer-Encoding: quoted-printable\r\n'
         b'\r\n'
         b'hard=0D=0Abreak and soft=\r\nbreak\r\n'),
    ])))

    cases.append(('024_mbox_multi', dict(mbox=[
        b'Subject: first\nFrom: a@example.com\n\nfirst body\n',
        b'Subject: second\nFrom: b@example.com\n\n'
        b'a body line that mentions From at the start:\n'
        b'From here on it is just text\n',
        b'Subject: third\n\n\n\nbody after blank lines\n\n',
        b'Subject: fourth\nContent-Type: text/plain; charset=utf-8\n\n'
        b'caf\xc3\xa9\n',
    ], senders=[
        b'From a@example.com Mon Jan  1 00:00:00 2001',
        b'From b@example.com Tue Jan  2 00:00:00 2001',
        b'From c@example.com Wed Jan  3 00:00:00 2001',
        b'From d@example.com Thu Jan  4 00:00:00 2001',
    ])))

    cases.append(('025_rich_messages', dict(mbox=[
        b'Subject: =?utf-8?Q?Quarterly_report_=E2=80=94_Q3?=\n'
        b'From: "Reports, Automated" <reports@example.com>\n'
        b'To: team@example.com, =?utf-8?Q?Ren=C3=A9?= <rene@example.fr>\n'
        b'Date: Fri, 3 Oct 2025 09:15:42 -0400\n'
        b'Message-ID: <20251003.091542@example.com>\n'
        b'MIME-Version: 1.0\n'
        b'Content-Type: multipart/mixed; boundary="=_out_42"\n\n'
        b'This is a multi-part message in MIME format.\n'
        b'--=_out_42\n'
        b'Content-Type: multipart/alternative; boundary="=_alt_42"\n\n'
        b'--=_alt_42\n'
        b'Content-Type: text/plain; charset=windows-1252\n'
        b'Content-Transfer-Encoding: quoted-printable\n\n'
        b'Revenue rose 12=25 this quarter =97 see the attached report.\n'
        b'Regards,=20\n'
        b'The =93automated=94 reporting system\n'
        b'--=_alt_42\n'
        b'Content-Type: text/html; charset=utf-8\n'
        b'Content-Transfer-Encoding: base64\n\n'
        b'PGh0bWw+PGJvZHk+PHA+UmV2ZW51ZSByb3NlIDEyJSDigJQgc2VlIHRoZSBh\n'
        b'dHRhY2hlZC48L3A+PC9ib2R5PjwvaHRtbD4K\n'
        b'--=_alt_42--\n'
        b'--=_out_42\n'
        b'Content-Type: application/pdf\n'
        b"Content-Disposition: attachment; filename*=utf-8''Q3%20r%C3%A9sum%C3%A9.pdf\n"
        b'Content-Transfer-Encoding: base64\n\n'
        b'JVBERi0xLjQKJcfsj6IKMSAwIG9iago8PC9UeXBlL0NhdGFsb2c+PgplbmRv\n'
        b'YmoKdHJhaWxlcgo8PC9Sb290IDEgMCBSPj4K\n'
        b'--=_out_42\n'
        b'Content-Type: image/png; name="chart.png"\n'
        b'Content-Disposition: inline; filename="chart.png"\n'
        b'Content-Transfer-Encoding: base64\n\n'
        b'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk\n'
        b'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==\n'
        b'--=_out_42--\n'
        b'and a trailing epilogue\n',

        b'Subject: Re: =?iso-8859-1?Q?caf=E9_meeting?=\n'
        b'From: =?iso-8859-1?Q?Ren=E9_Descartes?= <rene@example.fr>\n'
        b'To: Ann Example <ann@example.com>\n'
        b'Cc: undisclosed-recipients:;\n'
        b'In-Reply-To: <20251003.091542@example.com>\n'
        b'References: <20251001.000000@example.com>\n'
        b'\t<20251003.091542@example.com>\n'
        b'Date: Fri, 3 Oct 2025 16:02:11 +0200\n'
        b'Content-Type: text/plain; charset=iso-8859-1\n'
        b'Content-Transfer-Encoding: 8bit\n\n'
        b'> Revenue rose 12% this quarter\n\n'
        b'Tr\xe8s bien. \xc0 demain au caf\xe9.\n',

        b'Subject: forwarded bundle\n'
        b'From: forwarder@example.com\n'
        b'Date: Sat, 4 Oct 2025 11:00:00 +0000\n'
        b'Content-Type: multipart/mixed; boundary="fwd"\n\n'
        b'--fwd\n'
        b'Content-Type: text/plain; charset=us-ascii\n\n'
        b'Two messages attached.\n'
        b'--fwd\n'
        b'Content-Type: message/rfc822\n'
        b'Content-Disposition: attachment; filename="one.eml"\n\n'
        b'Subject: inner one\n'
        b'From: inner@example.com\n'
        b'Content-Type: multipart/alternative; boundary="in"\n\n'
        b'--in\nContent-Type: text/plain\n\ninner plain text\n'
        b'--in\nContent-Type: text/html\n\n<p>inner html</p>\n'
        b'--in--\n'
        b'--fwd\n'
        b'Content-Type: message/rfc822\n\n'
        b'Subject: inner two\n'
        b'Content-Type: text/plain; charset=utf-8\n'
        b'Content-Transfer-Encoding: quoted-printable\n\n'
        b'second inner =E2=9C=93\n'
        b'--fwd--\n',
    ])))

    cases.append(('026_oracle_divergences', dict(files=[
        ('folded-boundary.eml',
         b'Content-Type: multipart/mixed; boundary="simple\n boundary"\n\n'
         b'preamble\n'
         b'--simple boundary\n\n'
         b'implicitly typed plain text\n'
         b'--simple boundary\n'
         b'Content-Type: text/plain; charset=us-ascii\n\n'
         b'explicitly typed plain text\n'
         b'--simple boundary--\n'),
        ('adjacent-delimiters.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\nContent-Type: text/plain\n\nfirst\n'
         b'--B\n'
         b'--B\nContent-Type: text/plain\n\nthird\n'
         b'--B--\n'),
        ('empty-part-then-close.eml',
         b'Content-Type: multipart/mixed; boundary="B"\n\n'
         b'--B\n--B--\n\nepilogue\n'),
        ('obsolete-header-syntax.eml',
         b'Subject :The obsolete syntax allows spaces before the colon\n'
         b'Date    :     Malformed Date.\n'
         b'\nbody\n'),
        ('envelope-line.eml',
         b'Subject: mbox envelope line inside the header block\n'
         b'From nobody Mon Sep  1 00:00:00 2025\n'
         b'X-Never-Seen: because the header block already ended\n'
         b'\nbody\n'),
        ('unquoted-spaces.eml',
         b'Content-Type: application/octet-stream; name=two words.bin\n'
         b'Content-Disposition: attachment; filename=two words.bin\n'
         b'\ndata\n'),
    ])))

    # Shapes where two readings of SPEC.md would disagree; each is spelled
    # out in the specification and pinned by check_pinned_cases().
    cases.append(('027_ambiguities', dict(files=[
        ('boundary-bad-utf8.eml',
         b'Content-Type: multipart/mixed; boundary="b\xe9"\n\n'
         b'--b\xe9\nContent-Type: text/plain\n\nfirst\n--b\xe9--\n'),
        ('boundary-utf8.eml',
         'Content-Type: multipart/mixed; boundary="b\u00e9"\n\n'
         '--b\u00e9\nContent-Type: text/plain\n\nfirst\n'
         '--b\u00e9--\n'.encode('utf-8')),
        ('extended-empty-charset.eml',
         b'Content-Type: application/octet-stream\n'
         b'Content-Disposition: attachment; filename*=\'\'caf%E9.txt\n'
         b'\ndata\n'),
        ('huge-zone.eml',
         b'Subject: a four-digit zone that is more than 99 hours\n'
         b'Date: Sat, 1 Jan 2000 00:00:00 +9999\n'
         b'\nbody\n'),
        ('nested-angles.eml',
         b'From: a <b <c@d.com> , e@f.com>, g@h.com\n'
         b'To: plain <x@y.com>\n'
         b'Subject: nested angle brackets\n'
         b'\nbody\n'),
        ('phrase-comments.eml',
         b'From: John (the third) Public <jqp@x.com>\n'
         b'To: =?utf-8?Q?a?= (c) =?utf-8?Q?b?= <ab@x.com>\n'
         b'Cc: "quoted \\"inner\\"" <qi@x.com>\n'
         b'\nbody\n'),
        ('quoted-backslash.eml',
         b'Content-Type: application/octet-stream\n'
         b'Content-Disposition: attachment; filename="a\\\\"; '
         b'creation-date="x"\n'
         b'\ndata\n'),
        ('unterminated-quote.eml',
         b'Content-Type: application/octet-stream\n'
         b'Content-Disposition: attachment; filename="abc\\\n'
         b'\ndata\n'),
        ('segment-order.eml',
         b'Content-Type: application/octet-stream; *0=x; *1=y; name=n.bin\n'
         b'Content-Disposition: attachment; filename*10=j; filename*2=c;\n'
         b' filename*0=a; filename*1=b; filename*07=h\n'
         b'\ndata\n'),
    ])))

    return cases


# ---------------------------------------------------------------------------
# Corpus tests
# ---------------------------------------------------------------------------

def corpus_cases():
    """Return the corpus-backed test cases as (name, kwargs) pairs."""
    cases = []

    groups = [
        ('mime4j', '.msg', ['028_mime4j_a', '029_mime4j_b', '030_mime4j_c']),
        ('mailgem', '.eml', ['031_mailgem_a', '032_mailgem_b',
                             '033_mailgem_c']),
    ]
    for subdir, suffix, names in groups:
        files = corpus_files(subdir, suffix)
        kept = []
        dropped = {}
        for name, data in files:
            data = data.replace(b'\r\n', b'\n')
            try:
                crosscheck(data)
            except Skip as exc:
                dropped[str(exc)] = dropped.get(str(exc), 0) + 1
                continue
            kept.append((eml_name(name), data))
        if dropped:
            detail = ', '.join('%s x%d' % (k, v) for k, v in sorted(dropped.items()))
            print('  %-30s kept %3d of %3d (%s)'
                  % (subdir, len(kept), len(files), detail))
        per = (len(kept) + len(names) - 1) // len(names)
        for k, name in enumerate(names):
            chunk = kept[k * per:(k + 1) * per]
            cases.append((name, dict(files=chunk)))

    for name, seed, count, kinds in SYNTHETIC_MBOXES:
        g = synth.Gen(seed)
        raws, senders = [], []
        for k in range(count):
            make = kinds[k % len(kinds)]
            # mbox writers escape a "From " line that follows a blank line.
            raw = re.sub(rb'(\n\r?\n)From ', rb'\1>From ', synth.capped(make, g))
            raws.append(mbox_body(raw))
            senders.append(b'From %s %s %s %2d %02d:%02d:%02d %d' % (
                g.person()[1].encode(), g.r.choice(synth.DAYS).encode(),
                g.r.choice(synth.MONTHS).encode(), g.r.randint(1, 28),
                g.r.randint(0, 23), g.r.randint(0, 59), g.r.randint(0, 59),
                g.r.choice([2004, 2005, 2025])))
        kept = keep_messages(raws, name)
        senders = [s for s, raw in zip(senders, raws) if raw in kept]
        cases.append((name, dict(mbox=kept, senders=senders)))
    return cases


def main():
    print('cross-checking the primitive decoders')
    check_primitives()
    check_pinned_cases()
    if os.path.isdir(TESTS):
        shutil.rmtree(TESTS)
    os.makedirs(TESTS)
    print('hand-written cases')
    for name, kwargs in hand_written():
        emit(name, **kwargs)
    print('corpus cases')
    for name, kwargs in corpus_cases():
        emit(name, **kwargs)
    total = sum(os.path.getsize(os.path.join(dp, f))
                for dp, _dn, fn in os.walk(TESTS) for f in fn)
    print('tests/ total %.1f MB' % (total / 1048576))
    return 0


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/mime4j/LICENSE',
     'LICENSE-mime4j.txt'),
    ('corpus/mime4j/NOTICE',
     'NOTICE-mime4j.txt'),
    ('corpus/mailgem/LICENSE',
     'LICENSE-mailgem.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == '__main__':
    rc = main()
    copy_licences()
    sys.exit(rc)
