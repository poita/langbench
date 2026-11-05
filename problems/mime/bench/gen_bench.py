#!/usr/bin/env python3
"""Generates the performance benchmark inputs for the `mime` problem.

    python3 bench/gen_bench.py

Writes bench/NNN_name/{input,expected} in the same layout as tests/, so

    python3 run_tests.py mime --tests-dir problems/mime/bench -- <impl>/run.sh

runs them. Every input is synthesised from fixed seeds; expected outputs are
produced by reference/main.py.

001_mailing_list_mbox    a large mbox of ordinary mailing-list traffic
002_attachments_eml_dir  a directory of .eml files with deep MIME trees,
                         base64/QP attachments, RFC 2231 names, forwards
003_header_heavy_mbox    an mbox of messages with very large address lists,
                         encoded words in several charsets and varied dates
"""
import base64
import os
import quopri
import random
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'reference'))
import main as ref  # noqa: E402

# Spec guarantee: the largest single message is about 90 kB.
MAX_MESSAGE = 88000

FIRST = ['Ann', 'Bob', 'Carl', 'Dana', 'Erik', 'Fiona', 'Greg', 'Hana',
         'Ivan', 'Jörg', 'Karin', 'Luis', 'María', 'Nils', 'Olga', 'Pierre',
         'Quinn', 'Rémi', 'Sven', 'Tomás', 'Uwe', 'Vera', 'William', 'Xavier',
         'Yuki', 'Zoë', 'Ελένη', 'Дмитрий', '太郎', 'François', 'Søren',
         'Agnieszka', 'Björn', 'Chloé', 'Đorđe', 'Łukasz']
LAST = ['Smith', 'Müller', 'García', 'Johansson', 'Rossi', 'Dubois',
        'Nakamura', 'Kowalski', 'O\'Brien', 'Nguyen', 'Petrov', 'Østergaard',
        'Fernández', 'Schröder', 'Brown', 'Taylor', 'Wilson', 'Lefèvre',
        'Papadopoulos', 'Иванов', '山田', 'Doe', 'van der Berg', 'Kim']
DOMAINS = ['example.com', 'example.org', 'apache.org', 'mail.example.net',
           'lists.example.edu', 'corp.example.co.uk', 'eu.example.de',
           'dev.example.io', 'students.example.ac.jp', 'post.example.fr']
WORDS = ('the of and to a in is it you that he was for on are with as I his '
         'they be at one have this from or had by hot word but what some we '
         'can out other were all there when up use your how said an each '
         'she which do their time if will way about many then them write '
         'would like so these her long make thing see him two has look more '
         'day could go come did number sound no most people my over know '
         'water than call first who may down side been now find any new '
         'work part take get place made live where after back little only '
         'round man year came show every good me give our under name very '
         'through just form sentence great think say help low line differ '
         'turn cause much mean before move right boy old too same tell does '
         'set three want air well also play small end put home read hand '
         'port large spell add even land here must big high such follow act '
         'why ask men change went light kind off need house picture try us '
         'again animal point mother world near build self earth father '
         'module server request config patch build release apr httpd proxy '
         'cache filter bucket brigade socket thread mutex pool handler hook '
         'directive vote commit branch trunk backport review bug crash '
         'segfault log error warning timeout header response status client '
         'connection keepalive ssl certificate rewrite alias vhost').split()
ACCENTED = ('café naïve résumé façade déjà Größe Straße fiancée jalapeño '
            'smörgåsbord crème brûlée Ångström piñata coöperate élan '
            'über Zürich São Paulo Málaga Kraków Ørsted').split()
CHARSETS_TEXT = ['us-ascii', 'utf-8', 'utf-8', 'iso-8859-1', 'windows-1252',
                 'UTF-8', 'ISO-8859-1']
DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep',
          'Oct', 'Nov', 'Dec']
