#!/usr/bin/env python3
"""Reference implementation for the `template` problem.

Reads a JSON context, a `--` line and a sequence of `=== name` templates
from stdin, renders the first template per SPEC.md and prints the result
(or `error: <kind>`). Hand-written lexer, recursive-descent parser and
tree-walking renderer; no template library is used.
"""
import json
import re
import sys
import threading

WS = ' \t\n\r\f\v'
FILTERS = {'upper', 'lower', 'length', 'join', 'default', 'escape', 'reverse',
           'sort', 'first', 'last', 'trim', 'replace', 'int'}
KEYWORDS = {'and', 'or', 'not', 'in', 'is', 'true', 'false', 'none'}


class TemplateError(Exception):
    def __init__(self, kind):
        super().__init__(kind)
        self.kind = kind


def syntax():
    return TemplateError('syntax')


class Undefined:
    """The undefined value; a single instance is shared."""
    __slots__ = ()


UNDEF = Undefined()


# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------
NAME_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
FLOAT_RE = re.compile(r'[0-9]+\.[0-9]+')
INT_RE = re.compile(r'[0-9]+')
OPERATORS = ['**', '//', '==', '!=', '<=', '>=', '~', '+', '-', '*', '/', '%', '<', '>',
             '(', ')', '[', ']', ',', '|', '.', '=']
STRING_ESCAPES = {'\\': '\\', '"': '"', "'": "'", 'n': '\n', 't': '\t'}


def lex_tag(src, pos, closer):
    """Tokenizes a tag body starting at `pos`; returns (tokens, end_pos, strip_after).

    Tokens are (kind, value) with kinds 'name', 'int', 'float', 'string', 'op'.
    """
    tokens = []
    n = len(src)
    while True:
        while pos < n and src[pos] in WS:
            pos += 1
        if pos >= n:
            raise syntax()
        if src.startswith('-' + closer, pos):
            return tokens, pos + 1 + len(closer), True
        if src.startswith(closer, pos):
            return tokens, pos + len(closer), False
        ch = src[pos]
        if ch in '"\'':
            quote = ch
            pos += 1
            buf = []
            while True:
                if pos >= n:
                    raise syntax()
                c = src[pos]
                if c == quote:
                    pos += 1
                    break
                if c == '\\':
                    if pos + 1 >= n or src[pos + 1] not in STRING_ESCAPES:
                        raise syntax()
                    buf.append(STRING_ESCAPES[src[pos + 1]])
                    pos += 2
                else:
                    buf.append(c)
                    pos += 1
            tokens.append(('string', ''.join(buf)))
            continue
        m = FLOAT_RE.match(src, pos)
        if m:
            tokens.append(('float', float(m.group())))
            pos = m.end()
            continue
        m = INT_RE.match(src, pos)
        if m:
            tokens.append(('int', int(m.group())))
            pos = m.end()
            continue
        m = NAME_RE.match(src, pos)
        if m:
            tokens.append(('name', m.group()))
            pos = m.end()
            continue
        for op in OPERATORS:
            if src.startswith(op, pos):
                tokens.append(('op', op))
                pos += len(op)
                break
        else:
            raise syntax()


def lex_template(src):
    """Splits template source into ('text', s), ('var', tokens), ('tag', tokens) items."""
    items = []
    pos = 0
    n = len(src)
    pending_lstrip = False  # a preceding `-%}` strips the whitespace that starts this text
    while pos < n:
        i = src.find('{', pos)
        while i != -1 and i + 1 < n and src[i + 1] not in '{%#':
            i = src.find('{', i + 1)
        if i == -1 or i + 1 >= n:
            text = src[pos:]
            pos = n
            opener = None
        else:
            text = src[pos:i]
            opener = src[i:i + 2]
            pos = i + 2
        if pending_lstrip:
            text = text.lstrip(WS)
            pending_lstrip = False
        if opener is not None and pos < n and src[pos] == '-':
            text = text.rstrip(WS)
            pos += 1
        if text:
            items.append(('text', text))
        if opener is None:
            break
        if opener == '{#':
            end = src.find('#}', pos)
            if end == -1:
                raise syntax()
            if end > pos and src[end - 1] == '-':
                pending_lstrip = True
            pos = end + 2
        elif opener == '{{':
            tokens, pos, pending_lstrip = lex_tag(src, pos, '}}')
            items.append(('var', tokens))
        else:
            tokens, pos, pending_lstrip = lex_tag(src, pos, '%}')
            items.append(('tag', tokens))
    return items


