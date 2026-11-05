#!/usr/bin/env python3
"""Reference CommonMark-subset to HTML converter for the `commonmark` problem.

Reads a Markdown document from stdin and writes HTML to stdout. The parser
follows the two-phase algorithm of the CommonMark specification (block
structure first, then inline content) and mirrors the C reference
implementation `cmark` closely so that its output is byte-for-byte identical
on every input inside the supported subset described in SPEC.md.
"""
import re
import sys
import unicodedata

TAB_STOP = 4
CODE_INDENT = 4
MAXBACKTICKS = 1000

# Block node types.
DOCUMENT = 'document'
BLOCK_QUOTE = 'block_quote'
LIST = 'list'
ITEM = 'item'
CODE_BLOCK = 'code_block'
HEADING = 'heading'
THEMATIC_BREAK = 'thematic_break'
PARAGRAPH = 'paragraph'
# Inline node types.
TEXT = 'text'
SOFTBREAK = 'softbreak'
LINEBREAK = 'linebreak'
CODE = 'code'
EMPH = 'emph'
STRONG = 'strong'
LINK = 'link'
IMAGE = 'image'

BULLET = 'bullet'
ORDERED = 'ordered'

ASCII_PUNCT = set('!"#$%&\'()*+,-./:;<=>?@[\\]^_`{|}~')
# cmark_isspace: the ASCII whitespace characters.
ASCII_SPACE = set(' \t\n\x0b\x0c\r')
LINE_END = ('\n', '\r')


class Node:
    __slots__ = (
        'type', 'parent', 'first_child', 'last_child', 'prev', 'next', 'open',
        'content', 'literal', 'last_line_blank', 'last_line_checked',
        'list_last_line_blank', 'start_line', 'fenced', 'fence_char',
        'fence_length', 'fence_offset', 'info', 'level', 'setext',
        'list_type', 'delimiter', 'bullet_char', 'start', 'tight',
        'marker_offset', 'padding', 'url', 'title', 'end_line')

    def __init__(self, type_, start_line=0):
        self.type = type_
        self.end_line = 0
        self.parent = self.first_child = self.last_child = None
        self.prev = self.next = None
        self.open = True
        self.content = []
        self.literal = ''
        self.last_line_blank = False
        self.last_line_checked = False
        self.list_last_line_blank = False
        self.start_line = start_line
        self.fenced = False
        self.fence_char = ''
        self.fence_length = 0
        self.fence_offset = 0
        self.info = ''
        self.level = 0
        self.setext = False
        self.list_type = BULLET
        self.delimiter = ''
        self.bullet_char = ''
        self.start = 0
        self.tight = False
        self.marker_offset = 0
        self.padding = 0
        self.url = ''
        self.title = None


def append_child(parent, child):
    child.parent = parent
    child.next = None
    if parent.last_child is not None:
        parent.last_child.next = child
        child.prev = parent.last_child
    else:
        parent.first_child = child
        child.prev = None
    parent.last_child = child


def unlink(node):
    if node.prev is not None:
        node.prev.next = node.next
    elif node.parent is not None:
        node.parent.first_child = node.next
    if node.next is not None:
        node.next.prev = node.prev
    elif node.parent is not None:
        node.parent.last_child = node.prev
    node.parent = node.prev = node.next = None


def insert_before(sibling, node):
    node.parent = sibling.parent
    node.prev = sibling.prev
    node.next = sibling
    if sibling.prev is not None:
        sibling.prev.next = node
    else:
        sibling.parent.first_child = node
    sibling.prev = node


def insert_after(sibling, node):
    node.parent = sibling.parent
    node.next = sibling.next
    node.prev = sibling
    if sibling.next is not None:
        sibling.next.prev = node
    else:
        sibling.parent.last_child = node
    sibling.next = node


def can_contain(parent_type, child_type):
    if parent_type in (DOCUMENT, BLOCK_QUOTE, ITEM):
        return child_type != ITEM
    if parent_type == LIST:
        return child_type == ITEM
    return False


def accepts_lines(t):
    return t in (PARAGRAPH, HEADING, CODE_BLOCK)


def peek(s, i):
    """Character at index i, or '' past the end (cmark's NUL)."""
    return s[i] if 0 <= i < len(s) else ''


def rtrim(s):
    i = len(s)
    while i > 0 and s[i - 1] in ASCII_SPACE:
        i -= 1
    return s[:i]


def ltrim(s):
    i = 0
    while i < len(s) and s[i] in ASCII_SPACE:
        i += 1
    return s[i:]


# ---------------------------------------------------------------------------
# Entities and escapes
# ---------------------------------------------------------------------------
NAMED_ENTITIES = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"'}
DEC_RE = re.compile(r'#([0-9]+);')
HEX_RE = re.compile(r'#[xX]([0-9a-fA-F]+);')
NAME_RE = re.compile(r'([A-Za-z][A-Za-z0-9]*);')