ZONES = ['+0000', '-0800', '-0700', '-0500', '-0400', '+0100', '+0200',
         '+0530', '+0900', '+1000', '-0000', 'GMT', 'UT', 'EST', 'PDT', 'CST',
         'Z', 'MET', '+1245', '-0330']


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)
        self.msgid = 0

    # -- primitives ---------------------------------------------------------
    def word(self):
        r = self.r
        if r.random() < 0.03:
            return r.choice(ACCENTED)
        # Zipf-ish: favour the front of the list.
        return WORDS[int(len(WORDS) * (r.random() ** 2.2))]

    def sentence(self, lo=5, hi=18):
        n = self.r.randint(lo, hi)
        s = ' '.join(self.word() for _ in range(n))
        return s[0].upper() + s[1:] + self.r.choice(['.', '.', '.', '?', '!'])

    def paragraph(self, lo=2, hi=7):
        return ' '.join(self.sentence() for _ in range(self.r.randint(lo, hi)))

    def wrap(self, text, width=72):
        lines, cur = [], ''
        for w in text.split(' '):
            if cur and len(cur) + 1 + len(w) > width:
                lines.append(cur)
                cur = w
            else:
                cur = (cur + ' ' + w) if cur else w
        if cur:
            lines.append(cur)
        return lines

    def person(self):
        r = self.r
        first, last = r.choice(FIRST), r.choice(LAST)
        local = ''.join(c for c in (first[0] + last).lower()
                        if c.isascii() and (c.isalnum()))
        if not local or not local[0].isalpha():
            local = 'user%d' % r.randint(1, 9999)
        if r.random() < 0.3:
            local += '.' + str(r.randint(1, 99))
        return first + ' ' + last, local + '@' + r.choice(DOMAINS)

    def encoded_word(self, text, charset=None):
        r = self.r
        charset = charset or r.choice(['utf-8', 'UTF-8', 'iso-8859-1',
                                       'windows-1252'])
        try:
            data = text.encode('utf-8' if 'utf' in charset.lower()
                               else 'cp1252')
        except UnicodeEncodeError:
            charset, data = 'utf-8', text.encode('utf-8')
        if r.random() < 0.5:
            enc = base64.b64encode(data).decode('ascii')
            return '=?%s?B?%s?=' % (charset, enc)
        out = []
        for b in data:
            c = chr(b)
            if b == 0x20:
                out.append('_')
            elif 0x21 <= b < 0x7f and c not in '=?_':
                out.append(c)
            else:
                out.append('=%02X' % b)
        return '=?%s?Q?%s?=' % (charset, ''.join(out))

    def display(self, name):
        """Render a display name the way a range of mailers would."""
        r = self.r
        if not name.isascii():
            if r.random() < 0.8:
                return self.encoded_word(name)
            return name  # raw 8-bit UTF-8 header, which happens in practice
        x = r.random()
        if x < 0.35:
            return '"%s, %s"' % tuple(reversed(name.split(' ', 1))) \
                if ' ' in name else '"%s"' % name
        if x < 0.45:
            return '"%s"' % name.replace('"', '')
        if "'" in name or '.' in name:
            return '"%s"' % name
        return name

    def mailbox(self):
        r = self.r
        name, addr = self.person()
        x = r.random()
        if x < 0.15:
            return addr
        if x < 0.22:
            return '%s (%s)' % (addr, name if name.isascii() else 'Someone')
        return '%s <%s>' % (self.display(name), addr)

    def address_list(self, n, groups=False):
        items = [self.mailbox() for _ in range(n)]
        if groups and n > 6 and self.r.random() < 0.3:
            k = self.r.randint(2, min(8, n - 1))
            grp = self.r.choice(['dev-team', 'Release Managers', 'ops',
                                 'Undisclosed'])
            items = items[:-k] + ['%s: %s;' % (grp, ', '.join(items[-k:]))]
        return items

    def date(self):
        r = self.r
        y = r.choice([2003, 2004, 2005, 2009, 2012, 2018, 2024, 2025])
        mo = r.randint(1, 12)
        d = r.randint(1, 28)
        hh, mm, ss = r.randint(0, 23), r.randint(0, 59), r.randint(0, 59)
        zone = r.choice(ZONES)
        x = r.random()
        dow = DAYS[r.randint(0, 6)]
        if x < 0.55:
            s = '%s, %d %s %d %02d:%02d:%02d %s' % (dow, d, MONTHS[mo - 1], y,
                                                   hh, mm, ss, zone)
        elif x < 0.70:
            s = '%s, %02d %s %d %02d:%02d:%02d %s (%s)' % (
                dow, d, MONTHS[mo - 1], y, hh, mm, ss, zone,
                r.choice(['PST', 'CET', 'GMT', 'EDT', 'JST']))
        elif x < 0.80:
            s = '%d %s %02d %02d:%02d %s' % (d, MONTHS[mo - 1].upper(),
                                             y % 100, hh, mm, zone)
        elif x < 0.90:
            s = '%s %s %d %02d:%02d:%02d %d %s' % (dow, MONTHS[mo - 1], d,
                                                   hh, mm, ss, y, zone)
        elif x < 0.97:
            s = '%s,%d %s %d %d:%d:%d (comment (nested)) %s' % (
                dow.lower(), d, MONTHS[mo - 1].lower(), y, hh, mm, ss, zone)
        else:
            s = r.choice(['31 Feb 2004 10:00:00 +0000', 'yesterday',
                          'Mon, 3 Mar 2004 25:00:00 +0000'])
        return s

    def new_msgid(self):
        self.msgid += 1
        return '<%d.%08x.%d@%s>' % (self.msgid, self.r.getrandbits(32),
                                    self.r.randint(1000, 99999),
                                    self.r.choice(DOMAINS))

    def fold(self, name, items, sep=', '):
        """Fold a list-valued header at about 76 columns."""
        lines, cur = [], name + ':'
        for k, it in enumerate(items):
            piece = it + (sep.rstrip() if k < len(items) - 1 else '')
            if len(cur) + 1 + len(piece) > 76 and cur != name + ':':
                lines.append(cur)
                cur = self.r.choice([' ', '\t', '    ']) + piece
            else:
                cur += ' ' + piece
        lines.append(cur)
        return '\n'.join(lines)

    def received(self):
        r = self.r
        return ('Received: from %s (%s [%d.%d.%d.%d])\n\tby %s (Postfix) with '
                'ESMTP id %X\n\tfor <%s>; %s' % (
                    r.choice(DOMAINS), 'mx%d.%s' % (r.randint(1, 9),
                                                    r.choice(DOMAINS)),
                    r.randint(1, 254), r.randint(0, 255), r.randint(0, 255),
                    r.randint(1, 254), r.choice(DOMAINS),
                    r.getrandbits(40), self.person()[1], self.date()))

    def subject(self):
        r = self.r
        s = self.sentence(3, 10).rstrip('.?!')
        prefix = r.choice(['', '', 'Re: ', 'RE: ', 'Fwd: ', '[PATCH] ',
                           '[VOTE] ', 'Re: [PATCH] '])
        x = r.random()
        if x < 0.25:
            # Encoded across several words, folded like real mailers do.
            parts, words = [], s.split(' ')
            while words:
                k = r.randint(2, 5)
                parts.append(self.encoded_word(' '.join(words[:k]) + ' '))
                words = words[k:]
            return 'Subject: ' + prefix + '\n '.join(parts)
        if x < 0.35:
            return 'Subject: %s%s %s' % (prefix, s, self.encoded_word(
                r.choice(ACCENTED + ['日本語のテスト', 'Привет мир'])))
        return 'Subject: ' + prefix + s

    # -- bodies -------------------------------------------------------------
    def text_body(self, paras_lo=2, paras_hi=8, quoted=True):
        r = self.r
        out = []
        if quoted and r.random() < 0.6:
            name = self.person()[0]
            out.append('On %s, %s wrote:' % (self.date(), name))
            for _ in range(r.randint(1, 4)):
                for line in self.wrap(self.paragraph(), 68):
                    out.append(r.choice(['> ', '>> ', '> > ']) + line)
                out.append('>')
            out.append('')
        for _ in range(r.randint(paras_lo, paras_hi)):
            out.extend(self.wrap(self.paragraph()))
            out.append('')
        if r.random() < 0.3:
            out.append('    if (rv != APR_SUCCESS) {')
            out.append('        ap_log_error(APLOG_MARK, APLOG_ERR, rv, s,')
            out.append('                     "failed: %s", name);')
            out.append('        return rv;')
            out.append('    }')
            out.append('')
        out.append('-- ')
        out.append(self.person()[0])
        text = '\n'.join(out) + '\n'
        # mbox writers escape body lines beginning with "From ".
        text = text.replace('\nFrom ', '\n>From ')
        return ('>' + text) if text.startswith('From ') else text

    def html_body(self, text):
        paras = [p for p in text.split('\n\n') if p.strip()]
        out = ['<html><head><meta http-equiv="Content-Type" '
               'content="text/html; charset=utf-8"></head><body>']
        for p in paras:
            p = (p.replace('&', '&amp;').replace('<', '&lt;')
                 .replace('>', '&gt;').replace('\n', '<br>\n'))
            out.append('<p style="margin:0 0 1em 0;font-family:Arial">'
                       + p + '</p>')
        out.append('</body></html>')
        return '\n'.join(out) + '\n'

    def encode_text(self, text, charset, cte):
        """Return (bytes, charset, cte) for a text part."""
        cs = charset.lower()
        if 'utf' in cs:
            data = text.encode('utf-8')
        elif cs == 'us-ascii':
            data = text.encode('ascii', 'replace')
        else:
            data = text.encode('cp1252', 'replace')
        if cte == 'quoted-printable':
            body = quopri.encodestring(data)
        elif cte == 'base64':
            body = base64.encodebytes(data)
        else:
            body = data
        return body

    def text_part(self, text, subtype='plain', charset=None, cte=None,
                  extra=''):
        r = self.r
        charset = charset or r.choice(CHARSETS_TEXT)
        if cte is None:
            cte = r.choice(['7bit', '8bit', 'quoted-printable',
                            'quoted-printable', 'base64'])
            if charset.lower() == 'us-ascii':
                cte = r.choice(['7bit', 'quoted-printable'])
        body = self.encode_text(text, charset, cte)
        cs_param = r.choice(['charset=%s', 'charset="%s"', 'CHARSET=%s'])
        hdr = 'Content-Type: text/%s; %s%s\nContent-Transfer-Encoding: %s\n' \
            % (subtype, cs_param % charset, extra, cte)
        return hdr.encode('utf-8') + b'\n' + body

    def filename(self, ext):
        r = self.r
        base = '_'.join(self.word() for _ in range(r.randint(1, 4)))
        if r.random() < 0.25:
            base = r.choice(ACCENTED) + '_' + base
        return base + '.' + ext

    def filename_params(self, name):
        """Content-Type name and Content-Disposition filename parameters."""
        r = self.r
        x = r.random()
        if name.isascii():
            if x < 0.5:
                return 'name="%s"' % name, 'filename="%s"' % name
            if x < 0.65:
                return 'name=%s' % name, 'filename=%s' % name
            if x < 0.8:
                half = len(name) // 2
                return ('name="%s"' % name,
                        'filename*0="%s";\n filename*1="%s"'
                        % (name[:half], name[half:]))
        enc = ''.join(c if (c.isascii() and (c.isalnum() or c in '._-'))
                      else ''.join('%%%02X' % b for b in c.encode('utf-8'))
                      for c in name)
        if x < 0.9:
            return ('name="%s"' % self.encoded_word(name, 'utf-8'),
                    "filename*=utf-8''%s" % enc)
        cut = max(1, len(enc) // 2)
        while '%' in enc[cut - 2:cut]:
            cut += 1
        return ('name="%s"' % self.encoded_word(name, 'utf-8'),
                "filename*0*=UTF-8''%s;\n filename*1*=%s"
                % (enc[:cut], enc[cut:]))

    def binary_blob(self, n):
        r = self.r
        # A mix of structured and random bytes, like real images / archives.
        head = bytes(r.getrandbits(8) for _ in range(min(n, 64)))
        body = bytearray(r.randbytes(max(0, n - 64)))
        for k in range(0, len(body), 97):
            body[k] = 0
        return head + bytes(body)

    def attachment(self, kind=None, max_size=24000):
        r = self.r
        kind = kind or r.choice(['pdf', 'png', 'jpg', 'zip', 'patch',
                                 'csv', 'docx', 'txt'])
        name = self.filename(kind)
        ct_name, cd_fn = self.filename_params(name)
        disp = r.choice(['attachment', 'attachment', 'Attachment', 'inline'])
        if kind in ('patch', 'csv', 'txt'):
            lines = []
            if kind == 'patch':
                lines += ['Index: modules/%s.c' % self.word(),
                          '=' * 67,
                          '--- modules/a.c\t(revision %d)' % r.randint(1, 900000),
                          '+++ modules/a.c\t(working copy)',
                          '@@ -%d,7 +%d,9 @@' % (r.randint(1, 900),
                                                 r.randint(1, 900))]
                for _ in range(r.randint(20, 200)):
                    lines.append(r.choice(' +-') + '    ' +
                                 ' '.join(self.word() for _ in
                                          range(r.randint(1, 9))))
            elif kind == 'csv':
                for _ in range(r.randint(30, 300)):
                    lines.append(','.join([self.word(),
                                           str(r.randint(0, 10**6)),
                                           '%.3f' % r.random(),
                                           self.person()[1]]))
            else:
                for _ in range(r.randint(10, 60)):
                    lines.extend(self.wrap(self.paragraph()))
            text = '\n'.join(lines) + '\n'
            ctype = {'patch': 'text/x-diff', 'csv': 'text/csv',
                     'txt': 'text/plain'}[kind]
            cte = r.choice(['7bit', 'quoted-printable', 'base64'])
            body = self.encode_text(text, 'utf-8', cte)
            hdr = ('Content-Type: %s; charset=UTF-8; %s\n'
                   'Content-Disposition: %s; %s\n'
                   'Content-Transfer-Encoding: %s\n' %
                   (ctype, ct_name, disp, cd_fn, cte))
            return hdr.encode('utf-8') + b'\n' + body
        ctype = {'pdf': 'application/pdf', 'png': 'image/png',
                 'jpg': 'image/jpeg', 'zip': 'application/zip',
                 'docx': 'application/vnd.openxmlformats-officedocument.'
                         'wordprocessingml.document'}[kind]
        data = self.binary_blob(r.randint(500, max_size))
        b64 = base64.encodebytes(data)
        extra = ''
        if r.random() < 0.3:
            extra = 'Content-ID: <%s>\n' % self.new_msgid()[1:-1]
        hdr = ('Content-Type: %s;\n %s\nContent-Transfer-Encoding: base64\n'
               'Content-Disposition: %s;\n %s; size=%d\n%s'
               % (ctype, ct_name, disp, cd_fn, len(data), extra))
        return hdr.encode('utf-8') + b'\n' + b64

    def multipart(self, subtype, parts, preamble=True, epilogue=None):
        r = self.r
        b = r.choice(['----=_Part_%d_%d.%d' % (r.randint(1, 9999),
                                                r.getrandbits(30),
                                                r.getrandbits(40)),
                      '=_%032x' % r.getrandbits(128),
                      'Apple-Mail=_%X' % r.getrandbits(64),
                      '000000000000%012x' % r.getrandbits(48),
                      'simple boundary %d' % r.randint(1, 999)])
        quoted = ' ' in b or '=' in b or r.random() < 0.6
        bp = ('"%s"' % b) if quoted else b
        hdr = 'Content-Type: multipart/%s;\n\tboundary=%s\n' % (subtype, bp)
        out = bytearray(hdr.encode('ascii') + b'\n')
        if preamble and r.random() < 0.5:
            out += b'This is a multi-part message in MIME format.\n'
        bb = b.encode('ascii')
        for p in parts:
            out += b'\n--' + bb + b'\n' + p
            if not p.endswith(b'\n'):
                out += b'\n'
        out += b'\n--' + bb + b'--\n'
        if epilogue:
            out += epilogue
        return bytes(out)

    def headers(self, extra_headers=(), n_to=(1, 3), n_cc=(0, 2),
                in_list=True):
        r = self.r
        h = []
        for _ in range(r.randint(1, 5)):
            h.append(self.received())
        h.append('Return-Path: <%s>' % self.person()[1])
        h.append('Message-ID: ' + self.new_msgid())
        if r.random() < 0.6:
            refs = [self.new_msgid() for _ in range(r.randint(1, 12))]
            h.append('In-Reply-To: ' + refs[-1])
            h.append(self.fold('References', refs, sep=' '))
        h.append('Date: ' + self.date())
        h.append('From: ' + self.mailbox())
        if r.random() < 0.15:
            h.append('Reply-To: ' + self.mailbox())
        h.append(self.fold('To', self.address_list(r.randint(*n_to))))
        nc = r.randint(*n_cc)
        if nc:
            h.append(self.fold('Cc', self.address_list(nc)))
        h.append(self.subject())
        if in_list:
            h.append('Mailing-List: contact dev-help@httpd.apache.org; run by '
                     'ezmlm')
            h.append('List-Post: <mailto:dev@httpd.apache.org>')
            h.append('Precedence: bulk')
        h.append('X-Mailer: ' + r.choice(['Mutt/1.4.1i', 'Apple Mail (2.612)',
                                          'Microsoft Outlook 16.0',
                                          'Thunderbird 115.3.1']))
        h.extend(extra_headers)
        return '\n'.join(h) + '\n'

    def finish(self, header_text, body):
        msg = header_text.encode('utf-8') + body
        if self.r.random() < 0.2:
            msg = msg.replace(b'\n', b'\r\n')
        return msg


# ---------------------------------------------------------------------------
# Workloads
# ---------------------------------------------------------------------------

def mailing_list_message(g):
    """An ordinary list post: mostly plain text, some alternatives/patches."""
    r = g.r
    x = r.random()
    text = g.text_body()
    if x < 0.6:
        body = g.text_part(text)
        hdr = g.headers(['MIME-Version: 1.0'])
        # text_part already carries its Content-Type header block.
        return g.finish(hdr, body)
    if x < 0.85:
        alt = g.multipart('alternative', [
            g.text_part(text),
            g.text_part(g.html_body(text), 'html', 'utf-8',
                        'quoted-printable')])
        return g.finish(g.headers(['MIME-Version: 1.0']), alt)
    parts = [g.text_part(text)]
    for _ in range(r.randint(1, 2)):
        parts.append(g.attachment(r.choice(['patch', 'patch', 'txt', 'csv']),
                                  8000))
    return g.finish(g.headers(['MIME-Version: 1.0']),
                    g.multipart('mixed', parts))


def rich_message(g, depth=0):
    """A business-style message with a deep MIME tree and attachments."""
    r = g.r
    text = g.text_body(1, 5)
    html = g.html_body(text)
    alt = g.multipart('alternative', [
        g.text_part(text),
        g.text_part(html, 'html', r.choice(['utf-8', 'windows-1252']),
                    'quoted-printable')])
    if r.random() < 0.5:
        inline = [g.attachment(r.choice(['png', 'jpg']), 4000)
                  for _ in range(r.randint(1, 3))]
        alt = g.multipart('related', [alt] + inline)
    parts = [alt]
    for _ in range(r.randint(1, 4)):
        parts.append(g.attachment(max_size=8000))
    if depth < 2 and r.random() < 0.3:
        inner = rich_message(g, depth + 1)
        if b'\r\n' in inner:
            inner = inner.replace(b'\r\n', b'\n')
        parts.append(b'Content-Type: message/rfc822\n'
                     b'Content-Disposition: inline\n\n' + inner)
    if r.random() < 0.08:
        digest = []
        for _ in range(r.randint(2, 4)):
            digest.append(b'\n' + mailing_list_message(g).replace(b'\r\n',
                                                                  b'\n'))
        parts.append(g.multipart('digest', digest))
    body = g.multipart('mixed', parts,
                       epilogue=b'\n' if r.random() < 0.5 else None)
    hdr = g.headers(['MIME-Version: 1.0'], in_list=False)
    return hdr.encode('utf-8') + body


def header_heavy_message(g):
    """A message whose cost is in its headers: big address lists etc."""
    r = g.r
    extra = ['MIME-Version: 1.0']
    for _ in range(r.randint(0, 3)):
        extra.append('X-Original-To: ' + g.mailbox())
    for _ in range(r.randint(1, 4)):
        extra.append('Resent-Date: ' + g.date())
    for _ in range(r.randint(0, 2)):
        extra.append(g.fold('Bcc', g.address_list(r.randint(1, 20))))
    extra.append('Thread-Topic: ' + g.encoded_word(g.sentence(3, 8)))
    extra.append('Comments: ' + ' '.join(
        g.encoded_word(w + ' ') if r.random() < 0.5 else w
        for w in g.sentence(5, 20).split()))
    hdr = g.headers(extra, n_to=(5, 120), n_cc=(0, 80), in_list=False)
    hdr += g.fold('Sender', g.address_list(1)) + '\n'
    if r.random() < 0.3:
        hdr += g.fold('Reply-To', g.address_list(r.randint(1, 4))) + '\n'
    body = g.text_part(g.text_body(1, 2, quoted=False))
    return g.finish(hdr, body)


def capped(make, g):
    while True:
        m = make(g)
        if len(m) <= MAX_MESSAGE:
            return m


def mbox_bytes(messages, g):
    out = bytearray()
    for m in messages:
        if not m.endswith(b'\n'):
            m += b'\n'
        out += b'From %s %s %s %2d %02d:%02d:%02d %d\n' % (
            g.person()[1].encode(), g.r.choice(DAYS).encode(),
            g.r.choice(MONTHS).encode(), g.r.randint(1, 28),
            g.r.randint(0, 23), g.r.randint(0, 59), g.r.randint(0, 59),
            g.r.choice([2004, 2005, 2025]))
        out += m + b'\n'
    return bytes(out)


def emit(name, mbox=None, files=None, base=HERE):
    case = os.path.join(base, name)
    if os.path.isdir(case):
        shutil.rmtree(case)
    os.makedirs(case)
    inp = os.path.join(case, 'input')
    if mbox is not None:
        with open(inp, 'wb') as f:
            f.write(mbox)
        n, size = None, len(mbox)
    else:
        os.makedirs(inp)
        for fn, data in files:
            with open(os.path.join(inp, fn), 'wb') as f:
                f.write(data)
        n, size = len(files), sum(len(d) for _, d in files)
    out = os.path.join(case, 'expected')
    os.makedirs(out)
    rc = ref.main(['main.py', inp, out])
    if rc != 0:
        raise SystemExit('reference failed on %s' % name)
    print('%-26s input %6.2f MB%s' % (name, size / 1e6,
                                      '' if n is None else ' (%d files)' % n))


# Long tier (../bench-long): the same three inputs with three times as many
# messages (new seeds). Parsing is linear in the input and the run time is
# dominated by writing the output tree, so the input size is the only lever.
LONG_DIR = os.path.join(os.path.dirname(HERE), 'bench-long')


def main():
    long = '--long' in sys.argv[1:]
    base = LONG_DIR if long else HERE
    scale = 3 if long else 1
    os.makedirs(base, exist_ok=True)

    g = Gen(20261011 if not long else 120261011)
    msgs = [capped(mailing_list_message, g) for _ in range(900 * scale)]
    emit('001_mailing_list_mbox', mbox=mbox_bytes(msgs, g), base=base)

    g = Gen(424242 if not long else 1424242)
    files = []
    for k in range(140 * scale):
        m = capped(rich_message, g)
        if g.r.random() < 0.5:
            m = m.replace(b'\n', b'\r\n')
        files.append(('msg-%05d-%s.eml' % (k, g.word()), m))
    emit('002_attachments_eml_dir', files=files, base=base)

    g = Gen(777 if not long else 1777)
    msgs = [capped(header_heavy_message, g) for _ in range(420 * scale)]
    emit('003_header_heavy_mbox', mbox=mbox_bytes(msgs, g), base=base)


if __name__ == '__main__':
    main()