# ---------------------------------------------------------------------------
# Parser: expressions are tuples ('kind', ...); statements are tuples too.
# ---------------------------------------------------------------------------
class ExprParser:
    def __init__(self, tokens):
        self.toks = tokens
        self.i = 0

    def peek(self, kind=None, value=None):
        if self.i >= len(self.toks):
            return False
        k, v = self.toks[self.i]
        return (kind is None or k == kind) and (value is None or v == value)

    def peek_name(self, value):
        return self.peek('name', value)

    def next(self):
        if self.i >= len(self.toks):
            raise syntax()
        t = self.toks[self.i]
        self.i += 1
        return t

    def expect(self, kind, value=None):
        if not self.peek(kind, value):
            raise syntax()
        return self.next()[1]

    def at_end(self):
        return self.i >= len(self.toks)

    def parse_expression(self):
        return self.parse_or()

    def parse_or(self):
        node = self.parse_and()
        while self.peek_name('or'):
            self.next()
            node = ('or', node, self.parse_and())
        return node

    def parse_and(self):
        node = self.parse_not()
        while self.peek_name('and'):
            self.next()
            node = ('and', node, self.parse_not())
        return node

    def parse_not(self):
        if self.peek_name('not'):
            self.next()
            return ('not', self.parse_not())
        return self.parse_compare()

    def parse_compare(self):
        left = self.parse_additive()
        ops = []
        while True:
            if self.peek('op') and self.toks[self.i][1] in ('==', '!=', '<', '<=', '>', '>='):
                op = self.next()[1]
            elif self.peek_name('in'):
                self.next()
                op = 'in'
            elif self.peek_name('not') and self.i + 1 < len(self.toks) and self.toks[self.i + 1] == ('name', 'in'):
                self.next()
                self.next()
                op = 'not in'
            else:
                break
            ops.append((op, self.parse_additive()))
        if not ops:
            return left
        return ('compare', left, ops)

    def parse_additive(self):
        node = self.parse_concat()
        while self.peek('op', '+') or self.peek('op', '-'):
            op = self.next()[1]
            node = ('binop', op, node, self.parse_concat())
        return node

    def parse_concat(self):
        node = self.parse_term()
        while self.peek('op', '~'):
            self.next()
            node = ('binop', '~', node, self.parse_term())
        return node

    def parse_term(self):
        node = self.parse_power()
        while self.peek('op') and self.toks[self.i][1] in ('*', '/', '//', '%'):
            op = self.next()[1]
            node = ('binop', op, node, self.parse_power())
        return node

    def parse_power(self):
        node = self.parse_filtered()
        while self.peek('op', '**'):
            self.next()
            node = ('binop', '**', node, self.parse_filtered())
        return node

    def parse_filtered(self):
        node = self.parse_unary()
        while True:
            if self.peek('op', '|'):
                self.next()
                name = self.expect('name')
                args = []
                if self.peek('op', '('):
                    self.next()
                    args = self.parse_args(allow_keywords=False)[0]
                node = ('filter', name, node, args)
            elif self.peek_name('is'):
                self.next()
                negate = False
                if self.peek_name('not'):
                    self.next()
                    negate = True
                if not self.peek_name('defined'):
                    raise syntax()
                self.next()
                node = ('defined', node, negate)
            else:
                return node

    def parse_unary(self):
        if self.peek('op', '-'):
            self.next()
            return ('neg', self.parse_unary())
        return self.parse_postfix(self.parse_primary())

    def parse_postfix(self, node):
        while True:
            if self.peek('op', '.'):
                self.next()
                name = self.expect('name')
                node = ('getattr', node, name)
            elif self.peek('op', '['):
                self.next()
                sub = self.parse_expression()
                self.expect('op', ']')
                node = ('getitem', node, sub)
            elif self.peek('op', '('):
                self.next()
                args, kwargs = self.parse_args(allow_keywords=True)
                node = ('call', node, args, kwargs)
            else:
                return node

    def parse_args(self, allow_keywords):
        """Parses arguments after an opening parenthesis up to and including `)`."""
        args = []
        kwargs = []
        while not self.peek('op', ')'):
            if allow_keywords and self.peek('name') and self.i + 1 < len(self.toks) \
                    and self.toks[self.i + 1] == ('op', '=') and self.toks[self.i][1] not in KEYWORDS:
                name = self.next()[1]
                self.next()
                if any(k == name for k, _ in kwargs):
                    raise syntax()
                kwargs.append((name, self.parse_expression()))
            else:
                if kwargs:
                    raise syntax()
                args.append(self.parse_expression())
            if self.peek('op', ','):
                self.next()
                if self.peek('op', ')'):
                    raise syntax()
            elif not self.peek('op', ')'):
                raise syntax()
        self.next()
        return args, kwargs

    def parse_primary(self):
        k, v = self.next()
        if k == 'int' or k == 'float' or k == 'string':
            return ('const', v)
        if k == 'name':
            if v == 'true':
                return ('const', True)
            if v == 'false':
                return ('const', False)
            if v == 'none':
                return ('const', None)
            if v in KEYWORDS:
                raise syntax()
            return ('name', v)
        if k == 'op' and v == '(':
            node = self.parse_expression()
            self.expect('op', ')')
            return node
        if k == 'op' and v == '[':
            items = []
            while not self.peek('op', ']'):
                items.append(self.parse_expression())
                if self.peek('op', ','):
                    self.next()
                    if self.peek('op', ']'):
                        raise syntax()
                elif not self.peek('op', ']'):
                    raise syntax()
            self.next()
            return ('list', items)
        raise syntax()


