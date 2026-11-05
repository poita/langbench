#!/usr/bin/env python3
"""Reference implementation of the minisql problem.

A hand-written engine for the SQL subset in SPEC.md: a tokenizer, a
recursive-descent parser producing small tuple ASTs, a resolver that binds
column references and aggregate calls, and an executor with a hash join for
equality conjuncts. Reads statements from stdin and writes results to stdout.
"""
import re
import sys
from functools import cmp_to_key

sys.setrecursionlimit(10000)


class SQLError(Exception):
    """Any statement-level failure; the driver prints "error" for it."""


KEYWORDS = {
    'select', 'from', 'where', 'and', 'or', 'not', 'null', 'is', 'like', 'as',
    'insert', 'into', 'values', 'delete', 'update', 'set', 'create', 'table',
    'integer', 'text', 'inner', 'join', 'on', 'group', 'by', 'having', 'order',
    'asc', 'desc', 'limit', 'offset', 'left', 'right', 'full', 'outer',
    'cross', 'natural',
}
AGG_FUNCS = {'count', 'sum', 'min', 'max', 'avg'}


class Real:
    """AVG result: an exact number of hundredths."""
    __slots__ = ('hund',)

    def __init__(self, hund):
        self.hund = hund


# ---------------------------------------------------------------------------
# Tokenizer
# ---------------------------------------------------------------------------

_WS = re.compile(r'(?:[ \t\r\n\f\v]+|--[^\n]*)+')
_INT = re.compile(r'[0-9]+')
_ID = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
_OP = re.compile(r'<>|<=|>=|!=|==|[-+*/%=<>(),.;]')


def tokenize(src):
    """Returns a list of (kind, value, start, end) tokens.

    kind is one of ID (value lowercased), INT, STR, OP, BAD. An unterminated
    string literal becomes a single BAD token running to the end of input.
    """
    toks = []
    i, n = 0, len(src)
    while i < n:
        m = _WS.match(src, i)
        if m:
            i = m.end()
            continue
        c = src[i]
        if c == "'":
            j = i + 1
            buf = []
            while True:
                k = src.find("'", j)
                if k < 0:
                    toks.append(('BAD', src[i:], i, n))
                    i = n
                    break
                buf.append(src[j:k])
                if k + 1 < n and src[k + 1] == "'":
                    buf.append("'")
                    j = k + 2
                else:
                    toks.append(('STR', ''.join(buf), i, k + 1))
                    i = k + 1
                    break
            continue
        m = _INT.match(src, i)
        if m:
            toks.append(('INT', int(m.group()), i, m.end()))
            i = m.end()
            continue
        m = _ID.match(src, i)
        if m:
            toks.append(('ID', m.group().lower(), i, m.end()))
            i = m.end()
            continue
        m = _OP.match(src, i)
        if m:
            toks.append(('OP', m.group(), i, m.end()))
            i = m.end()
            continue
        toks.append(('BAD', c, i, i + 1))
        i += 1
    return toks


def split_statements(toks):
    """Splits a token list into statements at ';' tokens, dropping empties."""
    stmts = []
    cur = []
    for t in toks:
        if t[0] == 'OP' and t[1] == ';':
            if cur:
                stmts.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        stmts.append(cur)
    return stmts


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

