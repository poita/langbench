#!/usr/bin/env python3
"""Reference interpreter for the `jq` problem.

Reads a jq-subset filter (first line of stdin) and one JSON document (the
rest), evaluates the filter and prints every result as one line of compact
JSON, or the word "error" when evaluation raises an uncaught error.
The JSON document is parsed with the standard json module (incidental to
the problem); the filter parser and evaluator are hand-written.
"""
import json
import math
import re
import sys
from functools import cmp_to_key


class JqError(Exception):
    """A runtime error of the filter (catchable by `?`)."""


class ParseError(Exception):
    pass


# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------
TOKEN_RE = re.compile(r'''
    (?P<ws>[ \t\r\n]+)
  | (?P<num>[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)
  | (?P<str>"(?:[^"\\]|\\.)*")
  | (?P<field>\.[A-Za-z_][A-Za-z0-9_]*)
  | (?P<var>\$[A-Za-z_][A-Za-z0-9_]*)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>==|!=|<=|>=|[-+*/%<>|,:;()\[\]{}?.])
''', re.X)
KEYWORDS = {'if', 'then', 'elif', 'else', 'end', 'as', 'reduce', 'and', 'or',
            'true', 'false', 'null'}


def tokenize(src):
    toks = []
    pos = 0
    while pos < len(src):
        m = TOKEN_RE.match(src, pos)
        if not m:
            raise ParseError('bad character at %d' % pos)
        pos = m.end()
        kind = m.lastgroup
        text = m.group(kind)
        if kind == 'ws':
            continue
        if kind == 'num':
            toks.append(('num', float(text)))
        elif kind == 'str':
            toks.append(('str', json.loads(text)))
        elif kind == 'field':
            toks.append(('field', text[1:]))
        elif kind == 'var':
            toks.append(('var', text[1:]))
        elif kind == 'ident':
            toks.append(('kw' if text in KEYWORDS else 'ident', text))
        else:
            toks.append(('op', text))
    toks.append(('eof', None))
    return toks


# ---------------------------------------------------------------------------
# Parser: produces a tuple-based AST
# ---------------------------------------------------------------------------
IDENTITY = ('identity',)
CMP_OPS = ('==', '!=', '<', '<=', '>', '>=')