def parse_expr_tokens(tokens):
    p = ExprParser(tokens)
    node = p.parse_expression()
    if not p.at_end():
        raise syntax()
    return node


class Template:
    def __init__(self, body, blocks, filters):
        self.body = body
        self.blocks = blocks      # name -> body node list
        self.filters = filters    # every filter name used anywhere in the template


class TemplateParser:
    def __init__(self, src):
        self.items = lex_template(src)
        self.i = 0
        self.blocks = {}
        self.filters = set()
        self.extends_seen = False

    def parse(self):
        body = self.parse_body(end_tags=None, top=True)
        return Template(body, self.blocks, self.filters)

    def collect_filters(self, node):
        if isinstance(node, tuple):
            if node and node[0] == 'filter':
                self.filters.add(node[1])
            for child in node:
                self.collect_filters(child)
        elif isinstance(node, list):
            for child in node:
                self.collect_filters(child)

    def expr(self, tokens):
        node = parse_expr_tokens(tokens)
        self.collect_filters(node)
        return node

    def tag_keyword(self):
        """Returns the keyword of the tag at the current position, or None if not a tag."""
        if self.i >= len(self.items):
            return None
        kind, tokens = self.items[self.i]
        if kind != 'tag':
            return None
        if not tokens or tokens[0][0] != 'name':
            raise syntax()
        return tokens[0][1]

    def parse_body(self, end_tags, top):
        """Parses statements until a tag in `end_tags` (left unconsumed) or end of input."""
        nodes = []
        while self.i < len(self.items):
            kind, payload = self.items[self.i]
            if kind == 'text':
                nodes.append(('text', payload))
                self.i += 1
                continue
            if kind == 'var':
                nodes.append(('output', self.expr(payload)))
                self.i += 1
                continue
            kw = self.tag_keyword()
            if end_tags is not None and kw in end_tags:
                return nodes
            self.i += 1
            rest = payload[1:]
            if kw == 'if':
                nodes.append(self.parse_if(rest))
            elif kw == 'for':
                nodes.append(self.parse_for(rest))
            elif kw == 'set':
                p = ExprParser(rest)
                name = p.expect('name')
                if name in KEYWORDS:
                    raise syntax()
                p.expect('op', '=')
                value = p.parse_expression()
                if not p.at_end():
                    raise syntax()
                self.collect_filters(value)
                nodes.append(('set', name, value))
            elif kw == 'macro':
                nodes.append(self.parse_macro(rest))
            elif kw == 'include':
                nodes.append(('include', self.expr(rest)))
            elif kw == 'extends':
                if not top or self.extends_seen:
                    raise syntax()
                self.extends_seen = True
                nodes.append(('extends', self.expr(rest)))
            elif kw == 'block':
                nodes.append(self.parse_block(rest))
            else:
                raise syntax()
        if end_tags is not None:
            raise syntax()
        return nodes

    def take_tag(self, expected):
        """Consumes the tag at the current position, which must have keyword `expected`."""
        kw = self.tag_keyword()
        if kw != expected:
            raise syntax()
        self.i += 1
        return self.items[self.i - 1][1][1:]

    def parse_if(self, rest):
        branches = []
        cond = self.expr(rest)
        body = self.parse_body(('elif', 'else', 'endif'), False)
        branches.append((cond, body))
        else_body = None
        while True:
            kw = self.tag_keyword()
            if kw == 'elif':
                cond = self.expr(self.take_tag('elif'))
                branches.append((cond, self.parse_body(('elif', 'else', 'endif'), False)))
            elif kw == 'else':
                if self.take_tag('else'):
                    raise syntax()
                else_body = self.parse_body(('endif',), False)
                if self.take_tag('endif'):
                    raise syntax()
                break
            else:
                if self.take_tag('endif'):
                    raise syntax()
                break
        return ('if', branches, else_body)

    def parse_for(self, rest):
        p = ExprParser(rest)
        var = p.expect('name')
        if var in KEYWORDS:
            raise syntax()
        if not p.peek_name('in'):
            raise syntax()
        p.next()
        seq = p.parse_expression()
        if not p.at_end():
            raise syntax()
        self.collect_filters(seq)
        body = self.parse_body(('else', 'endfor'), False)
        else_body = None
        if self.tag_keyword() == 'else':
            if self.take_tag('else'):
                raise syntax()
            else_body = self.parse_body(('endfor',), False)
        if self.take_tag('endfor'):
            raise syntax()
        return ('for', var, seq, body, else_body)

    def parse_macro(self, rest):
        p = ExprParser(rest)
        name = p.expect('name')
        if name in KEYWORDS:
            raise syntax()
        p.expect('op', '(')
        params = []
        seen = set()
        while not p.peek('op', ')'):
            pname = p.expect('name')
            if pname in KEYWORDS or pname in seen:
                raise syntax()
            seen.add(pname)
            default = None
            if p.peek('op', '='):
                p.next()
                default = p.parse_expression()
                self.collect_filters(default)
            params.append((pname, default))
            if p.peek('op', ','):
                p.next()
                if p.peek('op', ')'):
                    raise syntax()
            elif not p.peek('op', ')'):
                raise syntax()
        p.next()
        if not p.at_end():
            raise syntax()
        body = self.parse_body(('endmacro',), False)
        if self.take_tag('endmacro'):
            raise syntax()
        return ('macro', name, params, body)

    def parse_block(self, rest):
        p = ExprParser(rest)
        name = p.expect('name')
        if name in KEYWORDS or not p.at_end():
            raise syntax()
        if name in self.blocks:
            raise syntax()
        self.blocks[name] = None  # reserved so a nested duplicate is caught
        body = self.parse_body(('endblock',), False)
        tail = self.take_tag('endblock')
        if tail and tail != [('name', name)]:
            raise syntax()
        self.blocks[name] = body
        return ('block', name)


# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------
class Macro:
    __slots__ = ('name', 'params', 'body', 'scope', 'render')

    def __init__(self, name, params, body, scope, render):
        self.name = name
        self.params = params
        self.body = body
        self.scope = scope
        self.render = render


class SuperRef:
    __slots__ = ('render', 'name', 'index')

    def __init__(self, render, name, index):
        self.render = render
        self.name = name
        self.index = index


class Scope:
    __slots__ = ('vars', 'parent')

    def __init__(self, parent):
        self.vars = {}
        self.parent = parent

    def lookup(self, name):
        s = self
        while s is not None:
            if name in s.vars:
                return s.vars[name]
            s = s.parent
        return UNDEF


def is_number(v):
    return isinstance(v, (int, float))


def is_int(v):
    return isinstance(v, int)  # bool included


def truthy(v):
    if v is UNDEF:
        raise TemplateError('undefined')
    if isinstance(v, (Macro, SuperRef)):
        return True
    return bool(v)


def repr_string(s):
    quote = "'"
    if "'" in s and '"' not in s:
        quote = '"'
    out = [quote]
    for ch in s:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\r':
            out.append('\\r')
        elif ch == '\t':
            out.append('\\t')
        elif ch == quote:
            out.append('\\' + ch)
        else:
            out.append(ch)
    out.append(quote)
    return ''.join(out)


