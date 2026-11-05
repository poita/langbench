#!/usr/bin/env python3
"""Generates tests/*.in and tests/*.out for the `commonmark` problem.

Every test is either an embedded literal, a group of official CommonMark
0.31.2 spec examples (spec_examples.json), or a document produced by a
seeded random generator, so re-running this script reproduces the suite
exactly. Expected outputs are produced by reference/main.py and every one of
them is cross-checked against the `cmark` reference implementation, which
is the oracle for this problem: the script aborts on any disagreement.
Every input is also checked against the subset guarantees in SPEC.md.

    python3 gen_tests.py                 # regenerate tests/
    python3 gen_tests.py --extract spec.txt   # rebuild spec_examples.json
"""
import html.entities
import json
import os
import shutil
import random
import re
import subprocess
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
REF = os.path.join(HERE, 'reference', 'main.py')
SPEC_JSON = os.path.join(HERE, 'spec_examples.json')
CMARK = os.environ.get('CMARK', 'cmark')

sys.path.insert(0, os.path.join(HERE, 'reference'))
import main as ref  # noqa: E402


# ---------------------------------------------------------------------------
# Subset guarantees (see SPEC.md, "What the input never contains")
# ---------------------------------------------------------------------------
HTML5 = html.entities.html5
NAMED_OK = {'amp', 'lt', 'gt', 'quot'}
ENTITY_NAME_RE = re.compile(r'&([A-Za-z][A-Za-z0-9]*);')
LT_RE = re.compile(r'<(?=[A-Za-z/!?])')
REFDEF_RE = re.compile(r'(?m)^(?:[ \t]*(?:>|[-+*][ \t]|\d{1,9}[.)][ \t]))*[ \t]*\[[^\]]*\][ \t]*:')
EMPTY_ITEM_RE = re.compile(r'^(?:[ \t]{0,3}>[ \t]?)*[ \t]{0,3}(?:[-+*]|\d{1,9}[.)])[ \t]*$')
DELIM_RUN_RE = re.compile(r'\*+|_+')
BQ_PREFIX_RE = re.compile(r'^(?:[ \t]{0,3}>[ \t]?)*')


class RawHtmlFound(Exception):
    pass


HTML_START_CHARS = set('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz/!?')


class CheckedBlockParser(ref.BlockParser):
    def on_block_start_lt(self):
        i = self.first_nonspace + 1
        if peek_next(self.line, i - 1) in HTML_START_CHARS and not (
                ref.AUTOLINK_URI_RE.match(self.line, i) or ref.AUTOLINK_EMAIL_RE.match(self.line, i)):
            raise RawHtmlFound("'<' starting a line's content on line %d" % self.line_number)


class CheckedInlineParser(ref.InlineParser):
    def on_literal_lt(self):
        if peek_next(self.s, self.pos - 1) in HTML_START_CHARS:
            raise RawHtmlFound("literal '<' followed by %r" % self.s[self.pos])


def peek_next(s, i):
    return s[i + 1] if i + 1 < len(s) else ''


def raw_html_violation(text):
    """Runs the reference with hooks that reject any '<' cmark could read as HTML."""
    saved = ref.BlockParser, ref.InlineParser
    ref.BlockParser, ref.InlineParser = CheckedBlockParser, CheckedInlineParser
    try:
        ref.convert(text)
    except RawHtmlFound as e:
        return str(e)
    finally:
        ref.BlockParser, ref.InlineParser = saved
    return None


def subset_violation(data):
    """Returns a reason string when `data` (bytes) breaks a SPEC guarantee, else None."""
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return 'invalid UTF-8'
    if text.startswith('\ufeff'):
        return 'BOM'
    for ch in text:
        o = ord(ch)
        if (o < 32 and ch not in '\t\n') or o == 127:
            return 'control character %r' % ch
    for m in ENTITY_NAME_RE.finditer(text):
        name = m.group(1)
        if name not in NAMED_OK and name + ';' in HTML5:
            return 'named entity &%s;' % name
    for m in DELIM_RUN_RE.finditer(text):
        for ch in (text[m.start() - 1] if m.start() > 0 else '', text[m.end()] if m.end() < len(text) else ''):
            if ch and ord(ch) >= 128 and unicodedata.category(ch)[0] in 'ZPSC':
                return 'non-ASCII whitespace/punctuation %r next to delimiter run' % ch
    for m in re.finditer(r'`+', text):
        if m.end() - m.start() > 100:
            return 'backtick run longer than 100'
    m = REFDEF_RE.search(text)
    if m:
        return 'link reference definition on line %d' % (text.count('\n', 0, m.start()) + 1)
    lines = text.split('\n')
    for i, line in enumerate(lines):
        if EMPTY_ITEM_RE.match(line) and i + 1 < len(lines):
            nxt = BQ_PREFIX_RE.sub('', lines[i + 1])
            if nxt.strip(' \t') == '' and nxt != '':
                return 'whitespace-only line after empty list item on line %d' % (i + 1)
    if LT_RE.search(text):
        return raw_html_violation(text)
    return None


# ---------------------------------------------------------------------------
# Random document generator
# ---------------------------------------------------------------------------
WORDS = ('foo bar baz qux lorem ipsum dolor sit amet alpha beta gamma delta epsilon zeta eta theta '
         'iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega one two three '
         'four five six seven eight nine ten hello world markdown html text link code list item quote').split()
UNICODE_WORDS = ['café', 'naïve', 'Ünïcödé', '日本語', 'テキスト', 'Привет', 'straße', 'ñandú', 'αβγ', 'עברית']
PUNCT = ['.', ',', '!', '?', ':', ';', '(', ')', '-', "'", '"', '/', '#', '+', '=', '~', '|', '{', '}', '^', '$', '%', '@']


def word(rng):
    r = rng.random()
    if r < 0.05:
        return rng.choice(UNICODE_WORDS)
    if r < 0.08:
        return rng.choice(WORDS).capitalize()
    if r < 0.10:
        return str(rng.randint(0, 99999))
    return rng.choice(WORDS)