class Parser:
    def __init__(self, src):
        self.toks = tokenize(src)
        self.pos = 0

    def peek(self):
        return self.toks[self.pos]

    def at(self, kind, val=None):
        k, v = self.toks[self.pos]
        return k == kind and (val is None or v == val)

    def next(self):
        t = self.toks[self.pos]
        self.pos += 1
        return t

    def expect(self, kind, val=None):
        if not self.at(kind, val):
            raise ParseError('expected %s %r, got %r' % (kind, val, self.peek()))
        return self.next()[1]

    def parse_program(self):
        node = self.parse_pipe()
        self.expect('eof')
        return node

    def parse_pipe(self):
        # `term as $x | body` binds a variable for the rest of the pipe.
        save = self.pos
        try:
            src = self.parse_postfix()
        except ParseError:
            src = None
        if src is not None and self.at('kw', 'as'):
            self.next()
            name = self.expect('var')
            self.expect('op', '|')
            body = self.parse_pipe()
            return ('as', src, name, body)
        self.pos = save
        left = self.parse_comma()
        if self.at('op', '|'):
            self.next()
            return ('pipe', left, self.parse_pipe())
        return left

    def parse_comma(self):
        left = self.parse_or()
        while self.at('op', ','):
            self.next()
            left = ('comma', left, self.parse_or())
        return left

    def parse_or(self):
        left = self.parse_and()
        while self.at('kw', 'or'):
            self.next()
            left = ('or', left, self.parse_and())
        return left

    def parse_and(self):
        left = self.parse_cmp()
        while self.at('kw', 'and'):
            self.next()
            left = ('and', left, self.parse_cmp())
        return left

    def parse_cmp(self):
        left = self.parse_add()
        if self.at('op') and self.peek()[1] in CMP_OPS:
            op = self.next()[1]
            right = self.parse_add()
            if self.at('op') and self.peek()[1] in CMP_OPS:
                raise ParseError('comparison operators are non-associative')
            return ('binop', op, left, right)
        return left

    def parse_add(self):
        left = self.parse_mul()
        while self.at('op') and self.peek()[1] in ('+', '-'):
            op = self.next()[1]
            left = ('binop', op, left, self.parse_mul())
        return left

    def parse_mul(self):
        left = self.parse_unary()
        while self.at('op') and self.peek()[1] in ('*', '/', '%'):
            op = self.next()[1]
            left = ('binop', op, left, self.parse_unary())
        return left

    def parse_unary(self):
        if self.at('op', '-'):
            self.next()
            return ('neg', self.parse_unary())
        return self.parse_postfix()

    def parse_postfix(self):
        node = self.parse_primary()
        # True while the newest part of the term is an index/iterate/slice
        # suffix that a following `?` can make optional.
        suffix = False
        while True:
            if self.at('field'):
                node = ('index', node, ('lit', self.next()[1]), False)
                suffix = True
            elif self.at('op', '.') and self.toks[self.pos + 1][0] == 'str':
                self.next()
                node = ('index', node, ('lit', self.next()[1]), False)
                suffix = True
            elif self.at('op', '['):
                self.next()
                suffix = True
                if self.at('op', ']'):
                    self.next()
                    node = ('iter', node, False)
                    continue
                start = None
                if not self.at('op', ':'):
                    start = self.parse_pipe()
                if self.at('op', ':'):
                    self.next()
                    end = None
                    if not self.at('op', ']'):
                        end = self.parse_pipe()
                    self.expect('op', ']')
                    node = ('slice', node, start, end, False)
                else:
                    self.expect('op', ']')
                    node = ('index', node, start, False)
            elif self.at('op', '?'):
                self.next()
                # `?` right after an index/iterate/slice suffix makes that one
                # operation optional; anywhere else it wraps the whole term in try.
                if suffix:
                    node = node[:-1] + (True,)
                    suffix = False
                else:
                    node = ('try', node)
            else:
                return node

    def parse_primary(self):
        kind, val = self.peek()
        if kind == 'op' and val == '.':
            self.next()
            if self.at('str'):
                return ('index', IDENTITY, ('lit', self.next()[1]), False)
            return IDENTITY
        if kind == 'field':
            self.next()
            return ('index', IDENTITY, ('lit', val), False)
        if kind == 'num' or kind == 'str':
            self.next()
            return ('lit', val)
        if kind == 'kw' and val in ('true', 'false', 'null'):
            self.next()
            return ('lit', {'true': True, 'false': False, 'null': None}[val])
        if kind == 'var':
            self.next()
            return ('var', val)
        if kind == 'op' and val == '(':
            self.next()
            node = self.parse_pipe()
            self.expect('op', ')')
            return node
        if kind == 'op' and val == '[':
            self.next()
            if self.at('op', ']'):
                self.next()
                return ('array', None)
            node = self.parse_pipe()
            self.expect('op', ']')
            return ('array', node)
        if kind == 'op' and val == '{':
            return self.parse_object()
        if kind == 'kw' and val == 'if':
            return self.parse_if()
        if kind == 'kw' and val == 'reduce':
            self.next()
            src = self.parse_postfix()
            self.expect('kw', 'as')
            name = self.expect('var')
            self.expect('op', '(')
            init = self.parse_pipe()
            self.expect('op', ';')
            update = self.parse_pipe()
            self.expect('op', ')')
            return ('reduce', src, name, init, update)
        if kind == 'ident':
            self.next()
            args = []
            if self.at('op', '('):
                self.next()
                args.append(self.parse_pipe())
                while self.at('op', ';'):
                    self.next()
                    args.append(self.parse_pipe())
                self.expect('op', ')')
            if (val, len(args)) not in BUILTINS:
                raise ParseError('%s/%d is not defined' % (val, len(args)))
            return ('call', val, args)
        raise ParseError('unexpected token %r' % (self.peek(),))

    def parse_if(self):
        self.expect('kw', 'if')
        return self.parse_if_rest()

    def parse_if_rest(self):
        """Parses `cond then a (elif ... | else b)? end` after `if`/`elif`;
        an `elif` chain becomes a nested if in the else branch."""
        cond = self.parse_pipe()
        self.expect('kw', 'then')
        then = self.parse_pipe()
        if self.at('kw', 'elif'):
            self.next()
            return ('if', cond, then, self.parse_if_rest())
        els = None
        if self.at('kw', 'else'):
            self.next()
            els = self.parse_pipe()
        self.expect('kw', 'end')
        return ('if', cond, then, els)

    def parse_object(self):
        self.expect('op', '{')
        entries = []
        if not self.at('op', '}'):
            while True:
                entries.append(self.parse_entry())
                if self.at('op', ','):
                    self.next()
                    continue
                break
        self.expect('op', '}')
        return ('object', entries)

    def parse_entry(self):
        kind, val = self.peek()
        if kind == 'var':
            self.next()
            return (('lit', val), ('var', val))
        if kind == 'ident' or kind == 'str':
            self.next()
            if self.at('op', ':'):
                self.next()
                return (('lit', val), self.parse_objval())
            return (('lit', val), ('index', IDENTITY, ('lit', val), False))
        if kind == 'op' and val == '(':
            self.next()
            key = self.parse_pipe()
            self.expect('op', ')')
            self.expect('op', ':')
            return (key, self.parse_objval())
        raise ParseError('bad object entry %r' % (self.peek(),))

    def parse_objval(self):
        node = self.parse_objterm()
        while self.at('op', '|'):
            self.next()
            node = ('pipe', node, self.parse_objterm())
        return node

    def parse_objterm(self):
        if self.at('op', '-'):
            self.next()
            return ('neg', self.parse_objterm())
        return self.parse_postfix()