class Parser:
    def __init__(self, toks):
        self.toks = toks
        self.i = 0

    def peek(self, k=0):
        j = self.i + k
        return self.toks[j] if j < len(self.toks) else ('EOF', None, -1, -1)

    def next(self):
        t = self.peek()
        self.i += 1
        return t

    def is_kw(self, *words):
        t = self.peek()
        return t[0] == 'ID' and t[1] in words

    def accept_kw(self, *words):
        if self.is_kw(*words):
            self.i += 1
            return True
        return False

    def expect_kw(self, word):
        if not self.accept_kw(word):
            raise SQLError('expected ' + word)

    def is_op(self, *ops):
        t = self.peek()
        return t[0] == 'OP' and t[1] in ops

    def accept_op(self, *ops):
        if self.is_op(*ops):
            return self.next()[1]
        return None

    def expect_op(self, op):
        if not self.accept_op(op):
            raise SQLError('expected ' + op)

    def ident(self):
        t = self.next()
        if t[0] != 'ID' or t[1] in KEYWORDS:
            raise SQLError('expected identifier')
        return t[1]

    def integer(self):
        t = self.next()
        if t[0] != 'INT':
            raise SQLError('expected integer')
        return t[1]

    def end(self):
        if self.peek()[0] != 'EOF':
            raise SQLError('trailing tokens')

    # -- statements --

    def parse_statement(self):
        if self.accept_kw('create'):
            self.expect_kw('table')
            name = self.ident()
            self.expect_op('(')
            cols = []
            while True:
                cname = self.ident()
                ctype = self.next()
                if ctype[0] != 'ID' or ctype[1] not in ('integer', 'text'):
                    raise SQLError('bad column type')
                cols.append((cname, ctype[1]))
                if not self.accept_op(','):
                    break
            self.expect_op(')')
            self.end()
            return ('create', name, cols)
        if self.accept_kw('insert'):
            self.expect_kw('into')
            name = self.ident()
            self.expect_kw('values')
            rows = []
            while True:
                self.expect_op('(')
                vals = [self.expr()]
                while self.accept_op(','):
                    vals.append(self.expr())
                self.expect_op(')')
                rows.append(vals)
                if not self.accept_op(','):
                    break
            self.end()
            return ('insert', name, rows)
        if self.accept_kw('delete'):
            self.expect_kw('from')
            name = self.ident()
            where = self.expr() if self.accept_kw('where') else None
            self.end()
            return ('delete', name, where)
        if self.accept_kw('update'):
            name = self.ident()
            self.expect_kw('set')
            sets = []
            while True:
                col = self.ident()
                self.expect_op('=')
                sets.append((col, self.expr()))
                if not self.accept_op(','):
                    break
            where = self.expr() if self.accept_kw('where') else None
            self.end()
            return ('update', name, sets, where)
        if self.accept_kw('select'):
            return self.parse_select()
        raise SQLError('unknown statement')

    def table_ref(self):
        name = self.ident()
        alias = None
        if self.accept_kw('as'):
            alias = self.ident()
        elif self.peek()[0] == 'ID' and self.peek()[1] not in KEYWORDS:
            alias = self.ident()
        return (name, alias)

    def parse_select(self):
        items = []
        while True:
            if self.accept_op('*'):
                items.append(('star', None, None))
            else:
                e = self.expr()
                alias = None
                if self.accept_kw('as'):
                    alias = self.ident()
                elif self.peek()[0] == 'ID' and self.peek()[1] not in KEYWORDS:
                    alias = self.ident()
                items.append(('expr', e, alias))
            if not self.accept_op(','):
                break
        sources = []
        join_on = None
        if self.accept_kw('from'):
            sources.append(self.table_ref())
            if self.accept_op(','):
                sources.append(self.table_ref())
            elif self.is_kw('inner', 'join'):
                self.accept_kw('inner')
                self.expect_kw('join')
                sources.append(self.table_ref())
                self.expect_kw('on')
                join_on = self.expr()
        where = self.expr() if self.accept_kw('where') else None
        group = []
        if self.accept_kw('group'):
            self.expect_kw('by')
            while True:
                e = self.expr()
                if e[0] != 'col':
                    raise SQLError('GROUP BY term must be a column')
                group.append(e)
                if not self.accept_op(','):
                    break
        having = None
        if self.accept_kw('having'):
            if not group:
                raise SQLError('HAVING without GROUP BY')
            having = self.expr()
        order = []
        if self.accept_kw('order'):
            self.expect_kw('by')
            while True:
                e = self.expr()
                desc = False
                if self.accept_kw('desc'):
                    desc = True
                else:
                    self.accept_kw('asc')
                order.append((e, desc))
                if not self.accept_op(','):
                    break
        limit = None
        offset = 0
        if self.accept_kw('limit'):
            limit = self.integer()
            if self.accept_kw('offset'):
                offset = self.integer()
        self.end()
        return ('select', items, sources, join_on, where, group, having, order, limit, offset)

    # -- expressions, lowest precedence first --

    def expr(self):
        e = self.and_()
        while self.accept_kw('or'):
            e = ('or', e, self.and_())
        return e

    def and_(self):
        e = self.not_()
        while self.accept_kw('and'):
            e = ('and', e, self.not_())
        return e

    def not_(self):
        if self.accept_kw('not'):
            return ('not', self.not_())
        return self.eq()

    def eq(self):
        e = self.rel()
        while True:
            if self.accept_op('=', '=='):
                e = ('cmp', '=', e, self.rel())
            elif self.accept_op('!=', '<>'):
                e = ('cmp', '!=', e, self.rel())
            elif self.accept_kw('is'):
                neg = self.accept_kw('not')
                self.expect_kw('null')
                e = ('isnull', e, neg)
            elif self.accept_kw('like'):
                e = ('like', e, self.rel(), False)
            elif self.is_kw('not') and self.peek(1)[0] == 'ID' and self.peek(1)[1] == 'like':
                self.next()
                self.next()
                e = ('like', e, self.rel(), True)
            else:
                return e

    def rel(self):
        e = self.add()
        while True:
            op = self.accept_op('<', '<=', '>', '>=')
            if op is None:
                return e
            e = ('cmp', op, e, self.add())

    def add(self):
        e = self.mul()
        while True:
            op = self.accept_op('+', '-')
            if op is None:
                return e
            e = ('bin', op, e, self.mul())

    def mul(self):
        e = self.unary()
        while True:
            op = self.accept_op('*', '/', '%')
            if op is None:
                return e
            e = ('bin', op, e, self.unary())

    def unary(self):
        if self.accept_op('-'):
            return ('neg', self.unary())
        return self.primary()

    def primary(self):
        t = self.next()
        if t[0] == 'INT' or t[0] == 'STR':
            return ('lit', t[1])
        if t[0] == 'OP' and t[1] == '(':
            e = self.expr()
            self.expect_op(')')
            return e
        if t[0] == 'ID':
            if t[1] == 'null':
                return ('lit', None)
            if self.is_op('('):
                self.next()
                if t[1] not in AGG_FUNCS:
                    raise SQLError('unknown function')
                if t[1] == 'count' and self.accept_op('*'):
                    arg = None
                else:
                    arg = self.expr()
                self.expect_op(')')
                return ('agg', t[1], arg)
            if t[1] in KEYWORDS:
                raise SQLError('keyword in expression')
            if self.accept_op('.'):
                return ('col', t[1], self.ident())
            return ('col', None, t[1])
        raise SQLError('bad expression')


# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

def rank(v):
    if v is None:
        return 0
    if isinstance(v, str):
        return 2
    return 1


def cmp_values(a, b):
    """Total order over values: NULL < numbers < text; -1, 0 or 1."""
    ra, rb = rank(a), rank(b)
    if ra != rb:
        return -1 if ra < rb else 1
    if ra == 0:
        return 0
    if ra == 1:
        x = a.hund if isinstance(a, Real) else a * 100
        y = b.hund if isinstance(b, Real) else b * 100
    else:
        x, y = a, b
    return (x > y) - (x < y)


def truth(v):
    """Boolean interpretation: None (unknown), True or False."""
    if v is None:
        return None
    if isinstance(v, int):
        return v != 0
    if isinstance(v, Real):
        return v.hund != 0
    raise SQLError('text in boolean context')


def arith(op, a, b):
    if a is None or b is None:
        return None
    if not isinstance(a, int) or not isinstance(b, int):
        raise SQLError('arithmetic on non-integer')
    if op == '+':
        return a + b
    if op == '-':
        return a - b
    if op == '*':
        return a * b
    if b == 0:
        return None
    q = abs(a) // abs(b)
    if op == '/':
        return q if (a < 0) == (b < 0) else -q
    r = abs(a) - q * abs(b)
    return r if a >= 0 else -r