def entity(rng):
    return rng.choice(['&amp;', '&lt;', '&gt;', '&quot;', '&#35;', '&#X22;', '&#x41;', '&#169;', '&#1234;',
                       '&#128512;', '&#x1F600;', '&#0;', '&#xD800;', '&#1234567;', '&#12345678;', '&#x110000;',
                       '&#xABCDEF1;', '&#;', '&#x;', '&foo;', '&x y;', '&amp', '&Amp;', '&&amp;&', '&#39;'])


def escape(rng):
    return rng.choice(['\\*', '\\_', '\\\\', '\\`', '\\[', '\\]', '\\(', '\\)', '\\#', '\\!', '\\>', '\\&',
                       '\\a', '\\1', '\\ ', '\\-', '\\+', '\\.', '\\"', "\\'", '\\~', '\\|', '\\< '])


def code_span(rng):
    n = rng.choice([1, 1, 1, 2, 2, 3])
    ticks = '`' * n
    inner = rng.choice([
        lambda: word(rng),
        lambda: ' ' + word(rng) + ' ',
        lambda: ' ' + word(rng),
        lambda: word(rng) + '  ',
        lambda: '  ',
        lambda: ' ',
        lambda: '`' * rng.choice([m for m in (1, 2, 3, 4) if m != n]) + word(rng),
        lambda: word(rng) + ' ' + '`' * rng.choice([m for m in (1, 2, 3, 4) if m != n]) + ' ' + word(rng),
        lambda: '*' + word(rng) + '* < ' + word(rng) + ' > &amp; \\' + word(rng),
        lambda: word(rng) + '\n' + word(rng),
        lambda: '\t' + word(rng) + '\t',
        lambda: '[' + word(rng) + '](/x)',
        lambda: '',
    ])()
    if inner == '' and n == 1:
        inner = 'x'
    return ticks + inner + ticks


def destination(rng):
    r = rng.random()
    base = '/' + word(rng)
    if r < 0.30:
        return base
    if r < 0.45:
        return 'http://example.com/' + word(rng) + rng.choice(['', '?a=1&b=2', '#frag', '/path/', '.html'])
    if r < 0.55:
        return '<' + base + rng.choice(['', ' ' + word(rng), '/a b', '\\>x', '&amp;x', '(paren)', 'ü']) + '>'
    if r < 0.62:
        return base + '(' + word(rng) + ')' + rng.choice(['', '/' + word(rng)])
    if r < 0.68:
        return base + rng.choice(['\\)', '\\(', '&amp;', '&#35;', '%20', 'ü', '~!*(),', "'q'", '"dq"', '[b]', '{c}', '`t`', '\\\\', '<3', '|'])
    if r < 0.72:
        return ''
    if r < 0.75:
        return '<>'
    if r < 0.80:
        return rng.choice(['javascript:alert(1)', 'JavaScript:x', 'vbscript:y', 'file:///etc/passwd', 'data:text/html,x',
                           'data:image/png;base64,AAA', 'DATA:image/gif;base64,AAA', 'data:image/jpeg,x', 'javascript', 'mailto:a@b.c'])
    if r < 0.85:
        return base + '\\&amp;' + rng.choice(['', 'x'])
    if r < 0.90:
        return '&#92;*' + word(rng)
    if r < 0.95:
        return base + ' ' + word(rng)  # invalid: space in bare destination
    return '(' * rng.randint(1, 3) + word(rng) + ')' * rng.randint(1, 3)


def title(rng):
    inner = rng.choice([word(rng), word(rng) + ' ' + word(rng), '', 'a "quoted" b', "it's", 'x\\"y', 'a&amp;b &lt; &#35;',
                        'multi\nline', 'paren (inside)', 'back\\\\slash', 'ü', 'x\\)y', '*emph*'])
    q = rng.choice(['"', "'", '('])
    if q == '(':
        inner = inner.replace('(', '\\(').replace(')', '\\)') if rng.random() < 0.7 else inner
        return '(' + inner + ')'
    if q == '"':
        inner = inner.replace('"', '\\"') if rng.random() < 0.7 else inner
    else:
        inner = inner.replace("'", "\\'") if rng.random() < 0.7 else inner
    return q + inner + q


def link_text(rng, depth):
    r = rng.random()
    if r < 0.5:
        return word(rng)
    if r < 0.7:
        return inline_run(rng, depth + 1, 3)
    if r < 0.8:
        return ''
    if r < 0.9:
        return '*' + word(rng) + '* `' + word(rng) + '`'
    return word(rng) + ' [' + word(rng) + '] ' + word(rng)


def link(rng, depth):
    text = link_text(rng, depth)
    dest = destination(rng)
    sep = rng.choice(['', '', ' ', '\n', ' \t '])
    t = rng.random()
    r = rng.random()
    invalid = t >= 0.9 or r >= 0.85
    html_like = dest.startswith('<') and len(dest) > 1 and dest[1] in HTML_START_CHARS
    if html_like and invalid:
        dest = '/' + word(rng)
        html_like = False
    if html_like:
        # A '<' that looks like HTML is allowed only inside a valid link's
        # destination and never at the start of a line's content, so the
        # whole link stays on one line where nothing can split it, with a
        # plain-text label (a nested link would deactivate the outer one).
        text = word(rng)
        ttl = title(rng).replace('\n', ' ')
        inside = ' ' + dest + ('' if t < 0.4 else ' ' + ttl)
    else:
        if t < 0.4:
            inside = dest
        elif t < 0.9:
            inside = dest + rng.choice([' ', '  ', '\n']) + title(rng)
        else:
            inside = dest + title(rng)  # no space: the title text joins a bare destination
        inside = sep + inside + rng.choice(['', '', ' ', '\n'])
    bang = '!' if rng.random() < 0.3 else ''
    if r < 0.85:
        return bang + '[' + text + '](' + inside + ')'
    if r < 0.9:
        return bang + '[' + text + '] (' + inside + ')'  # space before ( -> not a link
    if r < 0.95:
        return bang + '[' + text + '](' + inside      # unclosed
    return bang + '[' + text + ']' + rng.choice(['', '[]', '[ref]'])