# ---------------------------------------------------------------------------
# Values: None, bool, float, str, list, dict (insertion-ordered)
# ---------------------------------------------------------------------------
def isnum(v):
    return isinstance(v, float)


def truthy(v):
    return v is not None and v is not False


def kind_rank(v):
    if v is None:
        return 0
    if v is False:
        return 1
    if v is True:
        return 2
    if isinstance(v, float):
        return 3
    if isinstance(v, str):
        return 4
    if isinstance(v, list):
        return 5
    return 6


def type_name(v):
    return ('null', 'boolean', 'boolean', 'number', 'string', 'array', 'object')[kind_rank(v)]


def cmp(a, b):
    ra, rb = kind_rank(a), kind_rank(b)
    if ra != rb:
        return -1 if ra < rb else 1
    if ra <= 2:
        return 0
    if ra <= 4:
        return -1 if a < b else (1 if a > b else 0)
    if ra == 5:
        for x, y in zip(a, b):
            c = cmp(x, y)
            if c:
                return c
        return (len(a) > len(b)) - (len(a) < len(b))
    ka, kb = sorted(a), sorted(b)
    c = cmp(ka, kb)
    if c:
        return c
    for k in ka:
        c = cmp(a[k], b[k])
        if c:
            return c
    return 0


cmp_key = cmp_to_key(cmp)


def equal(a, b):
    return cmp(a, b) == 0


# ---------------------------------------------------------------------------
# Output formatting (compact JSON, jq -c style)
# ---------------------------------------------------------------------------
ESCAPE_RE = re.compile(r'["\\\x00-\x1f\x7f]')
ESCAPE_TABLE = {chr(c): '\\u%04x' % c for c in range(0x20)}
ESCAPE_TABLE.update({'"': '\\"', '\\': '\\\\', '\b': '\\b', '\f': '\\f',
                     '\n': '\\n', '\r': '\\r', '\t': '\\t', '\x7f': '\\u007f'})


def fmt_num(f):
    if f == 0 and math.copysign(1.0, f) < 0:
        return '-0'
    if f == math.floor(f) and abs(f) < 1e17:
        return str(int(f))
    return repr(f)


def dump(v, out):
    if v is None:
        out.append('null')
    elif v is True:
        out.append('true')
    elif v is False:
        out.append('false')
    elif isinstance(v, float):
        out.append(fmt_num(v))
    elif isinstance(v, str):
        out.append('"')
        out.append(ESCAPE_RE.sub(lambda m: ESCAPE_TABLE[m.group(0)], v))
        out.append('"')
    elif isinstance(v, list):
        out.append('[')
        first = True
        for x in v:
            if not first:
                out.append(',')
            first = False
            dump(x, out)
        out.append(']')
    else:
        out.append('{')
        first = True
        for k, x in v.items():
            if not first:
                out.append(',')
            first = False
            dump(k, out)
            out.append(':')
            dump(x, out)
        out.append('}')


def to_json(v):
    out = []
    dump(v, out)
    return ''.join(out)


# ---------------------------------------------------------------------------
# Primitive operations
# ---------------------------------------------------------------------------
def op_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if isnum(a) and isnum(b):
        return a + b
    if isinstance(a, str) and isinstance(b, str):
        return a + b
    if isinstance(a, list) and isinstance(b, list):
        return a + b
    if isinstance(a, dict) and isinstance(b, dict):
        d = dict(a)
        d.update(b)
        return d
    raise JqError('cannot be added')