def unescape_entity(s, i):
    """Decodes the entity reference whose '&' is at s[i-1].

    Returns (replacement, length_consumed) or (None, 0) when the text at
    s[i:] is not a valid reference.
    """
    m = DEC_RE.match(s, i)
    if m:
        digits = m.group(1)
        if 1 <= len(digits) <= 7:
            cp = int(digits)
            return codepoint_char(cp), m.end() - i
        return None, 0
    m = HEX_RE.match(s, i)
    if m:
        digits = m.group(1)
        if 1 <= len(digits) <= 6:
            cp = int(digits, 16)
            return codepoint_char(cp), m.end() - i
        return None, 0
    m = NAME_RE.match(s, i)
    if m and m.group(1) in NAMED_ENTITIES:
        return NAMED_ENTITIES[m.group(1)], m.end() - i
    return None, 0


def codepoint_char(cp):
    if cp == 0 or 0xD800 <= cp < 0xE000 or cp >= 0x110000:
        cp = 0xFFFD
    return chr(cp)


def unescape_entities(s):
    """Replaces every valid entity reference in s (destinations, titles, info strings)."""
    out = []
    i = 0
    n = len(s)
    while i < n:
        j = s.find('&', i)
        if j < 0:
            out.append(s[i:])
            break
        out.append(s[i:j])
        rep, ln = unescape_entity(s, j + 1)
        if rep is None:
            out.append('&')
            i = j + 1
        else:
            out.append(rep)
            i = j + 1 + ln
    return ''.join(out)