def autolink(rng):
    return rng.choice([
        '<http://example.com/' + word(rng) + '>',
        '<https://a.b/?x=1&y=2&amp;z=3>',
        '<mailto:' + word(rng) + '@example.org>',
        '<' + rng.choice(WORDS) + '@' + rng.choice(WORDS) + '.com>',
        '<MAILTO:FOO@BAR.BAZ>',
        '<ftp://x.y/z%20w>',
        '<made-up+scheme.x:whatever>',
        '<ab:c>', '<ab:>',
        '< http://x y >',          # space after '<': not an autolink, '<' is text
        '<http://a.b/&#65;&lt;>',
        '<file:///x>',
        '<javascript:alert(1)>',
        '<foo@bar>', '<foo.bar@x-y.z9.example>', '<>', '<3>',
    ])


def delim_run(rng):
    return rng.choice(['*', '**', '***', '_', '__', '___', '****', '*_', '_*', '**_', '_**'])


def emphasis(rng, depth):
    inner = inline_run(rng, depth + 1, 3) if depth < 2 else word(rng)
    d = rng.choice(['*', '**', '_', '__', '***', '___', '*', '**'])
    r = rng.random()
    if r < 0.6:
        return d + inner + d
    if r < 0.7:
        return d + ' ' + inner + d          # not left flanking
    if r < 0.8:
        return d + inner + ' ' + d
    if r < 0.9:
        return d + inner + rng.choice(['*', '**', '_', '__'])
    return word(rng) + d + inner + d + word(rng)   # intraword


def hard_break(rng):
    return rng.choice(['  \n', '   \n', '\\\n', '\\\n   ', ' \n'])


def inline_atom(rng, depth):
    r = rng.random()
    if r < 0.40:
        return word(rng)
    if r < 0.48:
        return rng.choice(PUNCT)
    if r < 0.55:
        return emphasis(rng, depth)
    if r < 0.60:
        return delim_run(rng)
    if r < 0.66:
        return code_span(rng)
    if r < 0.73:
        return link(rng, depth)
    if r < 0.76:
        return autolink(rng)
    if r < 0.81:
        return entity(rng)
    if r < 0.86:
        return escape(rng)
    if r < 0.89:
        return rng.choice(['[', ']', '![', '!', '< ', '>', '<3', '<>', '< /', '<-', '<=', '&', '"', "'"])
    if r < 0.92:
        return hard_break(rng)
    if r < 0.95:
        return rng.choice(['\t', '  ', ' \t '])
    return ' ' + rng.choice(['😀', '🎉', '→', '—', '…', '«»']) + ' '


def is_sep(atom):
    return atom in ('', '\t', '  ', ' \t ') or atom.endswith('\n')


def inline_run(rng, depth=0, n=None):
    if n is None:
        n = rng.randint(1, 12)
    atoms = [inline_atom(rng, depth) for _ in range(n)]
    out = []
    for a in atoms:
        if out and rng.random() < 0.8 and not is_sep(out[-1]) and not is_sep(a):
            out.append(' ')
        out.append(a)
    return ''.join(out)


def paragraph_lines(rng):
    n = rng.choice([1, 1, 2, 2, 3, 4])
    lines = []
    for _ in range(n):
        text = inline_run(rng)
        for piece in text.split('\n'):
            lines.append(piece)
    lines = [ln if ln.strip(' \t') else word(rng) for ln in lines]
    return lines


def indent_lines(lines, prefix, first_prefix=None):
    out = []
    for i, ln in enumerate(lines):
        p = first_prefix if (i == 0 and first_prefix is not None) else prefix
        out.append((p + ln) if ln != '' or i == 0 else '')
    return out


def block(rng, depth, allow_setext=True):
    """Returns a list of lines for one random block (no trailing blank line)."""
    r = rng.random()
    if r < 0.30 or depth >= 4:
        return paragraph_lines(rng)
    if r < 0.38:
        level = rng.randint(1, 6)
        content = inline_run(rng, 0, rng.randint(0, 5))
        close = rng.choice(['', '', ' #', ' ###', ' # ', '#', ' \\#', '  ##  ', ' # #'])
        return [' ' * rng.randint(0, 3) + '#' * level + rng.choice([' ', '  ', '\t', '']) + content + close]
    if r < 0.43 and allow_setext:
        lines = paragraph_lines(rng)
        under = rng.choice(['===', '=', '---', '-', '------   ', '  ==', '- - -', '=== =']) + rng.choice(['', ' ', '\t'])
        return lines + [under]
    if r < 0.48:
        c = rng.choice('-*_')
        return [' ' * rng.randint(0, 3) + rng.choice([c * 3, c * 5, (c + ' ') * 3, (c + '  ') * 4, c + c + ' ' + c, c * 3 + '\t'])]
    if r < 0.55:
        lines = []
        for _ in range(rng.randint(1, 4)):
            lines.append(rng.choice(['    ', '\t', '     ', '  \t', '    \t']) + rng.choice([inline_run(rng, 0, 4), '&lt;div&gt;*x* < b', '  indented more', word(rng) + '  ']))
            if rng.random() < 0.3:
                lines.append(rng.choice(['', '  ', '    ', '\t']))
        while lines and lines[-1].strip() == '':
            lines.pop()
        return lines
    if r < 0.65:
        fence_char = rng.choice('`~')
        n = rng.choice([3, 3, 3, 4, 5])
        fence = fence_char * n
        info = rng.choice(['', '', 'python', 'c++ extra words', ' js', 'language-rust', 'a&amp;b\\!', 'x`y' if fence_char == '~' else 'x', 'ü日本', '\tt'])
        ind = ' ' * rng.randint(0, 3)
        lines = [ind + fence + info]
        for _ in range(rng.randint(0, 5)):
            lines.append(rng.choice(['', '  ' + word(rng), word(rng) + ' *' + word(rng) + '* < b > &lt;b&gt; &amp; \\', '\t' + word(rng), '    ' + word(rng), fence_char * (n - 1), ' ' + fence + ' ' + word(rng), '   ' + word(rng)]))
        close = rng.random()
        if close < 0.8:
            lines.append(' ' * rng.randint(0, 3) + fence_char * rng.choice([n, n, n + 1, n + 2]) + rng.choice(['', ' ', '  \t']))
        elif close < 0.9:
            lines.append('    ' + fence)   # too indented: not a closing fence
        return lines
    if r < 0.80:
        inner = blocks(rng, depth + 1, rng.randint(1, 3))
        style = rng.random()
        out = []
        for i, ln in enumerate(inner):
            if style < 0.5:
                out.append('> ' + ln if ln else '>')
            elif style < 0.7:
                out.append('>' + ln if ln else '>')
            elif style < 0.85:
                out.append(rng.choice(['> ', '>', '>  ', ' > ', '>\t']) + ln if ln else rng.choice(['>', '', '> ']))
            else:
                # Lazy continuation: some non-first lines lose their marker.
                if i > 0 and ln and rng.random() < 0.5 and out and out[-1].startswith('>'):
                    out.append(ln)
                else:
                    out.append('> ' + ln if ln else '>')
        return out
    return list_block(rng, depth)