def to_repr(v):
    if isinstance(v, str):
        return repr_string(v)
    if isinstance(v, list):
        return '[' + ', '.join(to_repr(x) for x in v) + ']'
    if isinstance(v, dict):
        return '{' + ', '.join(repr_string(k) + ': ' + to_repr(x) for k, x in v.items()) + '}'
    return to_str(v)


def to_str(v):
    if v is UNDEF:
        raise TemplateError('undefined')
    if v is None:
        return 'None'
    if v is True:
        return 'True'
    if v is False:
        return 'False'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    if isinstance(v, str):
        return v
    if isinstance(v, (list, dict)):
        return to_repr(v)
    raise TemplateError('type')


def equal(a, b):
    if a is UNDEF or b is UNDEF:
        raise TemplateError('undefined')
    if is_number(a) and is_number(b):
        return a == b
    if isinstance(a, str) and isinstance(b, str):
        return a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(equal(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(equal(a[k], b[k]) for k in a)
    if a is None and b is None:
        return True
    return False


def order(op, a, b):
    if a is UNDEF or b is UNDEF:
        raise TemplateError('undefined')
    if (is_number(a) and is_number(b)) or (isinstance(a, str) and isinstance(b, str)):
        if op == '<':
            return a < b
        if op == '<=':
            return a <= b
        if op == '>':
            return a > b
        return a >= b
    raise TemplateError('type')


def contains(item, container):
    if item is UNDEF or container is UNDEF:
        raise TemplateError('undefined')
    if isinstance(container, str):
        if not isinstance(item, str):
            raise TemplateError('type')
        return item in container
    if isinstance(container, dict):
        return isinstance(item, str) and item in container
    if isinstance(container, list):
        return any(equal(item, x) for x in container)
    raise TemplateError('type')


def as_sequence(v):
    """The elements of a list, the keys of a dict or the characters of a string."""
    if v is UNDEF:
        raise TemplateError('undefined')
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        return list(v.keys())
    if isinstance(v, str):
        return list(v)
    raise TemplateError('type')


def arith(op, a, b):
    if a is UNDEF or b is UNDEF:
        raise TemplateError('undefined')
    if op == '~':
        return to_str(a) + to_str(b)
    if is_number(a) and is_number(b):
        try:
            if op == '+':
                return a + b
            if op == '-':
                return a - b
            if op == '*':
                return a * b
            if op == '/':
                return a / b
            if op == '//':
                return a // b
            if op == '%':
                return a % b
            if op == '**':
                r = a ** b
                if isinstance(r, complex):
                    raise TemplateError('type')
                return r
        except (ZeroDivisionError, OverflowError):
            raise TemplateError('type')
    if op == '+':
        if isinstance(a, str) and isinstance(b, str):
            return a + b
        if isinstance(a, list) and isinstance(b, list):
            return a + b
    if op == '*':
        if isinstance(a, str) and is_int(b):
            return a * int(b)
        if is_int(a) and isinstance(b, str):
            return b * int(a)
    raise TemplateError('type')


def get_attr(obj, key):
    """Attribute/subscript access: dict key, list index or string index; else undefined."""
    if obj is UNDEF:
        raise TemplateError('undefined')
    if key is UNDEF:
        raise TemplateError('undefined')
    if isinstance(obj, dict):
        if isinstance(key, str) and key in obj:
            return obj[key]
        return UNDEF
    if isinstance(obj, (list, str)) and is_int(key):
        i = int(key)
        if -len(obj) <= i < len(obj):
            return obj[i]
        return UNDEF
    return UNDEF


def ascii_lower(s):
    return ''.join(chr(ord(c) + 32) if 'A' <= c <= 'Z' else c for c in s)


def ascii_upper(s):
    return ''.join(chr(ord(c) - 32) if 'a' <= c <= 'z' else c for c in s)


INT_STR_RE = re.compile(r'[+-]?[0-9]+')
FLOAT_STR_RE = re.compile(r'[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?')


def filter_int(v):
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v)
    if isinstance(v, str):
        s = v.strip(WS)
        if INT_STR_RE.fullmatch(s):
            return int(s)
        if FLOAT_STR_RE.fullmatch(s):
            return int(float(s))
        return 0
    return 0


def html_escape(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;') \
            .replace('"', '&#34;').replace("'", '&#39;')


def apply_filter(name, v, args):
    if name not in FILTERS:
        raise TemplateError('filter')
    nargs = len(args)
    if name == 'default':
        if nargs > 1:
            raise TemplateError('type')
        if v is UNDEF:
            return args[0] if args else ''
        return v
    if v is UNDEF:
        raise TemplateError('undefined')
    if name == 'join':
        if nargs > 1:
            raise TemplateError('type')
        sep = to_str(args[0]) if args else ''
        return sep.join(to_str(x) for x in as_sequence(v))
    if name == 'replace':
        if nargs != 2:
            raise TemplateError('type')
        return to_str(v).replace(to_str(args[0]), to_str(args[1]))
    if nargs != 0:
        raise TemplateError('type')
    if name == 'upper':
        return ascii_upper(to_str(v))
    if name == 'lower':
        return ascii_lower(to_str(v))
    if name == 'trim':
        return to_str(v).strip(WS)
    if name == 'escape':
        return html_escape(to_str(v))
    if name == 'int':
        return filter_int(v)
    if name == 'length':
        if isinstance(v, (str, list, dict)):
            return len(v)
        raise TemplateError('type')
    if name == 'reverse':
        if isinstance(v, str):
            return v[::-1]
        return as_sequence(v)[::-1]
    if name == 'first' or name == 'last':
        seq = as_sequence(v)
        if not seq:
            return UNDEF
        return seq[0] if name == 'first' else seq[-1]
    if name == 'sort':
        seq = as_sequence(v)
        if all(is_number(x) for x in seq):
            return sorted(seq)
        if all(isinstance(x, str) for x in seq):
            return sorted(seq, key=ascii_lower)
        raise TemplateError('type')
    raise TemplateError('filter')


def builtin_range(args):
    if not 1 <= len(args) <= 3:
        raise TemplateError('type')
    for a in args:
        if a is UNDEF:
            raise TemplateError('undefined')
        if not is_int(a):
            raise TemplateError('type')
    args = [int(a) for a in args]
    if len(args) == 3 and args[2] == 0:
        raise TemplateError('type')
    return list(range(*args))


# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------
class Render:
    """State of one top-level rendering of a template (the main one or an include)."""

    def __init__(self, engine, scope):
        self.engine = engine
        self.scope = scope          # the template scope shared by the inheritance chain
        self.blocks = {}            # name -> list of bodies, most derived first
        self.extends_name = None
        self.suppress = False


class Engine:
    def __init__(self, templates, context):
        self.sources = templates
        self.parsed = {}
        self.context = context

    def load(self, name):
        if name is UNDEF:
            raise TemplateError('undefined')
        if not isinstance(name, str):
            raise TemplateError('type')
        if name in self.parsed:
            return self.parsed[name]
        if name not in self.sources:
            raise TemplateError('template')
        tpl = TemplateParser(self.sources[name]).parse()
        for f in tpl.filters:
            if f not in FILTERS:
                raise TemplateError('filter')
        self.parsed[name] = tpl
        return tpl

    def render_template(self, name, parent_scope, out):
        tpl = self.load(name)
        render = Render(self, Scope(parent_scope))
        while True:
            for bname, body in tpl.blocks.items():
                render.blocks.setdefault(bname, []).append(body)
            render.suppress = False
            render.extends_name = None
            self.exec_body(tpl.body, render.scope, render, out)
            if render.extends_name is None:
                return
            tpl = self.load(render.extends_name)

    def render_block(self, render, name, index, out):
        chain = render.blocks.get(name)
        if chain is None or index >= len(chain):
            raise TemplateError('undefined')
        scope = Scope(render.scope)
        scope.vars['super'] = SuperRef(render, name, index + 1)
        saved = render.suppress
        render.suppress = False
        self.exec_body(chain[index], scope, render, out)
        render.suppress = saved

    def call_macro(self, macro, args, kwargs):
        scope = Scope(macro.scope)
        names = [p for p, _ in macro.params]
        if len(args) > len(names):
            raise TemplateError('type')
        for pname, value in zip(names, args):
            scope.vars[pname] = value
        for k, value in kwargs:
            if k not in names or k in scope.vars:
                raise TemplateError('type')
            scope.vars[k] = value
        for pname, default in macro.params:
            if pname not in scope.vars:
                scope.vars[pname] = self.eval(default, scope, None) if default is not None else UNDEF
        out = []
        # A macro renders into its own buffer, so the output suppression that
        # follows an `extends` tag must not apply while its body runs.
        render = macro.render
        saved = render.suppress
        render.suppress = False
        try:
            self.exec_body(macro.body, scope, render, out)
        finally:
            render.suppress = saved
        return ''.join(out)

    def exec_body(self, nodes, scope, render, out):
        for node in nodes:
            kind = node[0]
            if kind == 'text':
                if not render.suppress:
                    out.append(node[1])
            elif kind == 'output':
                if not render.suppress:
                    out.append(to_str(self.eval(node[1], scope, render)))
            elif kind == 'if':
                for cond, body in node[1]:
                    if truthy(self.eval(cond, scope, render)):
                        self.exec_body(body, scope, render, out)
                        break
                else:
                    if node[2] is not None:
                        self.exec_body(node[2], scope, render, out)
            elif kind == 'for':
                _, var, seq_expr, body, else_body = node
                seq = as_sequence(self.eval(seq_expr, scope, render))
                if not seq:
                    if else_body is not None:
                        self.exec_body(else_body, scope, render, out)
                    continue
                n = len(seq)
                for i, item in enumerate(seq):
                    inner = Scope(scope)
                    inner.vars[var] = item
                    inner.vars['loop'] = {'index': i + 1, 'index0': i, 'first': i == 0,
                                          'last': i == n - 1, 'length': n}
                    self.exec_body(body, inner, render, out)
            elif kind == 'set':
                scope.vars[node[1]] = self.eval(node[2], scope, render)
            elif kind == 'macro':
                scope.vars[node[1]] = Macro(node[1], node[2], node[3], scope, render)
            elif kind == 'include':
                name = self.eval(node[1], scope, render)
                self.render_template(name, scope, [] if render.suppress else out)
            elif kind == 'extends':
                name = self.eval(node[1], scope, render)
                self.load(name)
                render.extends_name = name
                render.suppress = True
            elif kind == 'block':
                if not render.suppress:
                    self.render_block(render, node[1], 0, out)
            else:
                raise AssertionError(kind)

    def eval(self, node, scope, render):
        kind = node[0]
        if kind == 'const':
            return node[1]
        if kind == 'name':
            name = node[1]
            v = scope.lookup(name)
            if v is UNDEF and name == 'range':
                return ('builtin', 'range')
            return v
        if kind == 'list':
            return [self.eval(x, scope, render) for x in node[1]]
        if kind == 'getattr':
            return get_attr(self.eval(node[1], scope, render), node[2])
        if kind == 'getitem':
            obj = self.eval(node[1], scope, render)
            return get_attr(obj, self.eval(node[2], scope, render))
        if kind == 'call':
            fn = self.eval(node[1], scope, render)
            args = [self.eval(a, scope, render) for a in node[2]]
            kwargs = [(k, self.eval(a, scope, render)) for k, a in node[3]]
            if fn is UNDEF:
                raise TemplateError('undefined')
            if isinstance(fn, Macro):
                return self.call_macro(fn, args, kwargs)
            if isinstance(fn, SuperRef):
                if args or kwargs:
                    raise TemplateError('type')
                out = []
                self.render_block(fn.render, fn.name, fn.index, out)
                return ''.join(out)
            if isinstance(fn, tuple) and fn[0] == 'builtin':
                if kwargs:
                    raise TemplateError('type')
                return builtin_range(args)
            raise TemplateError('type')
        if kind == 'filter':
            v = self.eval(node[2], scope, render)
            args = [self.eval(a, scope, render) for a in node[3]]
            return apply_filter(node[1], v, args)
        if kind == 'defined':
            v = self.eval(node[1], scope, render)
            return (v is UNDEF) if node[2] else (v is not UNDEF)
        if kind == 'neg':
            v = self.eval(node[1], scope, render)
            if v is UNDEF:
                raise TemplateError('undefined')
            if is_number(v):
                return -v
            raise TemplateError('type')
        if kind == 'not':
            return not truthy(self.eval(node[1], scope, render))
        if kind == 'and':
            left = self.eval(node[1], scope, render)
            if not truthy(left):
                return left
            return self.eval(node[2], scope, render)
        if kind == 'or':
            left = self.eval(node[1], scope, render)
            if truthy(left):
                return left
            return self.eval(node[2], scope, render)
        if kind == 'binop':
            return arith(node[1], self.eval(node[2], scope, render), self.eval(node[3], scope, render))
        if kind == 'compare':
            left = self.eval(node[1], scope, render)
            for op, rhs in node[2]:
                right = self.eval(rhs, scope, render)
                if op == '==':
                    ok = equal(left, right)
                elif op == '!=':
                    ok = not equal(left, right)
                elif op == 'in':
                    ok = contains(left, right)
                elif op == 'not in':
                    ok = not contains(left, right)
                else:
                    ok = order(op, left, right)
                if not ok:
                    return False
                left = right
            return True
        raise AssertionError(kind)


# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------
def split_input(data):
    lines = data.split('\n')
    if data.endswith('\n'):
        lines.pop()
    sep = lines.index('--')
    context = json.loads('\n'.join(lines[:sep]))
    templates = {}
    order = []
    name = None
    body = []
    for line in lines[sep + 1:]:
        if line.startswith('=== '):
            if name is not None:
                templates[name] = '\n'.join(body)
            name = line[4:]
            order.append(name)
            body = []
        elif name is not None:
            body.append(line)
    if name is not None:
        templates[name] = '\n'.join(body)
    return context, templates, order


def main():
    data = sys.stdin.buffer.read().decode('utf-8')
    context, templates, order = split_input(data)
    engine = Engine(templates, context)
    root = Scope(None)
    root.vars.update(context)
    out = []
    try:
        engine.render_template(order[0], root, out)
        result = ''.join(out)
    except TemplateError as e:
        result = 'error: ' + e.kind
    sys.stdout.write(result + '\n')


if __name__ == '__main__':
    sys.setrecursionlimit(1000000)
    threading.stack_size(512 * 1024 * 1024)
    t = threading.Thread(target=main)
    t.start()
    t.join()