_like_cache = {}


def fold_ascii(s):
    return ''.join(ch.lower() if 'A' <= ch <= 'Z' else ch for ch in s)


def like(s, p):
    if isinstance(s, int):
        s = str(s)
    if isinstance(p, int):
        p = str(p)
    if not isinstance(s, str) or not isinstance(p, str):
        raise SQLError('LIKE on non-text')
    rx = _like_cache.get(p)
    if rx is None:
        parts = []
        for ch in fold_ascii(p):
            if ch == '%':
                parts.append('.*')
            elif ch == '_':
                parts.append('.')
            else:
                parts.append(re.escape(ch))
        rx = re.compile(''.join(parts), re.S)
        _like_cache[p] = rx
    return rx.fullmatch(fold_ascii(s)) is not None


def ev(node, row, ag):
    """Evaluates a resolved expression against a flat row; ag holds the
    values of this group's aggregate calls, indexed by aggregate number."""
    t = node[0]
    if t == 'colref':
        return row[node[1]]
    if t == 'lit':
        return node[1]
    if t == 'cmp':
        a = ev(node[2], row, ag)
        b = ev(node[3], row, ag)
        if a is None or b is None:
            return None
        c = cmp_values(a, b)
        op = node[1]
        if op == '=':
            return 1 if c == 0 else 0
        if op == '!=':
            return 1 if c != 0 else 0
        if op == '<':
            return 1 if c < 0 else 0
        if op == '<=':
            return 1 if c <= 0 else 0
        if op == '>':
            return 1 if c > 0 else 0
        return 1 if c >= 0 else 0
    if t == 'bin':
        return arith(node[1], ev(node[2], row, ag), ev(node[3], row, ag))
    if t == 'and':
        a = truth(ev(node[1], row, ag))
        if a is False:
            return 0
        b = truth(ev(node[2], row, ag))
        if b is False:
            return 0
        if a is None or b is None:
            return None
        return 1
    if t == 'or':
        a = truth(ev(node[1], row, ag))
        if a is True:
            return 1
        b = truth(ev(node[2], row, ag))
        if b is True:
            return 1
        if a is None or b is None:
            return None
        return 0
    if t == 'not':
        v = truth(ev(node[1], row, ag))
        if v is None:
            return None
        return 0 if v else 1
    if t == 'neg':
        v = ev(node[1], row, ag)
        if v is None:
            return None
        if not isinstance(v, int):
            raise SQLError('negation of non-integer')
        return -v
    if t == 'isnull':
        r = 1 if ev(node[1], row, ag) is None else 0
        return 1 - r if node[2] else r
    if t == 'like':
        a = ev(node[1], row, ag)
        b = ev(node[2], row, ag)
        if a is None or b is None:
            return None
        r = 1 if like(a, b) else 0
        return 1 - r if node[3] else r
    if t == 'agg':
        return ag[node[1]]
    raise SQLError('bad node')