def list_block(rng, depth):
    ordered = rng.random() < 0.4
    if ordered:
        start = rng.choice([1, 1, 1, 0, 2, 7, 10, 42, 123456789, 999999999])
        delim = rng.choice(['.', ')'])
    else:
        bullet = rng.choice('-*+')
    n_items = rng.randint(1, 5)
    loose = rng.random() < 0.3
    out = []
    num = start if ordered else 0
    for i in range(n_items):
        if ordered:
            marker = str(num if i == 0 or rng.random() < 0.8 else rng.randint(1, 20)) + delim
            num += 1
        else:
            marker = bullet
            if rng.random() < 0.08:
                marker = rng.choice('-*+')     # changes list type
        gap = rng.choice([' ', ' ', ' ', '  ', '   ', '    ', '     ', '\t'])
        lead = ' ' * rng.choice([0, 0, 0, 1, 2, 3])
        width = len(lead) + len(marker) + (len(gap) if gap != '\t' else 1)
        cont_indent = ' ' * (len(lead) + len(marker) + (len(gap) if gap != '\t' and len(gap) < 5 else 1))
        r = rng.random()
        if r < 0.08:
            out.append(lead + marker)            # empty item
            if rng.random() < 0.5:
                out.append('')
            continue
        content = blocks(rng, depth + 1, rng.randint(1, 3) if rng.random() < 0.4 else 1)
        first = lead + marker + gap + content[0]
        rest = [(cont_indent + ln) if ln else '' for ln in content[1:]]
        if rng.random() < 0.15 and rest:
            # Lazy continuation / under-indented lines.
            rest = [ln.lstrip(' ') if (ln and rng.random() < 0.5) else ln for ln in rest]
        out.append(first)
        out.extend(rest)
        if loose and i < n_items - 1:
            out.append('')
        elif rng.random() < 0.1:
            out.append('')
    while out and out[-1] == '':
        out.pop()
    return out


def blocks(rng, depth, n):
    out = []
    for i in range(n):
        b = block(rng, depth)
        if i > 0:
            sep = rng.random()
            if sep < 0.75:
                out.append('')
            elif sep < 0.85:
                out.append('')
                out.append('')
            # otherwise no blank line: paragraph continuation / interruption cases
        out.extend(b)
    return out


def gen_document(seed, target_bytes, depth=0):
    rng = random.Random(seed)
    lines = []
    size = 0
    while size < target_bytes:
        b = blocks(rng, depth, rng.randint(1, 4))
        lines.extend(b)
        lines.append('')
        size += sum(len(x.encode('utf-8')) + 1 for x in b) + 1
    text = '\n'.join(lines) + '\n'
    return text


def gen_chaos(seed, n_lines):
    """Random lines from a pool of block-structure fragments, at random indents."""
    rng = random.Random(seed)
    pool = ['- a', '* b', '+ c', '1. d', '2) e', '10. f', '-', '1.', '> g', '>', '> > h', '>>', '# i', '## j ##',
            '###', '====', '---', '***', '- - -', '___', '```', '~~~', '```py', '````', '~~~~', '    code', '\tcode',
            'k', 'l m', '', '', '', '  ', '\t', 'n\\', 'o  ', '*p*', '**q', 'r**', '`s', 't`', '[u', 'v](w)', '[x](y "z")',
            '- - a', '-  b', '-   c', '-    d', '-     e', '1.  f', '1)   g', '- > h', '> - i', '> 1. j', '- # k',
            '- ```', '- ~~~', '-\tl', '>\tm', ' - n', '  - o', '   - p', '    - q', '     - r', '2. s', '3) t',
            '*', '**', '- *', '- **', '* * *', '- ***', '1. ---', '- ===', '# #', '#', '   #', '#\tx', '`', '``', '```x```',
            'a *b* c', '_x_ y', '__z__', '***w***', 'foo< bar', 'foo<3', 'a <http://x.y> b', 'x &amp; y', '&#35;', 'v\\',
            '- [w](x)', '> [y](z "t")', '![i](j)', '`code`', '``co`de``', 'ab  ', 'cd\\', '=', '=\t', '-\t', '--', '- -']
    lines = []
    for _ in range(n_lines):
        ln = rng.choice(pool)
        ind = rng.choice(['', '', '', ' ', '  ', '   ', '    ', '\t', ' \t'])
        lines.append(ind + ln if ln else ln)
    # A whitespace-only line right after an empty list item is outside the subset.
    for i in range(len(lines) - 1):
        if EMPTY_ITEM_RE.match(lines[i]) and lines[i + 1] != '' and lines[i + 1].strip(' \t') == '':
            lines[i + 1] = ''
    return '\n'.join(lines) + ('\n' if rng.random() < 0.8 else '')