def op_sub(a, b):
    if isnum(a) and isnum(b):
        return a - b
    if isinstance(a, list) and isinstance(b, list):
        return [x for x in a if not any(equal(x, y) for y in b)]
    raise JqError('cannot be subtracted')


def deep_merge(a, b):
    d = dict(a)
    for k, v in b.items():
        if k in d and isinstance(d[k], dict) and isinstance(v, dict):
            d[k] = deep_merge(d[k], v)
        else:
            d[k] = v
    return d


def op_mul(a, b):
    if isnum(a) and isnum(b):
        return a * b
    if isinstance(a, str) and isnum(b) or isnum(a) and isinstance(b, str):
        s, n = (a, b) if isinstance(a, str) else (b, a)
        if n < 0:
            return None
        return s * int(n)
    if isinstance(a, dict) and isinstance(b, dict):
        return deep_merge(a, b)
    raise JqError('cannot be multiplied')


def op_div(a, b):
    if isnum(a) and isnum(b):
        if b == 0:
            raise JqError('division by zero')
        return a / b
    if isinstance(a, str) and isinstance(b, str):
        if a == '':
            return []
        if b == '':
            return list(a)
        return a.split(b)
    raise JqError('cannot be divided')


def op_mod(a, b):
    if isnum(a) and isnum(b):
        ia, ib = int(a), int(b)
        if ib == 0:
            raise JqError('modulo by zero')
        if ib == -1:
            return 0.0
        r = abs(ia) % abs(ib)
        return float(-r if ia < 0 else r)
    raise JqError('cannot be divided (remainder)')


def op_cmp(op):
    def f(a, b):
        c = cmp(a, b)
        if op == '==':
            return c == 0
        if op == '!=':
            return c != 0
        if op == '<':
            return c < 0
        if op == '<=':
            return c <= 0
        if op == '>':
            return c > 0
        return c >= 0
    return f


BINOPS = {'+': op_add, '-': op_sub, '*': op_mul, '/': op_div, '%': op_mod}
for _op in CMP_OPS:
    BINOPS[_op] = op_cmp(_op)


def index_value(t, k):
    if t is None:
        if isinstance(k, str) or isnum(k):
            return None
        raise JqError('cannot index null')
    if isinstance(t, dict):
        if isinstance(k, str):
            return t.get(k)
        raise JqError('cannot index object')
    if isinstance(t, list):
        if isnum(k):
            i = int(k)  # truncates toward zero, as jq's (int) cast does
            if i < 0:
                i += len(t)
            if 0 <= i < len(t):
                return t[i]
            return None
        raise JqError('cannot index array')
    raise JqError('cannot index %s' % type_name(t))


def slice_value(t, s, e):
    if t is None:
        return None
    if not isinstance(t, (list, str)):
        raise JqError('cannot slice %s' % type_name(t))
    n = len(t)
    if s is None:
        s = 0.0
    if e is None:
        e = float(n)
    if not (isnum(s) and isnum(e)):
        raise JqError('slice bounds must be numbers')
    if s < 0:
        s += n
    if e < 0:
        e += n
    s = max(0.0, min(float(n), s))
    e = max(0.0, min(float(n), e))
    if e < s:
        e = s
    return t[math.floor(s):math.ceil(e)]


def iterate(t):
    if isinstance(t, list):
        return t
    if isinstance(t, dict):
        return t.values()
    raise JqError('cannot iterate over %s' % type_name(t))