def unescape_backslashes(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == '\\' and i + 1 < n and s[i + 1] in ASCII_PUNCT:
            i += 1
            c = s[i]
        out.append(c)
        i += 1
    return ''.join(out)


def clean_url(s):
    s = ltrim(rtrim(s))
    return unescape_backslashes(unescape_entities(s))


def clean_title(s):
    if not s:
        return None
    first, last = s[0], s[-1]
    if (first == "'" and last == "'") or (first == '(' and last == ')') or (first == '"' and last == '"'):
        s = s[1:-1]
    return unescape_backslashes(unescape_entities(s))


# ---------------------------------------------------------------------------
# Block parsing
# ---------------------------------------------------------------------------
ATX_RE = re.compile(r'#{1,6}(?:[ \t]+|[\r\n])')
OPEN_FENCE_RE = re.compile(r'`{3,}(?=[^`\r\n]*[\r\n])|~{3,}(?=[^\r\n]*[\r\n])')
CLOSE_FENCE_RE = re.compile(r'`{3,}(?=[ \t]*[\r\n])|~{3,}(?=[ \t]*[\r\n])')
SETEXT_RE = re.compile(r'(=+|-+)[ \t]*[\r\n]')


class BlockParser:
    def __init__(self):
        self.root = Node(DOCUMENT, 1)
        self.current = self.root
        self.line_number = 0
        self.line = ''
        self.offset = 0
        self.column = 0
        self.first_nonspace = 0
        self.first_nonspace_column = 0
        self.indent = 0
        self.blank = False
        self.partially_consumed_tab = False

    # -- low level line scanning helpers ------------------------------------
    def find_first_nonspace(self):
        line = self.line
        chars_to_tab = TAB_STOP - (self.column % TAB_STOP)
        if self.first_nonspace <= self.offset:
            fn = self.offset
            fnc = self.column
            while True:
                c = peek(line, fn)
                if c == ' ':
                    fn += 1
                    fnc += 1
                    chars_to_tab -= 1
                    if chars_to_tab == 0:
                        chars_to_tab = TAB_STOP
                elif c == '\t':
                    fn += 1
                    fnc += chars_to_tab
                    chars_to_tab = TAB_STOP
                else:
                    break
            self.first_nonspace = fn
            self.first_nonspace_column = fnc
        self.indent = self.first_nonspace_column - self.column
        self.blank = peek(line, self.first_nonspace) in LINE_END

    def advance_offset(self, count, columns):
        line = self.line
        while count > 0:
            c = peek(line, self.offset)
            if c == '':
                break
            if c == '\t':
                chars_to_tab = TAB_STOP - (self.column % TAB_STOP)
                if columns:
                    self.partially_consumed_tab = chars_to_tab > count
                    chars_to_advance = min(count, chars_to_tab)
                    self.column += chars_to_advance
                    if not self.partially_consumed_tab:
                        self.offset += 1
                    count -= chars_to_advance
                else:
                    self.partially_consumed_tab = False
                    self.column += chars_to_tab
                    self.offset += 1
                    count -= 1
            else:
                self.partially_consumed_tab = False
                self.offset += 1
                self.column += 1
                count -= 1

    def add_line(self, node):
        if self.partially_consumed_tab:
            self.offset += 1
            chars_to_tab = TAB_STOP - (self.column % TAB_STOP)
            node.content.append(' ' * chars_to_tab)
        if self.offset < len(self.line):
            node.content.append(self.line[self.offset:])

    # -- block tree manipulation --------------------------------------------
    def add_child(self, parent, block_type):
        while not can_contain(parent.type, block_type):
            parent = self.finalize(parent)
        child = Node(block_type, self.line_number)
        append_child(parent, child)
        return child

    def finalize(self, b):
        parent = b.parent
        b.open = False
        b.end_line = self.line_number
        if b.type == CODE_BLOCK:
            text = ''.join(b.content)
            if not b.fenced:
                b.literal = remove_trailing_blank_lines(text) + '\n'
            else:
                pos = 0
                while pos < len(text) and text[pos] not in LINE_END:
                    pos += 1
                info = text[:pos]
                if pos == 0:
                    b.info = ''
                else:
                    b.info = unescape_backslashes(ltrim(rtrim(unescape_entities(info))))
                if peek(text, pos) == '\r':
                    pos += 1
                if peek(text, pos) == '\n':
                    pos += 1
                b.literal = text[pos:]
        elif b.type in (PARAGRAPH, HEADING):
            b.literal = ''.join(b.content)
        elif b.type == LIST:
            b.tight = True
            item = b.first_child
            while item is not None:
                if item.last_line_blank and item.next is not None:
                    b.tight = False
                    break
                subitem = item.first_child
                while subitem is not None:
                    if (item.next is not None or subitem.next is not None) and ends_with_blank_line(subitem):
                        b.tight = False
                        break
                    subitem = subitem.next
                if not b.tight:
                    break
                item = item.next
        return parent

    # -- per-line driver ----------------------------------------------------
    def process_line(self, text):
        self.line = text + '\n'
        self.offset = 0
        self.column = 0
        self.first_nonspace = 0
        self.first_nonspace_column = 0
        self.indent = 0
        self.blank = False
        self.partially_consumed_tab = False
        self.line_number += 1

        container, all_matched = self.check_open_blocks()
        if container is None:
            return
        last_matched_container = container
        container = self.open_new_blocks(container, all_matched)
        self.add_text_to_container(container, last_matched_container)

    def check_open_blocks(self):
        all_matched = False
        container = self.root
        while container.last_child is not None and container.last_child.open:
            container = container.last_child
            t = container.type
            self.find_first_nonspace()
            if t == BLOCK_QUOTE:
                if not self.parse_block_quote_prefix():
                    break
            elif t == LIST:
                # A second consecutive unindented blank line inside a list
                # changes nothing, so the rest of the line is skipped.
                if self.blank:
                    if container.list_last_line_blank and self.indent == 0:
                        if self.current.type == CODE_BLOCK:
                            self.add_line(self.current)
                        return None, False
                    container.list_last_line_blank = True
                else:
                    container.list_last_line_blank = False
            elif t == ITEM:
                if not self.parse_item_prefix(container):
                    break
            elif t == CODE_BLOCK:
                r = self.parse_code_block_prefix(container)
                if r == 2:
                    return None, False
                if r == 0:
                    break
            elif t == HEADING:
                break
            elif t == PARAGRAPH:
                if self.blank:
                    break
        else:
            all_matched = True
        if not all_matched:
            container = container.parent
        return container, all_matched

    def parse_block_quote_prefix(self):
        if self.indent <= 3 and peek(self.line, self.first_nonspace) == '>':
            self.advance_offset(self.indent + 1, True)
            if peek(self.line, self.offset) in (' ', '\t'):
                self.advance_offset(1, True)
            return True
        return False

    def parse_item_prefix(self, container):
        need = container.marker_offset + container.padding
        if self.indent >= need:
            self.advance_offset(need, True)
            return True
        if self.blank and container.first_child is not None:
            self.advance_offset(self.first_nonspace - self.offset, False)
            return True
        return False

    def parse_code_block_prefix(self, container):
        """Returns 0 (no match), 1 (matched) or 2 (closing fence: line done)."""
        if not container.fenced:
            if self.indent >= CODE_INDENT:
                self.advance_offset(CODE_INDENT, True)
                return 1
            if self.blank:
                self.advance_offset(self.first_nonspace - self.offset, False)
                return 1
            return 0
        matched = 0
        if self.indent <= 3 and peek(self.line, self.first_nonspace) == container.fence_char:
            m = CLOSE_FENCE_RE.match(self.line, self.first_nonspace)
            if m:
                matched = m.end() - m.start()
        if matched >= container.fence_length:
            self.advance_offset(matched, False)
            self.current = self.finalize(container)
            return 2
        i = container.fence_offset
        while i > 0 and peek(self.line, self.offset) in (' ', '\t'):
            self.advance_offset(1, True)
            i -= 1
        return 1

    def open_new_blocks(self, container, all_matched):
        line = self.line
        maybe_lazy = self.current.type == PARAGRAPH
        while container.type != CODE_BLOCK:
            self.find_first_nonspace()
            fn = self.first_nonspace
            indented = self.indent >= CODE_INDENT
            c = peek(line, fn)
            if not indented and c == '<':
                self.on_block_start_lt()
            if not indented and c == '>':
                self.advance_offset(fn + 1 - self.offset, False)
                if peek(line, self.offset) in (' ', '\t'):
                    self.advance_offset(1, True)
                container = self.add_child(container, BLOCK_QUOTE)
            elif not indented and c == '#' and ATX_RE.match(line, fn):
                m = ATX_RE.match(line, fn)
                matched = m.end() - fn
                self.advance_offset(fn + matched - self.offset, False)
                container = self.add_child(container, HEADING)
                level = 0
                while peek(line, fn + level) == '#':
                    level += 1
                container.level = level
                container.setext = False
            elif not indented and c in '`~' and OPEN_FENCE_RE.match(line, fn):
                m = OPEN_FENCE_RE.match(line, fn)
                matched = m.end() - fn
                container = self.add_child(container, CODE_BLOCK)
                container.fenced = True
                container.fence_char = c
                container.fence_length = min(matched, 255)
                container.fence_offset = fn - self.offset
                self.advance_offset(fn + matched - self.offset, False)
            elif not indented and container.type == PARAGRAPH and c in '=-' and SETEXT_RE.match(line, fn):
                m = SETEXT_RE.match(line, fn)
                container.type = HEADING
                container.level = 1 if m.group(1)[0] == '=' else 2
                container.setext = True
                self.advance_offset(len(line) - 1 - self.offset, False)
            elif (not indented and not (container.type == PARAGRAPH and not all_matched)
                  and c in '*_-' and scan_thematic_break(line, fn)):
                container = self.add_child(container, THEMATIC_BREAK)
                self.advance_offset(len(line) - 1 - self.offset, False)
            elif self.indent < 4 and (c in '*+-' or c.isdigit() and c.isascii()):
                data = parse_list_marker(line, fn, container.type == PARAGRAPH)
                if data is None:
                    break
                matched = data['width']
                self.advance_offset(fn + matched - self.offset, False)
                save_tab = self.partially_consumed_tab
                save_offset = self.offset
                save_column = self.column
                while self.column - save_column <= 5 and peek(line, self.offset) in (' ', '\t'):
                    self.advance_offset(1, True)
                i = self.column - save_column
                if i >= 5 or i < 1 or peek(line, self.offset) in LINE_END:
                    padding = matched + 1
                    self.offset = save_offset
                    self.column = save_column
                    self.partially_consumed_tab = save_tab
                    if i > 0:
                        self.advance_offset(1, True)
                else:
                    padding = matched + i
                marker_offset = self.indent
                if (container.type != LIST or container.list_type != data['type']
                        or container.delimiter != data['delimiter']
                        or container.bullet_char != data['bullet_char']):
                    container = self.add_child(container, LIST)
                    self.set_list_data(container, data, marker_offset, padding)
                container = self.add_child(container, ITEM)
                self.set_list_data(container, data, marker_offset, padding)
            elif indented and not maybe_lazy and not self.blank:
                self.advance_offset(CODE_INDENT, True)
                container = self.add_child(container, CODE_BLOCK)
                container.fenced = False
            else:
                break
            if accepts_lines(container.type):
                break
            maybe_lazy = False
        return container

    def on_block_start_lt(self):
        """Hook: a '<' is the first non-blank character where a new block could start."""

    @staticmethod
    def set_list_data(node, data, marker_offset, padding):
        node.list_type = data['type']
        node.delimiter = data['delimiter']
        node.bullet_char = data['bullet_char']
        node.start = data['start']
        node.marker_offset = marker_offset
        node.padding = padding
        node.tight = False

    def add_text_to_container(self, container, last_matched_container):
        self.find_first_nonspace()
        if self.blank and container.last_child is not None:
            container.last_child.last_line_blank = True
        ctype = container.type
        last_line_blank = (
            self.blank and ctype != BLOCK_QUOTE and ctype != HEADING and ctype != THEMATIC_BREAK
            and not (ctype == CODE_BLOCK and container.fenced)
            and not (ctype == ITEM and container.first_child is None
                     and container.start_line == self.line_number))
        container.last_line_blank = last_line_blank
        tmp = container
        while tmp.parent is not None:
            tmp.parent.last_line_blank = False
            tmp = tmp.parent

        if (self.current is not last_matched_container and container is last_matched_container
                and not self.blank and self.current.type == PARAGRAPH):
            # Lazy continuation line.
            self.add_line(self.current)
            return
        while self.current is not last_matched_container:
            self.current = self.finalize(self.current)
        if ctype == CODE_BLOCK:
            self.add_line(container)
        elif self.blank:
            pass
        elif accepts_lines(ctype):
            if ctype == HEADING and not container.setext:
                self.line = chop_trailing_hashtags(self.line)
            self.advance_offset(self.first_nonspace - self.offset, False)
            self.add_line(container)
        else:
            container = self.add_child(container, PARAGRAPH)
            self.advance_offset(self.first_nonspace - self.offset, False)
            self.add_line(container)
        self.current = container

    def finish(self):
        while self.current is not self.root:
            self.current = self.finalize(self.current)
        self.finalize(self.root)
        return self.root


def ends_with_blank_line(node):
    if node.last_line_checked:
        return node.last_line_blank
    node.last_line_checked = True
    if node.type in (LIST, ITEM) and node.last_child is not None:
        return ends_with_blank_line(node.last_child)
    return node.last_line_blank


def remove_trailing_blank_lines(text):
    i = len(text) - 1
    while i >= 0 and text[i] in (' ', '\t', '\n', '\r'):
        i -= 1
    if i < 0:
        return ''
    while i < len(text):
        if text[i] in LINE_END:
            return text[:i]
        i += 1
    return text


def chop_trailing_hashtags(line):
    """Removes an optional closing sequence of #s (and the newline) from an ATX heading line."""
    line = rtrim(line)
    orig_n = n = len(line) - 1
    while n >= 0 and line[n] == '#':
        n -= 1
    if n != orig_n and n >= 0 and line[n] in (' ', '\t'):
        line = rtrim(line[:n])
    return line


def scan_thematic_break(line, i):
    c = line[i]
    count = 1
    i += 1
    while True:
        nextc = peek(line, i)
        if nextc == '':
            break
        if nextc == c:
            count += 1
        elif nextc != ' ' and nextc != '\t':
            break
        i += 1
    return count >= 3 and nextc in LINE_END


def parse_list_marker(line, pos, interrupts_paragraph):
    start = pos
    c = peek(line, pos)
    if c in '*-+':
        pos += 1
        if peek(line, pos) not in ASCII_SPACE or peek(line, pos) == '':
            return None
        if interrupts_paragraph:
            i = pos
            while peek(line, i) in (' ', '\t'):
                i += 1
            if peek(line, i) == '\n':
                return None
        return {'type': BULLET, 'bullet_char': c, 'start': 0, 'delimiter': '', 'width': pos - start}
    if c.isdigit() and c.isascii():
        num = 0
        digits = 0
        while True:
            num = num * 10 + (ord(line[pos]) - 48)
            pos += 1
            digits += 1
            if not (digits < 9 and peek(line, pos).isdigit() and peek(line, pos).isascii()):
                break
        if interrupts_paragraph and num != 1:
            return None
        c = peek(line, pos)
        if c not in ('.', ')'):
            return None
        pos += 1
        if peek(line, pos) not in ASCII_SPACE or peek(line, pos) == '':
            return None
        if interrupts_paragraph:
            i = pos
            while peek(line, i) in (' ', '\t'):
                i += 1
            if peek(line, i) in LINE_END:
                return None
        return {'type': ORDERED, 'bullet_char': '', 'start': num, 'delimiter': c, 'width': pos - start}
    return None


# ---------------------------------------------------------------------------
# Inline parsing
# ---------------------------------------------------------------------------
SPECIAL_CHARS = set('\n\r`\\&<*_[]!')
SPACECHARS_RE = re.compile(r'[ \t\x0b\x0c\r\n]*')
AUTOLINK_URI_RE = re.compile(r'[A-Za-z][A-Za-z0-9.+-]{1,31}:[^\x00-\x20<>]*>')
AUTOLINK_EMAIL_RE = re.compile(
    r"[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
    r"(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*>")


def is_unicode_space(ch):
    if ch == '':
        return True
    if ch in ' \t\n\x0c\r':
        return True
    return unicodedata.category(ch) == 'Zs'


def is_unicode_punct(ch):
    if ch == '':
        return False
    if ord(ch) < 128:
        return ch in ASCII_PUNCT
    return unicodedata.category(ch)[0] in 'PS'


class Delim:
    __slots__ = ('char', 'can_open', 'can_close', 'inl', 'position', 'length', 'prev', 'next')

    def __init__(self, char, can_open, can_close, inl, position):
        self.char = char
        self.can_open = can_open
        self.can_close = can_close
        self.inl = inl
        self.position = position
        self.length = len(inl.literal)
        self.prev = self.next = None


class Bracket:
    __slots__ = ('image', 'inl', 'prev', 'position', 'bracket_after')

    def __init__(self, image, inl, prev, position):
        self.image = image
        self.inl = inl
        self.prev = prev
        self.position = position
        self.bracket_after = False


class InlineParser:
    def __init__(self, text):
        self.s = text
        self.pos = 0
        self.last_delim = None
        self.last_bracket = None
        self.backticks = [0] * (MAXBACKTICKS + 1)
        self.scanned_for_backticks = False
        self.no_link_openers = True

    def peek(self, i=None):
        return peek(self.s, self.pos if i is None else i)

    def make_text(self, literal):
        n = Node(TEXT)
        n.literal = literal
        return n

    # -- delimiters ---------------------------------------------------------
    def push_delimiter(self, c, can_open, can_close, inl):
        d = Delim(c, can_open, can_close, inl, self.pos)
        d.prev = self.last_delim
        if d.prev is not None:
            d.prev.next = d
        self.last_delim = d

    def remove_delimiter(self, d):
        if d is None:
            return
        if d.next is None:
            self.last_delim = d.prev
        else:
            d.next.prev = d.prev
        if d.prev is not None:
            d.prev.next = d.next

    def push_bracket(self, image, inl):
        if self.last_bracket is not None:
            self.last_bracket.bracket_after = True
        self.last_bracket = Bracket(image, inl, self.last_bracket, self.pos)
        if not image:
            self.no_link_openers = False

    def pop_bracket(self):
        if self.last_bracket is not None:
            self.last_bracket = self.last_bracket.prev

    # -- the main loop ------------------------------------------------------
    def parse(self, parent):
        self.s = rtrim(self.s)
        s = self.s
        n = len(s)
        while self.pos < n:
            c = s[self.pos]
            if c in LINE_END:
                new = self.handle_newline()
            elif c == '`':
                new = self.handle_backticks()
            elif c == '\\':
                new = self.handle_backslash()
            elif c == '&':
                new = self.handle_entity()
            elif c == '<':
                new = self.handle_pointy_brace()
            elif c == '*' or c == '_':
                new = self.handle_delim(c)
            elif c == '[':
                self.pos += 1
                new = self.make_text('[')
                self.push_bracket(False, new)
            elif c == ']':
                new = self.handle_close_bracket(parent)
            elif c == '!':
                self.pos += 1
                if self.peek() == '[':
                    self.pos += 1
                    new = self.make_text('![')
                    self.push_bracket(True, new)
                else:
                    new = self.make_text('!')
            else:
                start = self.pos
                end = start + 1
                while end < n and s[end] not in SPECIAL_CHARS:
                    end += 1
                contents = s[start:end]
                self.pos = end
                if peek(s, end) in LINE_END:
                    contents = rtrim(contents)
                new = self.make_text(contents)
            if new is not None:
                append_child(parent, new)
        self.process_emphasis(0)

    def handle_newline(self):
        nlpos = self.pos
        if self.peek() == '\r':
            self.pos += 1
        if self.peek() == '\n':
            self.pos += 1
        while self.peek() in (' ', '\t'):
            self.pos += 1
        if nlpos > 1 and self.s[nlpos - 1] == ' ' and self.s[nlpos - 2] == ' ':
            return Node(LINEBREAK)
        return Node(SOFTBREAK)

    def handle_backslash(self):
        self.pos += 1
        nextchar = self.peek()
        if nextchar in ASCII_PUNCT:
            self.pos += 1
            return self.make_text(nextchar)
        if nextchar in LINE_END:
            if nextchar == '\r':
                self.pos += 1
            if self.peek() == '\n':
                self.pos += 1
            return Node(LINEBREAK)
        return self.make_text('\\')

    def handle_entity(self):
        self.pos += 1
        rep, ln = unescape_entity(self.s, self.pos)
        if rep is None:
            return self.make_text('&')
        self.pos += ln
        return self.make_text(rep)

    def handle_backticks(self):
        s = self.s
        start = self.pos
        while self.peek() == '`':
            self.pos += 1
        openticks = self.pos - start
        startpos = self.pos
        endpos = self.scan_to_closing_backticks(openticks)
        if endpos == 0:
            self.pos = startpos
            return self.make_text(s[start:startpos])
        code = normalize_code(s[startpos:endpos - openticks])
        node = Node(CODE)
        node.literal = code
        return node

    def scan_to_closing_backticks(self, openticklength):
        if openticklength > MAXBACKTICKS:
            return 0
        if self.scanned_for_backticks and self.backticks[openticklength] <= self.pos:
            return 0
        s = self.s
        n = len(s)
        while True:
            i = s.find('`', self.pos)
            if i < 0:
                self.pos = n
                break
            self.pos = i
            numticks = 0
            while self.peek() == '`':
                self.pos += 1
                numticks += 1
            if numticks <= MAXBACKTICKS:
                self.backticks[numticks] = self.pos - numticks
            if numticks == openticklength:
                return self.pos
        self.scanned_for_backticks = True
        return 0

    def scan_delims(self, c):
        s = self.s
        before_char = '\n' if self.pos == 0 else s[self.pos - 1]
        numdelims = 0
        while self.peek() == c:
            numdelims += 1
            self.pos += 1
        after_char = self.peek()
        if after_char == '':
            after_char = '\n'
        left_flanking = (not is_unicode_space(after_char)
                         and (not is_unicode_punct(after_char) or is_unicode_space(before_char)
                              or is_unicode_punct(before_char)))
        right_flanking = (not is_unicode_space(before_char)
                          and (not is_unicode_punct(before_char) or is_unicode_space(after_char)
                               or is_unicode_punct(after_char)))
        if c == '_':
            can_open = left_flanking and (not right_flanking or is_unicode_punct(before_char))
            can_close = right_flanking and (not left_flanking or is_unicode_punct(after_char))
        else:
            can_open = left_flanking
            can_close = right_flanking
        return numdelims, can_open, can_close

    def handle_delim(self, c):
        numdelims, can_open, can_close = self.scan_delims(c)
        inl = self.make_text(c * numdelims)
        if can_open or can_close:
            self.push_delimiter(c, can_open, can_close, inl)
        return inl

    def process_emphasis(self, stack_bottom):
        openers_bottom = [stack_bottom] * 15
        candidate = self.last_delim
        closer = None
        while candidate is not None and candidate.position >= stack_bottom:
            closer = candidate
            candidate = candidate.prev
        while closer is not None:
            if not closer.can_close:
                closer = closer.next
                continue
            base = 2 if closer.char == '_' else 8
            idx = base + (3 if closer.can_open else 0) + (closer.length % 3)
            opener = closer.prev
            opener_found = False
            while opener is not None and opener.position >= openers_bottom[idx]:
                if opener.can_open and opener.char == closer.char:
                    if (not (closer.can_open or opener.can_close) or closer.length % 3 == 0
                            or (opener.length + closer.length) % 3 != 0):
                        opener_found = True
                        break
                opener = opener.prev
            old_closer = closer
            if opener_found:
                closer = self.insert_emph(opener, closer)
            else:
                closer = closer.next
                openers_bottom[idx] = old_closer.position
                if not old_closer.can_open:
                    self.remove_delimiter(old_closer)
        while self.last_delim is not None and self.last_delim.position >= stack_bottom:
            self.remove_delimiter(self.last_delim)

    def insert_emph(self, opener, closer):
        opener_inl = opener.inl
        closer_inl = closer.inl
        opener_num = len(opener_inl.literal)
        closer_num = len(closer_inl.literal)
        use_delims = 2 if (closer_num >= 2 and opener_num >= 2) else 1
        opener_num -= use_delims
        closer_num -= use_delims
        opener_inl.literal = opener_inl.literal[:opener_num]
        closer_inl.literal = closer_inl.literal[:closer_num]

        d = closer.prev
        while d is not None and d is not opener:
            tmp = d.prev
            self.remove_delimiter(d)
            d = tmp

        emph = Node(EMPH if use_delims == 1 else STRONG)
        tmp = opener_inl.next
        while tmp is not None and tmp is not closer_inl:
            nxt = tmp.next
            unlink(tmp)
            append_child(emph, tmp)
            tmp = nxt
        insert_after(opener_inl, emph)

        if opener_num == 0:
            unlink(opener_inl)
            self.remove_delimiter(opener)
        if closer_num == 0:
            unlink(closer_inl)
            tmp = closer.next
            self.remove_delimiter(closer)
            closer = tmp
        return closer

    # -- links, images, autolinks -------------------------------------------
    def handle_pointy_brace(self):
        s = self.s
        self.pos += 1
        m = AUTOLINK_URI_RE.match(s, self.pos)
        is_email = False
        if m is None:
            m = AUTOLINK_EMAIL_RE.match(s, self.pos)
            is_email = True
        if m is None:
            self.on_literal_lt()
            return self.make_text('<')
        contents = s[self.pos:m.end() - 1]
        self.pos = m.end()
        link = Node(LINK)
        url = ltrim(rtrim(contents))
        link.url = ('mailto:' if is_email else '') + unescape_entities(url)
        link.title = None
        append_child(link, self.make_text(unescape_entities(contents)))
        return link

    def on_literal_lt(self):
        """Hook: a '<' that is not an autolink is being emitted as text."""

    def handle_close_bracket(self, parent):
        s = self.s
        self.pos += 1
        initial_pos = self.pos
        opener = self.last_bracket
        if opener is None:
            return self.make_text(']')
        is_image = opener.image
        if not is_image and self.no_link_openers:
            self.pop_bracket()
            return self.make_text(']')

        url = title = None
        matched = False
        if self.peek() == '(':
            sps = SPACECHARS_RE.match(s, self.pos + 1).end() - (self.pos + 1)
            res = scan_link_url(s, self.pos + 1 + sps)
            if res is not None:
                n, url_text = res
                endurl = self.pos + 1 + sps + n
                starttitle = SPACECHARS_RE.match(s, endurl).end()
                if starttitle == endurl:
                    endtitle = starttitle
                else:
                    endtitle = scan_link_title(s, starttitle)
                endall = SPACECHARS_RE.match(s, endtitle).end()
                if peek(s, endall) == ')':
                    self.pos = endall + 1
                    url = clean_url(url_text)
                    title = clean_title(s[starttitle:endtitle])
                    matched = True
        if not matched:
            self.pop_bracket()
            self.pos = initial_pos
            return self.make_text(']')

        inl = Node(IMAGE if is_image else LINK)
        inl.url = url
        inl.title = title
        insert_before(opener.inl, inl)
        tmp = opener.inl.next
        while tmp is not None:
            nxt = tmp.next
            unlink(tmp)
            append_child(inl, tmp)
            tmp = nxt
        unlink(opener.inl)
        self.process_emphasis(opener.position)
        self.pop_bracket()
        if not is_image:
            self.no_link_openers = True
        return None


def scan_link_title(s, start):
    """Returns the end of the longest link title starting at s[start], or start if none.

    A title is delimited by "...", '...' or (...); inside, the delimiter
    characters (and for parentheses the opener too) may only appear preceded
    by a backslash. The longest possible match is taken, as re2c does.
    """
    opener = peek(s, start)
    if opener == '"' or opener == "'":
        closer, forbidden = opener, ''
    elif opener == '(':
        closer, forbidden = ')', '('
    else:
        return start
    end = start
    i = start + 1
    n = len(s)
    while i < n:
        ch = s[i]
        escaped = s[i - 1] == '\\'
        if ch == closer:
            end = i + 1
            if not escaped:
                break
        elif ch == forbidden and not escaped:
            break
        i += 1
    return end


def scan_link_url(s, offset):
    """Returns (length, destination_text) for a link destination at s[offset:], or None."""
    n = len(s)
    i = offset
    if i < n and s[i] == '<':
        i += 1
        while i < n:
            ch = s[i]
            if ch == '>':
                i += 1
                break
            if ch == '\\':
                i += 2
            elif ch == '\n' or ch == '<':
                return None
            else:
                i += 1
        if i >= n:
            return None
        return i - offset, s[offset + 1:i - 1]
    nb_p = 0
    while i < n:
        ch = s[i]
        if ch == '\\' and i + 1 < n and s[i + 1] in ASCII_PUNCT:
            i += 2
        elif ch == '(':
            nb_p += 1
            i += 1
            if nb_p > 32:
                return None
        elif ch == ')':
            if nb_p == 0:
                break
            nb_p -= 1
            i += 1
        elif ch in ASCII_SPACE:
            if i == offset:
                return None
            break
        else:
            i += 1
    if i >= n or nb_p != 0:
        return None
    return i - offset, s[offset:i]


def normalize_code(text):
    """Code span content: line endings become spaces, then one leading and
    one trailing space are stripped when both exist and the content is not
    all spaces."""
    text = text.replace('\r\n', '\n').replace('\r', ' ').replace('\n', ' ')
    if text and text[0] == ' ' and text[-1] == ' ' and text.strip(' ') != '':
        text = text[1:-1]
    return text


def parse_inlines(root):
    stack = [root]
    while stack:
        node = stack.pop()
        if node.type in (PARAGRAPH, HEADING):
            InlineParser(node.literal).parse(node)
            continue
        child = node.first_child
        while child is not None:
            stack.append(child)
            child = child.next


# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------
HREF_SAFE = set('!#$%()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~')
DANGEROUS_RE = re.compile(r'(?i)javascript:|vbscript:|file:|data:')
SAFE_DATA_RE = re.compile(r'(?i)data:image/(?:png|gif|jpeg|webp)')


def escape_html(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def escape_href(url):
    out = []
    for b in url.encode('utf-8'):
        ch = chr(b)
        if b < 128 and ch in HREF_SAFE:
            out.append(ch)
        elif ch == '&':
            out.append('&amp;')
        elif ch == "'":
            out.append('&#x27;')
        else:
            out.append('%%%02X' % b)
    return ''.join(out)


def render_url(url):
    if DANGEROUS_RE.match(url) and not SAFE_DATA_RE.match(url):
        return ''
    return escape_href(url)


class Renderer:
    def __init__(self):
        self.out = []
        self.plain = None

    def put(self, text):
        if text:
            self.out.append(text)

    def cr(self):
        if self.out and not self.out[-1].endswith('\n'):
            self.out.append('\n')

    def render(self, root):
        # Iterative pre/post-order walk: (node, entering) pairs.
        stack = [(root, False), (root, True)]
        while stack:
            node, entering = stack.pop()
            self.visit(node, entering)
            if entering:
                child = node.last_child
                while child is not None:
                    stack.append((child, False))
                    stack.append((child, True))
                    child = child.prev
        return ''.join(self.out)

    def visit(self, node, entering):
        out = self
        t = node.type
        if self.plain is node:
            self.plain = None
        if self.plain is not None:
            if entering:
                if t in (TEXT, CODE):
                    out.put(escape_html(node.literal))
                elif t in (LINEBREAK, SOFTBREAK):
                    out.put(' ')
            return
        if t == DOCUMENT:
            return
        if t == BLOCK_QUOTE:
            self.cr()
            out.put('<blockquote>\n' if entering else '</blockquote>\n')
        elif t == LIST:
            if entering:
                self.cr()
                if node.list_type == BULLET:
                    out.put('<ul>\n')
                elif node.start == 1:
                    out.put('<ol>\n')
                else:
                    out.put('<ol start="%d">\n' % node.start)
            else:
                out.put('</ul>\n' if node.list_type == BULLET else '</ol>\n')
        elif t == ITEM:
            if entering:
                self.cr()
                out.put('<li>')
            else:
                out.put('</li>\n')
        elif t == HEADING:
            if entering:
                self.cr()
                out.put('<h%d>' % node.level)
            else:
                out.put('</h%d>\n' % node.level)
        elif t == CODE_BLOCK:
            if entering:
                self.cr()
                if not node.info:
                    out.put('<pre><code>')
                else:
                    info = node.info
                    first = 0
                    while first < len(info) and info[first] not in ASCII_SPACE:
                        first += 1
                    out.put('<pre><code class="')
                    if not info.startswith('language-'):
                        out.put('language-')
                    out.put(escape_html(info[:first]))
                    out.put('">')
                out.put(escape_html(node.literal))
                out.put('</code></pre>\n')
        elif t == THEMATIC_BREAK:
            if entering:
                self.cr()
                out.put('<hr />\n')
        elif t == PARAGRAPH:
            parent = node.parent
            grandparent = parent.parent if parent is not None else None
            tight = grandparent is not None and grandparent.type == LIST and grandparent.tight
            if not tight:
                if entering:
                    self.cr()
                    out.put('<p>')
                else:
                    out.put('</p>\n')
        elif t == TEXT:
            if entering:
                out.put(escape_html(node.literal))
        elif t == LINEBREAK:
            if entering:
                out.put('<br />\n')
        elif t == SOFTBREAK:
            if entering:
                out.put('\n')
        elif t == CODE:
            if entering:
                out.put('<code>' + escape_html(node.literal) + '</code>')
        elif t == STRONG:
            out.put('<strong>' if entering else '</strong>')
        elif t == EMPH:
            out.put('<em>' if entering else '</em>')
        elif t == LINK:
            if entering:
                out.put('<a href="' + render_url(node.url))
                if node.title is not None:
                    out.put('" title="' + escape_html(node.title))
                out.put('">')
            else:
                out.put('</a>')
        elif t == IMAGE:
            if entering:
                out.put('<img src="' + render_url(node.url) + '" alt="')
                self.plain = node
            else:
                if node.title is not None:
                    out.put('" title="' + escape_html(node.title))
                out.put('" />')


def convert(text):
    parser = BlockParser()
    lines = text.split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    for line in lines:
        parser.process_line(line)
    root = parser.finish()
    parse_inlines(root)
    return Renderer().render(root)


def main():
    data = sys.stdin.buffer.read()
    text = data.decode('utf-8')
    sys.stdout.buffer.write(convert(text).encode('utf-8'))


if __name__ == '__main__':
    sys.setrecursionlimit(10000)
    main()