# ---------------------------------------------------------------------------
# Spec examples
# ---------------------------------------------------------------------------
def extract_spec_examples(spec_path):
    """Extracts the examples of spec.txt that lie inside the subset."""
    txt = open(spec_path, encoding='utf-8').read()
    lines = txt.split('\n')
    examples = []
    sec = ''
    i = 0
    num = 0
    while i < len(lines):
        ln = lines[i]
        m = re.match(r'^(#+) (.*)', ln)
        if m:
            sec = m.group(2)
        if ln.startswith('```````````````````````````````` example'):
            num += 1
            j = i + 1
            md = []
            while lines[j] != '.':
                md.append(lines[j])
                j += 1
            j += 1
            html_lines = []
            while not lines[j].startswith('````````````````````````````````'):
                html_lines.append(lines[j])
                j += 1
            md_text = '\n'.join(md).replace('→', '\t') + '\n'
            html_text = '\n'.join(html_lines).replace('→', '\t') + ('\n' if html_lines else '')
            examples.append({'n': num, 'sec': sec, 'md': md_text, 'html': html_text})
            i = j
        i += 1
    keep = []
    for e in examples:
        if e['sec'] in ('HTML blocks', 'Raw HTML', 'Link reference definitions'):
            continue
        if subset_violation(e['md'].encode('utf-8')):
            continue
        if b'raw HTML omitted' in run_cmark(e['md'].encode('utf-8')):
            continue
        keep.append(e)
    return keep


def spec_groups(examples):
    """Groups examples per section into files separated by thematic breaks.

    An example joins the current group only if cmark's output for the joined
    text is exactly the concatenation of the individual outputs, so no
    example's meaning is changed by its neighbours (e.g. an unclosed fence).
    """
    sep = '\n\n* * * * *\n\n'
    sep_html = b'<hr />\n'
    groups = []
    by_sec = {}
    for e in examples:
        by_sec.setdefault(e['sec'], []).append(e)
    for sec, exs in by_sec.items():
        cur_text = None
        cur_html = None
        cur_n = []
        for e in exs:
            md = e['md'].rstrip('\n')
            if cur_text is None:
                cur_text, cur_html, cur_n = md, run_cmark((md + '\n').encode('utf-8')), [e['n']]
                continue
            joined = cur_text + sep + md
            expect = cur_html + sep_html + run_cmark((md + '\n').encode('utf-8'))
            got = run_cmark((joined + '\n').encode('utf-8'))
            if got == expect and not subset_violation((joined + '\n').encode('utf-8')):
                cur_text, cur_html, cur_n = joined, got, cur_n + [e['n']]
            else:
                groups.append((sec, cur_n, cur_text + '\n'))
                cur_text, cur_html, cur_n = md, run_cmark((md + '\n').encode('utf-8')), [e['n']]
        groups.append((sec, cur_n, cur_text + '\n'))
    return groups


# ---------------------------------------------------------------------------
# Oracle
# ---------------------------------------------------------------------------
def run_cmark(data):
    proc = subprocess.run([CMARK], input=data, capture_output=True)
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


def run_reference(data):
    proc = subprocess.run([sys.executable, REF], input=data, capture_output=True, timeout=600)
    assert proc.returncode == 0, proc.stderr.decode()
    return proc.stdout


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------
cases = []