NUMBER_RE = re.compile(r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\Z')


# ---------------------------------------------------------------------------
# Builtins: each is a generator over (input, arg nodes, env)
# ---------------------------------------------------------------------------
def b_empty(inp, args, env):
    return
    yield


def b_error0(inp, args, env):
    raise JqError('error')
    yield


def b_error1(inp, args, env):
    for _ in ev(args[0], inp, env):
        raise JqError('error')
    return
    yield


def b_not(inp, args, env):
    yield not truthy(inp)


def b_length(inp, args, env):
    if inp is None:
        yield 0.0
    elif isinstance(inp, bool):
        raise JqError('boolean has no length')
    elif isnum(inp):
        yield abs(inp)
    else:
        yield float(len(inp))


def b_keys(inp, args, env):
    if isinstance(inp, dict):
        yield sorted(inp)
    elif isinstance(inp, list):
        yield [float(i) for i in range(len(inp))]
    else:
        raise JqError('has no keys')


def b_has(inp, args, env):
    for k in ev(args[0], inp, env):
        if inp is None:
            yield False
        elif isinstance(inp, dict) and isinstance(k, str):
            yield k in inp
        elif isinstance(inp, list) and isnum(k):
            yield 0 <= int(k) < len(inp)
        else:
            raise JqError('cannot check whether %s has a %s key' % (type_name(inp), type_name(k)))


def b_add(inp, args, env):
    acc = None
    for x in iterate(inp):
        acc = op_add(acc, x)
    yield acc


def require_array(inp, what):
    if not isinstance(inp, list):
        raise JqError('%s cannot be %s, as it is not an array' % (type_name(inp), what))


def b_sort(inp, args, env):
    require_array(inp, 'sorted')
    yield sorted(inp, key=cmp_key)


def keyed(inp, f, env):
    """Pairs each element with the array of all outputs of f on it."""
    return [(list(ev(f, x, env)), x) for x in inp]


def b_sort_by(inp, args, env):
    require_array(inp, 'sorted')
    pairs = keyed(inp, args[0], env)
    pairs.sort(key=lambda p: cmp_key(p[0]))
    yield [x for _, x in pairs]


def group_pairs(pairs):
    pairs.sort(key=lambda p: cmp_key(p[0]))
    groups = []
    for k, x in pairs:
        if groups and equal(groups[-1][0], k):
            groups[-1][1].append(x)
        else:
            groups.append((k, [x]))
    return groups


def b_group_by(inp, args, env):
    require_array(inp, 'grouped')
    yield [g for _, g in group_pairs(keyed(inp, args[0], env))]


def b_unique(inp, args, env):
    require_array(inp, 'sorted')
    yield [g[0] for _, g in group_pairs([(x, x) for x in inp])]


def b_reverse(inp, args, env):
    if inp is None:
        yield []
    elif isinstance(inp, list):
        yield inp[::-1]
    else:
        raise JqError('cannot reverse %s' % type_name(inp))


def b_min(inp, args, env):
    require_array(inp, 'searched')
    best = None
    for i, x in enumerate(inp):
        if i == 0 or cmp(x, best) < 0:
            best = x
    yield best


def b_max(inp, args, env):
    require_array(inp, 'searched')
    best = None
    for i, x in enumerate(inp):
        if i == 0 or cmp(x, best) >= 0:
            best = x
    yield best


def b_tostring(inp, args, env):
    yield inp if isinstance(inp, str) else to_json(inp)


def b_tonumber(inp, args, env):
    if isnum(inp):
        yield inp
    elif isinstance(inp, str) and NUMBER_RE.match(inp):
        yield float(inp)
    else:
        raise JqError('cannot be parsed as a number')


def b_type(inp, args, env):
    yield type_name(inp)


def b_select(inp, args, env):
    for c in ev(args[0], inp, env):
        if truthy(c):
            yield inp


def b_map(inp, args, env):
    f = args[0]
    yield [v for x in iterate(inp) for v in ev(f, x, env)]


BUILTINS = {
    ('empty', 0): b_empty, ('error', 0): b_error0, ('error', 1): b_error1,
    ('not', 0): b_not, ('length', 0): b_length, ('keys', 0): b_keys,
    ('has', 1): b_has, ('add', 0): b_add, ('sort', 0): b_sort,
    ('sort_by', 1): b_sort_by, ('group_by', 1): b_group_by,
    ('unique', 0): b_unique, ('reverse', 0): b_reverse, ('min', 0): b_min,
    ('max', 0): b_max, ('tostring', 0): b_tostring, ('tonumber', 0): b_tonumber,
    ('type', 0): b_type, ('select', 1): b_select, ('map', 1): b_map,
}


# ---------------------------------------------------------------------------
# Evaluator: ev(node, input, env) is a generator of output values.
# env is a linked list of (name, value, parent) bindings.
# ---------------------------------------------------------------------------
def lookup(env, name):
    while env is not None:
        if env[0] == name:
            return env[1]
        env = env[2]
    raise ParseError('$%s is not defined' % name)


def ev_identity(node, inp, env):
    yield inp


def ev_lit(node, inp, env):
    yield node[1]


def ev_var(node, inp, env):
    yield lookup(env, node[1])


def ev_pipe(node, inp, env):
    right = node[2]
    for v in ev(node[1], inp, env):
        yield from ev(right, v, env)


def ev_comma(node, inp, env):
    yield from ev(node[1], inp, env)
    yield from ev(node[2], inp, env)


def ev_binop(node, inp, env):
    f = BINOPS[node[1]]
    left = node[2]
    # jq evaluates the right operand as the outer loop.
    for b in ev(node[3], inp, env):
        for a in ev(left, inp, env):
            yield f(a, b)


def ev_and(node, inp, env):
    for a in ev(node[1], inp, env):
        if not truthy(a):
            yield False
        else:
            for b in ev(node[2], inp, env):
                yield truthy(b)


def ev_or(node, inp, env):
    for a in ev(node[1], inp, env):
        if truthy(a):
            yield True
        else:
            for b in ev(node[2], inp, env):
                yield truthy(b)


def ev_neg(node, inp, env):
    for v in ev(node[1], inp, env):
        if not isnum(v):
            raise JqError('cannot be negated')
        yield -v


def ev_index(node, inp, env):
    _, target, idx, opt = node
    for k in ev(idx, inp, env):
        for t in ev(target, inp, env):
            try:
                v = index_value(t, k)
            except JqError:
                if opt:
                    continue
                raise
            yield v


def ev_iter(node, inp, env):
    _, target, opt = node
    for t in ev(target, inp, env):
        if isinstance(t, list):
            yield from t
        elif isinstance(t, dict):
            yield from t.values()
        elif not opt:
            raise JqError('cannot iterate over %s' % type_name(t))


def ev_slice(node, inp, env):
    _, target, start, end, opt = node
    starts = ev(start, inp, env) if start is not None else (None,)
    for s in starts:
        ends = ev(end, inp, env) if end is not None else (None,)
        for e in ends:
            for t in ev(target, inp, env):
                try:
                    v = slice_value(t, s, e)
                except JqError:
                    if opt:
                        continue
                    raise
                yield v


def ev_try(node, inp, env):
    try:
        yield from ev(node[1], inp, env)
    except JqError:
        return


def ev_array(node, inp, env):
    if node[1] is None:
        yield []
    else:
        yield list(ev(node[1], inp, env))


def ev_object(node, inp, env):
    entries = node[1]

    def build(i, acc):
        if i == len(entries):
            yield dict(acc)
            return
        knode, vnode = entries[i]
        for k in ev(knode, inp, env):
            if not isinstance(k, str):
                raise JqError('object keys must be strings')
            for v in ev(vnode, inp, env):
                yield from build(i + 1, acc + [(k, v)])
    yield from build(0, [])


def ev_if(node, inp, env):
    _, cond, then, els = node
    for c in ev(cond, inp, env):
        if truthy(c):
            yield from ev(then, inp, env)
        elif els is None:
            yield inp
        else:
            yield from ev(els, inp, env)


def ev_reduce(node, inp, env):
    _, src, name, init, update = node
    for acc in ev(init, inp, env):
        for x in ev(src, inp, env):
            last = None
            for v in ev(update, acc, (name, x, env)):
                last = v
            acc = last
        yield acc


def ev_as(node, inp, env):
    _, src, name, body = node
    for v in ev(src, inp, env):
        yield from ev(body, inp, (name, v, env))


def ev_call(node, inp, env):
    return BUILTINS[(node[1], len(node[2]))](inp, node[2], env)


EVAL = {
    'identity': ev_identity, 'lit': ev_lit, 'var': ev_var, 'pipe': ev_pipe,
    'comma': ev_comma, 'binop': ev_binop, 'and': ev_and, 'or': ev_or,
    'neg': ev_neg, 'index': ev_index, 'iter': ev_iter, 'slice': ev_slice,
    'try': ev_try, 'array': ev_array, 'object': ev_object, 'if': ev_if,
    'reduce': ev_reduce, 'as': ev_as, 'call': ev_call,
}


def ev(node, inp, env):
    return EVAL[node[0]](node, inp, env)


def main():
    sys.setrecursionlimit(20000)
    data = sys.stdin.buffer.read().decode('utf-8')
    nl = data.find('\n')
    if nl < 0:
        nl = len(data)
    filt = data[:nl]
    doc = json.loads(data[nl + 1:], parse_int=float, parse_float=float)
    ast = Parser(filt).parse_program()
    out = []
    try:
        for v in ev(ast, doc, None):
            out.append(to_json(v))
    except JqError:
        out.append('error')
    sys.stdout.write('\n'.join(out) + ('\n' if out else ''))


if __name__ == '__main__':
    main()