def compute_aggs(aggs, rows):
    vals = []
    for fname, arg in aggs:
        if fname == 'count':
            if arg is None:
                vals.append(len(rows))
            else:
                vals.append(sum(1 for r in rows if ev(arg, r, None) is not None))
            continue
        xs = [v for v in (ev(arg, r, None) for r in rows) if v is not None]
        if not xs:
            vals.append(None)
        elif fname == 'min' or fname == 'max':
            best = xs[0]
            for v in xs[1:]:
                c = cmp_values(v, best)
                if (c < 0) if fname == 'min' else (c > 0):
                    best = v
            vals.append(best)
        else:
            if not all(isinstance(v, int) for v in xs):
                raise SQLError('SUM/AVG of non-integer')
            s = sum(xs)
            if fname == 'sum':
                vals.append(s)
            else:
                c = len(xs)
                h = (200 * abs(s) + c) // (2 * c)
                vals.append(Real(-h if s < 0 else h))
    return vals


def fmt(v):
    if v is None:
        return 'NULL'
    if isinstance(v, Real):
        h = v.hund
        sign = '-' if h < 0 else ''
        h = abs(h)
        return '%s%d.%02d' % (sign, h // 100, h % 100)
    return str(v)


# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

class Scope:
    """Maps (qualifier, column) to an index into the flat row of a FROM list."""

    def __init__(self, sources):
        self.sources = []
        off = 0
        for eff, table in sources:
            self.sources.append((eff, table, off))
            off += len(table.cols)
        self.width = off

    def lookup(self, qual, name):
        if qual is not None:
            for eff, table, off in self.sources:
                if eff == qual:
                    if name not in table.index:
                        raise SQLError('no such column')
                    return off + table.index[name]
            raise SQLError('no such table')
        found = None
        for eff, table, off in self.sources:
            if name in table.index:
                if found is not None:
                    raise SQLError('ambiguous column')
                found = off + table.index[name]
        if found is None:
            raise SQLError('no such column')
        return found


class Resolver:
    def __init__(self, scope, allow_agg):
        self.scope = scope
        self.allow_agg = allow_agg
        self.aggs = []

    def resolve(self, node, in_agg=False):
        t = node[0]
        if t == 'lit':
            return node
        if t == 'col':
            return ('colref', self.scope.lookup(node[1], node[2]))
        if t == 'agg':
            if not self.allow_agg or in_agg:
                raise SQLError('misplaced aggregate')
            arg = self.resolve(node[2], True) if node[2] is not None else None
            self.aggs.append((node[1], arg))
            return ('agg', len(self.aggs) - 1)
        if t == 'neg' or t == 'not':
            return (t, self.resolve(node[1], in_agg))
        if t == 'isnull':
            return (t, self.resolve(node[1], in_agg), node[2])
        if t == 'like':
            return (t, self.resolve(node[1], in_agg), self.resolve(node[2], in_agg), node[3])
        if t == 'and' or t == 'or':
            return (t, self.resolve(node[1], in_agg), self.resolve(node[2], in_agg))
        if t == 'cmp' or t == 'bin':
            return (t, node[1], self.resolve(node[2], in_agg), self.resolve(node[3], in_agg))
        raise SQLError('bad node')


def check_grouped(node, gset):
    """Rejects column references outside aggregates that are not grouping columns."""
    t = node[0]
    if t == 'colref':
        if node[1] not in gset:
            raise SQLError('column not in GROUP BY')
    elif t in ('lit', 'agg'):
        return
    else:
        for child in node[1:]:
            if isinstance(child, tuple):
                check_grouped(child, gset)


def colrefs(node, acc):
    if node[0] == 'colref':
        acc.add(node[1])
    elif node[0] not in ('lit',):
        for child in node[1:]:
            if isinstance(child, tuple):
                colrefs(child, acc)
    return acc


def split_and(node):
    if node is None:
        return []
    if node[0] == 'and':
        return split_and(node[1]) + split_and(node[2])
    return [node]


# ---------------------------------------------------------------------------
# Executor
# ---------------------------------------------------------------------------

class Table:
    def __init__(self, name, cols):
        self.name = name
        self.cols = [c for c, _ in cols]
        self.types = [t for _, t in cols]
        self.index = {c: i for i, c in enumerate(self.cols)}
        self.rows = []


class Database:
    def __init__(self):
        self.tables = {}

    def table(self, name):
        t = self.tables.get(name)
        if t is None:
            raise SQLError('no such table')
        return t

    def execute(self, stmt, out):
        kind = stmt[0]
        if kind == 'create':
            _, name, cols = stmt
            if name in self.tables:
                raise SQLError('table exists')
            names = [c for c, _ in cols]
            if len(set(names)) != len(names):
                raise SQLError('duplicate column')
            self.tables[name] = Table(name, cols)
        elif kind == 'insert':
            _, name, rows = stmt
            table = self.table(name)
            res = Resolver(Scope([]), False)
            new_rows = []
            for vals in rows:
                if len(vals) != len(table.cols):
                    raise SQLError('column count mismatch')
                new_rows.append([ev(res.resolve(e), None, None) for e in vals])
            table.rows.extend(new_rows)
        elif kind == 'delete':
            _, name, where = stmt
            table = self.table(name)
            if where is None:
                table.rows = []
            else:
                w = Resolver(Scope([(name, table)]), False).resolve(where)
                table.rows = [r for r in table.rows if truth(ev(w, r, None)) is not True]
        elif kind == 'update':
            _, name, sets, where = stmt
            table = self.table(name)
            res = Resolver(Scope([(name, table)]), False)
            assigns = []
            for col, e in sets:
                if col not in table.index:
                    raise SQLError('no such column')
                assigns.append((table.index[col], res.resolve(e)))
            w = res.resolve(where) if where is not None else None
            pending = []
            for r in table.rows:
                if w is None or truth(ev(w, r, None)) is True:
                    pending.append((r, [ev(e, r, None) for _, e in assigns]))
            for r, vals in pending:
                for (idx, _), v in zip(assigns, vals):
                    r[idx] = v
        else:
            out.extend(self.select(stmt))

    def scan(self, sources, conj):
        """Produces the flat rows of the FROM list satisfying every conjunct."""
        if len(sources) == 1:
            rows = sources[0][1].rows
            if not conj:
                return list(rows)
            return [r for r in rows if all(truth(ev(c, r, None)) is True for c in conj)]
        left, right = sources[0][1], sources[1][1]
        nl = len(left.cols)
        nr = len(right.cols)
        lcols = set(range(nl))
        rcols = set(range(nl, nl + nr))
        key = None
        rest = []
        for c in conj:
            if key is None and c[0] == 'cmp' and c[1] == '=':
                ca = colrefs(c[2], set())
                cb = colrefs(c[3], set())
                if ca and cb and ca <= lcols and cb <= rcols:
                    key = (c[2], c[3])
                    continue
                if ca and cb and ca <= rcols and cb <= lcols:
                    key = (c[3], c[2])
                    continue
            rest.append(c)
        result = []
        if key is None:
            for lr in left.rows:
                for rr in right.rows:
                    row = lr + rr
                    if all(truth(ev(c, row, None)) is True for c in rest):
                        result.append(row)
            return result
        lexpr, rexpr = key
        lpad = [None] * nl
        buckets = {}
        for rr in right.rows:
            k = ev(rexpr, lpad + rr, None)
            if k is not None:
                buckets.setdefault(k, []).append(rr)
        rpad = [None] * nr
        for lr in left.rows:
            k = ev(lexpr, lr + rpad, None)
            if k is None:
                continue
            for rr in buckets.get(k, ()):
                row = lr + rr
                if all(truth(ev(c, row, None)) is True for c in rest):
                    result.append(row)
        return result

    def select(self, stmt):
        _, raw_items, raw_sources, join_on, where, group, having, order, limit, offset = stmt
        sources = []
        for tname, alias in raw_sources:
            table = self.table(tname)
            eff = alias or tname
            if any(eff == e for e, _ in sources):
                raise SQLError('duplicate table name')
            sources.append((eff, table))
        scope = Scope(sources)
        res = Resolver(scope, True)
        items = []
        for it in raw_items:
            if it[0] == 'star':
                if not sources:
                    raise SQLError('* without FROM')
                for eff, table, off in scope.sources:
                    for i in range(len(table.cols)):
                        items.append((('colref', off + i), None))
            else:
                items.append((res.resolve(it[1]), it[2]))
        plain = Resolver(scope, False)
        conj = split_and(plain.resolve(join_on) if join_on is not None else None)
        conj += split_and(plain.resolve(where) if where is not None else None)
        gidx = [scope.lookup(g[1], g[2]) for g in group]
        hav = res.resolve(having) if having is not None else None
        okeys = []
        for e, desc in order:
            if e[0] == 'col' and e[1] is None and any(a == e[2] for _, a in items):
                okeys.append((('out', next(i for i, (_, a) in enumerate(items) if a == e[2])), desc))
            elif e[0] == 'lit' and isinstance(e[1], int):
                if not 1 <= e[1] <= len(items):
                    raise SQLError('ORDER BY ordinal out of range')
                okeys.append((('out', e[1] - 1), desc))
            else:
                okeys.append((('expr', res.resolve(e)), desc))
        is_agg = bool(gidx) or bool(res.aggs)
        if is_agg:
            gset = set(gidx)
            for e, _ in items:
                check_grouped(e, gset)
            if hav is not None:
                check_grouped(hav, gset)
            for k, _ in okeys:
                if k[0] == 'expr':
                    check_grouped(k[1], gset)

        if sources:
            rows = self.scan(sources, conj)
        else:
            rows = [[]] if all(truth(ev(c, [], None)) is True for c in conj) else []

        def keys_for(row, outv, ag):
            return [outv[k[1]] if k[0] == 'out' else ev(k[1], row, ag) for k, _ in okeys]

        outrows = []
        if not is_agg:
            for r in rows:
                outv = [ev(e, r, None) for e, _ in items]
                outrows.append((outv, keys_for(r, outv, None)))
        else:
            if gidx:
                groups = {}
                for r in rows:
                    groups.setdefault(tuple(r[i] for i in gidx), []).append(r)
                keys = sorted(groups.keys(), key=cmp_to_key(cmp_tuples))
            else:
                groups = {(): rows}
                keys = [()]
            blank = [None] * scope.width
            for gk in keys:
                grows = groups[gk]
                ag = compute_aggs(res.aggs, grows)
                rep = grows[0] if grows else blank
                if hav is not None and truth(ev(hav, rep, ag)) is not True:
                    continue
                outv = [ev(e, rep, ag) for e, _ in items]
                outrows.append((outv, keys_for(rep, outv, ag)))

        if okeys:
            dirs = [desc for _, desc in okeys]

            def cmp_rows(x, y):
                for kx, ky, desc in zip(x[1], y[1], dirs):
                    c = cmp_values(kx, ky)
                    if c:
                        return -c if desc else c
                return 0
            outrows.sort(key=cmp_to_key(cmp_rows))
        if limit is not None:
            outrows = outrows[offset:offset + limit]
        lines = ['\t'.join(fmt(v) for v in outv) for outv, _ in outrows]
        lines.append('-- %d rows' % len(outrows))
        return lines


def cmp_tuples(a, b):
    for x, y in zip(a, b):
        c = cmp_values(x, y)
        if c:
            return c
    return 0


def run(src):
    db = Database()
    out = []
    for stmt_toks in split_statements(tokenize(src)):
        try:
            if any(t[0] == 'BAD' for t in stmt_toks):
                raise SQLError('bad token')
            stmt = Parser(stmt_toks).parse_statement()
            db.execute(stmt, out)
        except SQLError:
            out.append('error')
    return out


def main():
    src = sys.stdin.read()
    out = run(src)
    if out:
        sys.stdout.write('\n'.join(out) + '\n')


if __name__ == '__main__':
    main()