def add(name, data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    cases.append((name, data))


def build_cases():
    add('empty', '')
    add('single_word', 'hello')
    add('paragraphs', 'first paragraph\nsecond line\n\nsecond paragraph\n\n\n\nthird\n')
    add('headings', '# h1\n## h2 ##\n###### h6\n####### not a heading\n#hashtag\n\\# escaped\n#\n# foo \\#\n  ### indented   \n    # code\n'
        'Setext one\n===\nSetext two\n---\n---\n')
    add('thematic_breaks', '***\n---\n___\n - - -\n  *\t*\t*\n**\n--\n_ _ _ _ _ _\n***a\n * * * * \n')
    add('code_blocks', '    indented\n      more\n\n    after blank\n    \n\ttab\n\n```\nfenced\n```\n\n~~~python\ndef f():\n    return 1\n~~~\n\n'
        '````md\n```\ninner\n```\n````\n\n```language-x\nno double prefix\n```\n\n  ```  c++  extra\n  code\n   more\n  ```\n\n```\nunclosed\n')
    add('block_quotes', '> quote\n> more\nlazy\n\n> nested\n> > deeper\n> > > deepest\n>\n> back\n\n>no space\n>  two spaces\n>\t tab\n\n> # heading\n> - list\n> - items\n>\n>     code\n\n>\n')
    add('lists_basic', '- one\n- two\n- three\n\n* a\n* b\n\n+ x\n\n1. first\n2. second\n3. third\n\n1) paren\n2) style\n\n0. zero\n\n7. seven\n8. eight\n\n123456789. big\n\n1234567890. too many digits\n')
    add('lists_tight_loose', '- a\n- b\n\n- c\n\n\n- d\n- e\n\n  para\n- f\n\n1. x\n\n   y\n2. z\n\n- ```\n  code\n\n\n  ```\n- after\n\n- p\n\n      code\n- q\n')
    add('lists_nested', '- a\n  - b\n    - c\n      - d\n  - e\n- f\n\n1. one\n   - sub\n   - sub2\n2. two\n\n   1. nested ordered\n\n   2. loose\n\n- x\n - y\n  - z\n   - w\n    - deep indented\n')
    add('lists_indentation', '-   four spaces\n\n    para in item\n\n-     five spaces means code\n\n- \tone tab\n\n  1.  two\n\n      inner\n\n10. ten\n    continuation\n   lazy\n\n- a\n\n\n  b\n\n-\n  empty first line then text\n\n-\n\n  foo\n')
    add('inline_basic', '*em* **strong** ***both*** _em_ __strong__ ___both___\n`code` ``co`de`` ` `` `\n[link](/url "title") [l](<a b> \'t\') ![img](/i.png "ti") ![*alt* `x`](/y)\n<http://example.com> <foo@bar.baz> <MAILTO:X@Y.Z>\n'
        'hard  \nbreak\\\nsoft\nbreak\n&amp; &lt; &gt; &quot; &#35; &#x41; &#X41; &copy &foo; &#0; &#xD800; &#1234567;\n\\* \\_ \\\\ \\a \\\n')
    add('emphasis_edge_cases', '*foo bar*\na * foo bar*\na*"foo"*\n* a *\nfoo*bar*\n5*6*78\n_foo bar_\n_ foo bar_\na_"foo"_\nfoo_bar_\n5_6_78\nпристаням_стремятся_\naa_"bb"_cc\nfoo-_(bar)_\n_foo*\n*foo bar *\n*foo bar\n*\n*(*foo)\n*(*foo*)*\n*foo*bar\n_foo bar _\n_(_foo)\n_(_foo_)_\n_foo_bar\n_пристаням_стремятся\n_foo_bar_baz_\n_(bar)_.\n**foo bar**\n** foo bar**\na**"foo"**\nfoo**bar**\n__foo bar__\n__ foo bar__\n__\nfoo bar__\na__"foo"__\nfoo__bar__\n5__6__78\nпристаням__стремятся__\n__foo, __bar__, baz__\nfoo-__(bar)__\n**foo bar **\n**(**foo)\n*(**foo**)*\n**Gomphocarpus (*Gomphocarpus physocarpus*, syn.\n*Asclepias physocarpa*)**\n**foo "*bar*" foo**\n**foo**bar\n__foo bar __\n__(__foo)\n_(__foo__)_\n__foo__bar\n__пристаням__стремятся\n__foo__bar__baz__\n__(bar)__.\n*foo [bar](/url)*\n*foo\nbar*\n_foo __bar__ baz_\n_foo _bar_ baz_\n__foo_ bar_\n*foo *bar**\n*foo **bar** baz*\n*foo**bar**baz*\n*foo**bar*\n***foo** bar*\n*foo **bar***\n*foo**bar***\nfoo***bar***baz\nfoo******bar*********baz\n*foo **bar *baz bim** bam*\n**foo **bar baz**\n*foo *bar baz*\n*[bar*](/url)\n_foo [bar_](/url)\n*a `*`*\n_a `_`_\n**a<http://foo.bar/?q=**>\n__a<http://foo.bar/?q=__>\n')
    add('rule_of_three', '*foo**bar**baz*\n*foo**bar*\n***foo** bar*\n*foo **bar***\n*foo**bar***\nfoo***bar***baz\nfoo******bar*********baz\n*foo **bar *baz bim** bam*\n**foo **bar baz**\n*foo *bar baz*\n**foo*\n*foo**\n***foo**\n****foo*\n**foo***\n*foo****\nfoo___bar___baz\n**foo*bar*baz**\n***foo***bar\n*a**b**c*d**e**f*\n**a*b*c**d*e*f**\n')
    add('links_and_images', '[link](/uri "title")\n[link](/uri)\n[](./target.md)\n[link]()\n[link](<>)\n[]()\n[link](/my uri)\n[link](</my uri>)\n[link](foo\nbar)\n[a](<b)c>)\n[link](\\(foo\\))\n[link](foo(and(bar)))\n[link](foo(and(bar))\n[link](foo\\(and\\(bar\\))\n[link](<foo(and(bar)>)\n[link](foo\\)\\:)\n[link](#fragment)\n[link](http://example.com#fragment)\n[link](http://example.com?foo=3#frag)\n[link](foo\\bar)\n[link](foo%20b&#228;)\n[link]("title")\n[link](/url "title")\n[link](/url \'title\')\n[link](/url (title))\n[link](/url "title "and" title")\n[link](/url \'title "and" title\')\n[link](   /uri\n  "title"  )\n[link] (/uri)\n[link [foo [bar]]](/uri)\n[link] bar](/uri)\n[link [bar](/uri)\n[link \\[bar](/uri)\n[link *foo **bar** `#`*](/uri)\n[![moon](moon.jpg)](/uri)\n[foo [bar](/uri)](/uri)\n[foo *[bar [baz](/uri)](/uri)*](/uri)\n![[[foo](uri1)](uri2)](uri3)\n*[foo*](/uri)\n[foo *bar](baz*)\n*foo [bar* baz]\n[foo`](/uri)`\n[foo<http://example.com/?search=](uri)>\n![foo](/url "title")\n![foo ![bar](/url)](/url2)\n![foo [bar](/url)](/url2)\n![foo](train.jpg)\nMy ![foo bar](/path/to/train.jpg  "title"   )\n![foo](<url>)\n![](/url)\n[x [a](b) y](d)\n[x [a](b) [c] y](d)\n[a](< b >)\n[a](/u "")\n[a](\\&amp;) [b](&#92;*) [c](/x?q=a&amp;b)\n[d](javascript:alert(1)) [e](JAVASCRIPT:x) [f](vbscript:x) [g](file:///x) [h](data:text/plain,x) [i](data:image/png;base64,x) ![j](Data:Image/WEBP;x) [k](javascriptx:) [l](/javascript:)\n[ü](/ü~!*()@#$%^&=+;:,?/\\\\[]{}|`<>"\')\n'
        '[x [a](/b) ![i](/j) y](/d)\n[x [a](/b) ![i ![q](/r) j](/k) y](/d)\n[x ![i](/j) [a](/b) y](/d)\n![x [a](/b) ![i](/j) y](/d)\n[x [a](/b) ![i [q] j](/k) y](/d)\n[x [a](/b) [q] y](/d)\n')
    add('autolinks', '<http://foo.bar.baz>\n<http://foo.bar.baz/test?q=hello&id=22&boolean>\n<irc://foo.bar:2233/baz>\n<MAILTO:FOO@BAR.BAZ>\n<a+b+c:d>\n<made-up-scheme://foo,bar>\n<http://../>\n<localhost:5001/foo>\n<http://example.com/\\[\\>\n<foo@bar.example.com>\n<foo+special@Bar.baz-bar0.com>\n<>\n< http://foo.bar >\n<3:abc> <-x:y>\nhttp://example.com\nfoo@bar.example.com\n<http://a.b/&#65;&lt;&amp;> <x@y.z> <file:///etc> <a@b>\n<abcdefghijklmnopqrstuvwxyzabcdef:x>\n<a@b.' + 'c' * 63 + '> <a@b.' + 'c' * 63 + '.' + 'd' * 63 + '>\n*<http://a.b/*> _<x@y.z>_ `<http://c.d>` [<http://e.f>](/g) <http://ü.example/ü?ü>\n')
    add('entities_and_escapes', '&nbsp &x; &#; &#x;\n&#87654321;\n&#abcdef0;\n&ThisIsNotDefined; &hi?;\n&#35; &#1234; &#992; &#0; &#X22; &#XD06; &#xcab; &#x110000; &#xDFFF; &#x10FFFF; &#1114111; &#1114112;\n&copy\n&MadeUpEntity;\n[foo](/f&#246;&#246; "f&#246;&#246;")\n``` f&#246;&#246;\nfoo\n```\n`f&#246;&#246;`\n    f&#246;f&#246;\n&#42;foo&#42;\n*foo*\n&#42; foo\n\n* foo\n\nfoo&#10;&#10;bar\n&#9;foo\n[a](url &quot;tit&quot;)\n\\!\\"\\#\\$\\%\\&\\\'\\(\\)\\*\\+\\,\\-\\.\\/\\:\\;\\<\\=\\>\\?\\@\\[\\\\\\]\\^\\_\\`\\{\\|\\}\\~\n\\\t\\A\\a\\ \\3\\φ\\«\n\\*not emphasized*\n\\<br/> not a tag\n\\[not a link](/foo)\n\\`not code`\n1\\. not a list\n\\* not a list\n\\# not a heading\n\\[foo]: /url "not a reference"\n\\&amp; not a character entity\n\\\\*emphasis*\nfoo\\\nbar\n`` \\[\\` ``\n    \\[\\]\n~~~\n\\[\\]\n~~~\n<http://example.com?find=\\*>\n[foo](/bar\\* "ti\\*tle")\n``` foo\\+bar\nfoo\n```\n')
    add('hard_and_soft_breaks', 'foo  \nbaz\nfoo\\\nbaz\nfoo       \nbaz\nfoo  \n     bar\nfoo\\\n     bar\n*foo  \nbar*\n*foo\\\nbar*\n`code  \nspan`\n`code\\\nspan`\nfoo\\\n\nfoo  \n\n### foo\\\n\n### foo  \n\nfoo \nbaz\nfoo\t\nbaz\nfoo \n baz\n\n> foo\\\n     bar\n\n> foo  \n     bar\n\n- a\\\n     b\n- c  \n     d\n')
    add('tabs', '\tfoo\tbaz\t\tbim\n\n  \tfoo\tbaz\t\tbim\n\n    a\ta\n    ὐ\ta\n\n  - foo\n\n\tbar\n\n- foo\n\n\t\tbar\n\n>\t\tfoo\n\n-\t\tfoo\n\n    foo\n\tbar\n\n - foo\n   - bar\n\t - baz\n\n#\tFoo\n\n*\t*\t*\t\n\n>\tquoted\tcontent\n\n- a\n\t- b\n\t\t- c\n\n1.\tone\n\n\ttwo\n')
    add('lazy_continuation', '> foo\nbar\n> baz\n\n> - a\nb\n\n- a\n> b\nc\n\n> 1. one\n> two\nthree\n\n> foo\n---\n\n> foo\n    - bar\n\n> ```\nfoo\n```\n\n- foo\n  - bar\nbaz\n\n1. a\n\n   b\nc\n\n> > > deep\nlazy\n> also\n\n> - x\n>   y\n> z\n  w\n')
    add('fenced_code_in_lists', '- ```\n  code\n  ```\n- item\n\n1. ~~~py\n   x = 1\n\n   y = 2\n   ~~~\n2. next\n\n- a\n\n  ```\n  b\n  ```\n\n- c\n\n  - ````\n    nested\n    ```\n    still\n    ````\n\n> - ```\n>   in quote\n>   ```\n\n- ```\n  unclosed\n- next item\n\n- text\n  ```\n  fence after text\n  ```\n')
    add('nested_block_quotes_and_lists', '> - a\n>   - b\n>     > c\n>     > d\n>   - e\n> - f\n>\n> > g\n> > - h\n> >\n> >   i\n> > - j\n\n- > a\n  > b\n\n  > c\n- > > d\n')
    add('interruptions', 'para\n# heading\npara\n> quote\npara\n- list\npara\n1. list\npara\n2. not list\npara\n- \npara\n```\nfence\n```\npara\n***\npara\n    not code\npara\n---\npara\n===\n\n- a\n***\n- b\n\n> a\n- b\n\n1. a\n\n    not code\n\n   1) b\n')
    add('list_item_starts', '-\n  foo\n-\n  ```\n  bar\n  ```\n-\n      baz\n\n- \n\n  foo\n\n-   foo\n\n    bar\n\n-    foo\n\n     bar\n\n-     foo\n\n      bar\n\n1.     indented code\n\n   paragraph\n\n       more code\n\n- foo\n\n\n  bar\n- \tfoo\n\n  1.  \tbar\n')
    add('list_changes_and_numbers', '- a\n* b\n+ c\n\n1. a\n1) b\n2. c\n\n003. three\n0. zero\n1. one\n\n1. a\n\n2. b\n\n\n\n3. c\n\n- a\n - b\n  - c\n   - d\n    - e\n\n1. a\n\n  2. b\n\n   3. c\n\n- a\n  - b\n  - c\n\n  d\n\n- e\n')
    add('unicode_content', '日本語のテキスト *強調* **太字** `コード` [リンク](/日本 "タイトル")\n\nПривет мир — «кавычки» … → ← 😀🎉\n\n> café naïve straße ñandú αβγ עברית\n\n```ü\n😀 emoji in code <b> &amp;\n```\n\n    ὐ\ttab after greek\n\n# 見出し #\n\nÜnïcödé\n===\n\n[😀](/😀 "😀") ![ü](/ü) <http://ü.example/ü?ü=ü>\n\nemoji 😀 near *emph* and _under_ score\n')
    add('paragraph_whitespace', '  leading spaces\n   more\n    still paragraph continuation\n\naaa\t\t\nbbb  \n\n  aaa\n bbb\n\naaa\n             bbb\n                                       ccc\n\n   aaa\nbbb\n\n    aaa\nbbb\n\naaa     \nbbb     \n\n\n  \n\t\n\nafter many blank lines\n')
    add('hardbreak_lazy_whitespace', '> foo\\\n   bar\n\n> foo  \n   bar\n\n- a\\\n   b\n\n> - a\\\n      b\n\n> x\\\n\tyy\n')

    # Spec examples grouped per section.
    examples = json.load(open(SPEC_JSON, encoding='utf-8'))
    for sec, nums, text in spec_groups(examples):
        slug = re.sub(r'[^a-z0-9]+', '_', sec.lower()).strip('_')
        add('spec_%s_%d_%d' % (slug, nums[0], nums[-1]), text)

    # Random structured documents, small to large.
    add('gen_small_1', gen_document(1, 600))
    add('gen_small_2', gen_document(2, 800))
    add('gen_small_3', gen_document(3, 1000))
    add('gen_medium_1', gen_document(11, 8_000))
    add('gen_medium_2', gen_document(12, 12_000))
    add('gen_medium_3', gen_document(13, 16_000))
    for i in range(6):
        add('gen_chaos_%d' % (i + 1), gen_chaos(100 + i, 60 + 40 * i))
    add('gen_large_1', gen_document(21, 200_000))
    add('gen_large_2', gen_document(22, 200_000))
    add('gen_chaos_large', gen_chaos(123, 12_000))

    # Deep nesting and pathological inline input.
    depth = 300
    add('deep_block_quotes', ''.join('>' * (i + 1) + ' level %d\n' % (i + 1) for i in range(depth)))
    add('deep_lists', ''.join('  ' * i + '- item %d\n' % i for i in range(depth)))
    add('deep_emphasis', '*' * 1 + ''.join('*a ' for _ in range(500)) + 'b' + ''.join(' a*' for _ in range(500)) + '*\n')
    add('many_unmatched_brackets', '[' * 5000 + 'x' + ']' * 5000 + '\n' + '![' * 3000 + 'y' + '](z)' * 3000 + '\n')
    add('many_delimiters', ' '.join('*a **b ***c' for _ in range(4000)) + '\n' + ''.join('_' * ((i % 7) + 1) + 'x' for i in range(8000)) + '\n' + '**' * 5000 + '\n')
    add('many_backticks', ' '.join('`' * ((i % 9) + 1) + 'x' for i in range(6000)) + '\n' + ''.join('``' + 'x' * (i % 5) for i in range(5000)) + '\n')
    add('long_paragraph', ' '.join(word(random.Random(7)) for _ in range(60_000)) + '\n')
    add('long_code_block', '```\n' + ''.join('line %d <b> &amp; "quoted" \'single\'\n' % i for i in range(20_000)) + '```\n')
    add('big_list', ''.join('%d. item *%d* with [link](/item/%d "t%d") and `c%d`\n%s' % (i, i, i, i, i, '\n' if i % 50 == 0 else '') for i in range(1, 12_000)))


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
def main():
    if len(sys.argv) >= 3 and sys.argv[1] == '--extract':
        keep = extract_spec_examples(sys.argv[2])
        json.dump(keep, open(SPEC_JSON, 'w', encoding='utf-8'), ensure_ascii=False, indent=0)
        print('%d in-subset spec examples written to %s' % (len(keep), SPEC_JSON))
        return
    build_cases()
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith('.in') or f.endswith('.out'):
            os.remove(os.path.join(TESTS, f))
    names = set()
    total = 0
    for idx, (name, data) in enumerate(cases, 1):
        assert name not in names, name
        names.add(name)
        base = '%03d_%s' % (idx, name)
        bad = subset_violation(data)
        assert bad is None, '%s violates the subset: %s' % (base, bad)
        expected = run_reference(data)
        oracle = run_cmark(data)
        if expected != oracle:
            sys.exit('ORACLE DISAGREEMENT on %s\nreference: %r\ncmark:     %r' % (base, expected[:400], oracle[:400]))
        with open(os.path.join(TESTS, base + '.in'), 'wb') as f:
            f.write(data)
        with open(os.path.join(TESTS, base + '.out'), 'wb') as f:
            f.write(expected)
        total += len(data) + len(expected)
        print('%-50s %8d bytes in %8d bytes out' % (base, len(data), len(expected)))
    print('%d tests written, %.1f MB total' % (len(cases), total / 1e6))


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'tests-notice.md'
TEST_LICENCES = [
    ('LICENSE-CC-BY-SA-4.0.txt',
     'LICENSE-CC-BY-SA-4.0.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == '__main__':
    main()
    copy_licences()
