#!/usr/bin/env python3
"""Reference spreadsheet engine for the `spreadsheet` problem.

Reads commands from stdin and writes the results of `get` and `dump`
commands to stdout. Cells hold numbers, strings or formulas; formulas form
a static dependency graph. Every edit recalculates only the cells that
transitively depend on the edited cell: the affected set is found by a
reverse BFS over dependents, its strongly connected components are computed
with an iterative Tarjan, cyclic components become #CYCLE!, and the rest are
evaluated in topological order.
"""
import math
import sys

sys.setrecursionlimit(1000000)


class Err:
    """A spreadsheet error value. Identity-compared; four singletons exist."""
    __slots__ = ('code',)

    def __init__(self, code):
        self.code = code


DIV0 = Err('#DIV/0!')
REF = Err('#REF!')
CYCLE = Err('#CYCLE!')
VALUE = Err('#VALUE!')

FUNCS = ('SUM', 'MIN', 'MAX', 'AVG', 'COUNT', 'IF')


# ---------------------------------------------------------------------------
# Cell names and number formatting
# ---------------------------------------------------------------------------

def col_index(letters):
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch) - 64)
    return n


def col_name(n):
    s = ''
    while n:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def parse_ref(letters, digits):
    """Returns (row, col) for a valid A1..ZZ9999 reference, else None."""
    if len(letters) > 2 or digits[0] == '0':
        return None
    row = int(digits)
    if row > 9999:
        return None
    return (row, col_index(letters))


def cell_name(key):
    return col_name(key[1]) + str(key[0])


def format_number(v):
    """Formats a finite double per SPEC: integral values below 1e15 as plain
    integers, everything else as C's printf("%.10g")."""
    if v == 0:
        return '0'
    if v == math.floor(v) and abs(v) < 1e15:
        return str(int(v))
    mant, exp = ('%.9e' % v).split('e')
    exp = int(exp)
    neg = mant.startswith('-')
    digits = mant.lstrip('-').replace('.', '').rstrip('0')
    if exp < -4 or exp >= 10:
        m = digits[0] + ('.' + digits[1:] if len(digits) > 1 else '')
        out = m + 'e' + ('+' if exp >= 0 else '-') + '%02d' % abs(exp)
    elif exp >= 0:
        ip = digits[:exp + 1].ljust(exp + 1, '0')
        fp = digits[exp + 1:]
        out = ip + ('.' + fp if fp else '')
    else:
        out = '0.' + '0' * (-exp - 1) + digits
    return ('-' if neg else '') + out


def to_text(v):
    if v is None:
        return ''
    if isinstance(v, str):
        return v
    return format_number(v)


def display(v):
    if isinstance(v, Err):
        return v.code
    return to_text(v)


# ---------------------------------------------------------------------------
# Formula lexer and parser
# ---------------------------------------------------------------------------

class BadRef(Exception):
    """Raised when a formula contains a reference outside A1..ZZ9999."""


def tokenize(s):
    toks = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == ' ':
            i += 1
        elif '0' <= c <= '9':
            j = i
            while j < n and '0' <= s[j] <= '9':
                j += 1
            if j < n and s[j] == '.':
                j += 1
                while j < n and '0' <= s[j] <= '9':
                    j += 1
            toks.append(('num', float(s[i:j])))
            i = j
        elif 'A' <= c <= 'Z':
            j = i
            while j < n and 'A' <= s[j] <= 'Z':
                j += 1
            k = j
            while k < n and '0' <= s[k] <= '9':
                k += 1
            if k > j:
                ref = parse_ref(s[i:j], s[j:k])
                if ref is None:
                    raise BadRef()
                toks.append(('ref', ref))
                i = k
            else:
                toks.append(('name', s[i:j]))
                i = j
        elif c == '"':
            j = s.index('"', i + 1)
            toks.append(('str', s[i + 1:j]))
            i = j + 1
        elif c in '+-*/&(),:':
            toks.append((c, None))
            i += 1
        elif c == '<':
            if i + 1 < n and s[i + 1] == '=':
                toks.append(('<=', None))
                i += 2
            elif i + 1 < n and s[i + 1] == '>':
                toks.append(('<>', None))
                i += 2
            else:
                toks.append(('<', None))
                i += 1
        elif c == '>':
            if i + 1 < n and s[i + 1] == '=':
                toks.append(('>=', None))
                i += 2
            else:
                toks.append(('>', None))
                i += 1
        elif c == '=':
            toks.append(('=', None))
            i += 1
        else:
            raise ValueError('bad character in formula: %r' % c)
    toks.append(('eof', None))
    return toks


class Parser:
    """Recursive-descent parser producing a tuple-based AST.

    Precedence, lowest to highest: comparisons, &, + -, * /, unary -.
    """

    def __init__(self, toks):
        self.toks = toks
        self.pos = 0

    def peek(self):
        return self.toks[self.pos][0]

    def take(self):
        t = self.toks[self.pos]
        self.pos += 1
        return t

    def expect(self, kind):
        t = self.take()
        if t[0] != kind:
            raise ValueError('expected %s, got %s' % (kind, t[0]))
        return t

    def formula(self):
        e = self.cmp()
        self.expect('eof')
        return e

    def cmp(self):
        e = self.cat()
        while self.peek() in ('=', '<>', '<', '>', '<=', '>='):
            op = self.take()[0]
            e = ('cmp', op, e, self.cat())
        return e

    def cat(self):
        e = self.add()
        while self.peek() == '&':
            self.take()
            e = ('cat', e, self.add())
        return e

    def add(self):
        e = self.mul()
        while self.peek() in ('+', '-'):
            op = self.take()[0]
            e = ('bin', op, e, self.mul())
        return e

    def mul(self):
        e = self.unary()
        while self.peek() in ('*', '/'):
            op = self.take()[0]
            e = ('bin', op, e, self.unary())
        return e

    def unary(self):
        if self.peek() == '-':
            self.take()
            return ('neg', self.unary())
        return self.primary()

    def primary(self):
        t = self.take()
        kind = t[0]
        if kind == 'num':
            return ('num', t[1])
        if kind == 'str':
            return ('str', t[1])
        if kind == 'ref':
            return ('ref', t[1])
        if kind == '(':
            e = self.cmp()
            self.expect(')')
            return e
        if kind == 'name':
            name = t[1]
            if name not in FUNCS:
                raise ValueError('unknown function ' + name)
            self.expect('(')
            args = []
            if self.peek() != ')':
                while True:
                    args.append(self.arg(name))
                    if self.peek() == ',':
                        self.take()
                    else:
                        break
            self.expect(')')
            if name == 'IF' and len(args) != 3:
                raise ValueError('IF takes 3 arguments')
            if name != 'IF' and not args:
                raise ValueError(name + ' takes at least 1 argument')
            return ('func', name, args)
        raise ValueError('unexpected token ' + kind)

    def arg(self, fname):
        if (fname != 'IF' and self.peek() == 'ref'
                and self.toks[self.pos + 1][0] == ':'):
            a = self.take()[1]
            self.take()
            b = self.expect('ref')[1]
            r1, c1 = a
            r2, c2 = b
            return ('range', (min(r1, r2), min(c1, c2)), (max(r1, r2), max(c1, c2)))
        return self.cmp()


def collect_deps(node, out):
    """Adds every cell referenced by the AST (ranges expanded) to `out`."""
    t = node[0]
    if t == 'ref':
        out.add(node[1])
    elif t == 'range':
        (r1, c1), (r2, c2) = node[1], node[2]
        for r in range(r1, r2 + 1):
            for c in range(c1, c2 + 1):
                out.add((r, c))
    elif t == 'neg':
        collect_deps(node[1], out)
    elif t == 'bin' or t == 'cmp':
        collect_deps(node[2], out)
        collect_deps(node[3], out)
    elif t == 'cat':
        collect_deps(node[1], out)
        collect_deps(node[2], out)
    elif t == 'func':
        for a in node[2]:
            collect_deps(a, out)


# ---------------------------------------------------------------------------
# Sheet and evaluation
# ---------------------------------------------------------------------------

class Cell:
    __slots__ = ('ast', 'value', 'deps')

    def __init__(self, ast, value, deps):
        self.ast = ast      # None for constant cells
        self.value = value
        self.deps = deps    # set of keys this formula reads


class Sheet:
    def __init__(self):
        self.cells = {}     # key -> Cell
        self.rdeps = {}     # key -> set of formula cells reading it

    def value_of(self, key):
        c = self.cells.get(key)
        return None if c is None else c.value

    # -- evaluation ---------------------------------------------------------

    def num_operand(self, v):
        """Coerces an operand for arithmetic; returns (value, error)."""
        if isinstance(v, Err):
            return None, v
        if isinstance(v, str):
            return None, VALUE
        if v is None:
            return 0.0, None
        return v, None

    def ev(self, node):
        t = node[0]
        if t == 'num' or t == 'str':
            return node[1]
        if t == 'ref':
            return self.value_of(node[1])
        if t == 'neg':
            a, e = self.num_operand(self.ev(node[1]))
            return e if e is not None else -a
        if t == 'bin':
            a, e = self.num_operand(self.ev(node[2]))
            if e is not None:
                return e
            b, e = self.num_operand(self.ev(node[3]))
            if e is not None:
                return e
            op = node[1]
            if op == '+':
                r = a + b
            elif op == '-':
                r = a - b
            elif op == '*':
                r = a * b
            else:
                if b == 0:
                    return DIV0
                r = a / b
            return r if math.isfinite(r) else VALUE
        if t == 'cat':
            a = self.ev(node[1])
            if isinstance(a, Err):
                return a
            b = self.ev(node[2])
            if isinstance(b, Err):
                return b
            return to_text(a) + to_text(b)
        if t == 'cmp':
            a = self.ev(node[2])
            if isinstance(a, Err):
                return a
            b = self.ev(node[3])
            if isinstance(b, Err):
                return b
            if a is None and b is None:
                a = b = 0.0
            elif a is None:
                a = '' if isinstance(b, str) else 0.0
            elif b is None:
                b = '' if isinstance(a, str) else 0.0
            op = node[1]
            if isinstance(a, str) != isinstance(b, str):
                if op == '=':
                    return 0.0
                if op == '<>':
                    return 1.0
                return VALUE
            if op == '=':
                res = a == b
            elif op == '<>':
                res = a != b
            elif op == '<':
                res = a < b
            elif op == '>':
                res = a > b
            elif op == '<=':
                res = a <= b
            else:
                res = a >= b
            return 1.0 if res else 0.0
        # function call
        name, args = node[1], node[2]
        if name == 'IF':
            c, e = self.num_operand(self.ev(args[0]))
            if e is not None:
                return e
            return self.ev(args[1] if c != 0 else args[2])
        nums = []
        for a in args:
            if a[0] == 'range':
                (r1, c1), (r2, c2) = a[1], a[2]
                value_of = self.value_of
                for r in range(r1, r2 + 1):
                    for c in range(c1, c2 + 1):
                        v = value_of((r, c))
                        if v is None:
                            continue
                        if isinstance(v, Err):
                            return v
                        if isinstance(v, float):
                            nums.append(v)
            else:
                v = self.ev(a)
                if isinstance(v, Err):
                    return v
                if v is None:
                    continue
                if isinstance(v, str):
                    return VALUE
                nums.append(v)
        if name == 'COUNT':
            return float(len(nums))
        if name == 'MIN':
            return min(nums) if nums else 0.0
        if name == 'MAX':
            return max(nums) if nums else 0.0
        s = 0.0
        for v in nums:
            s += v
        if name == 'AVG':
            if not nums:
                return DIV0
            s = s / len(nums)
        return s if math.isfinite(s) else VALUE

    def evaluate(self, cell):
        if cell.ast is None:
            return cell.value
        if cell.ast[0] == 'referr':
            return REF
        v = self.ev(cell.ast)
        return 0.0 if v is None else v

    # -- editing and recalculation ------------------------------------------

    def detach(self, key):
        c = self.cells.get(key)
        if c is not None and c.deps:
            rdeps = self.rdeps
            for d in c.deps:
                rdeps[d].discard(key)

    def set(self, key, content):
        self.detach(key)
        if content.startswith('='):
            try:
                ast = Parser(tokenize(content[1:])).formula()
                deps = set()
                collect_deps(ast, deps)
            except BadRef:
                ast, deps = ('referr',), set()
            cell = Cell(ast, None, deps)
            rdeps = self.rdeps
            for d in deps:
                s = rdeps.get(d)
                if s is None:
                    rdeps[d] = {key}
                else:
                    s.add(key)
        elif content.startswith('"'):
            cell = Cell(None, content[1:-1], ())
        else:
            cell = Cell(None, float(content), ())
        self.cells[key] = cell
        self.recalc(key)

    def clear(self, key):
        self.detach(key)
        self.cells.pop(key, None)
        self.recalc(key)

    def affected(self, start):
        """All cells that transitively read `start`, including `start`."""
        seen = {start}
        stack = [start]
        rdeps = self.rdeps
        while stack:
            k = stack.pop()
            for d in rdeps.get(k, ()):
                if d not in seen:
                    seen.add(d)
                    stack.append(d)
        return seen

    def recalc(self, start):
        affected = self.affected(start)
        cells = self.cells
        # Iterative Tarjan SCC restricted to the affected set. Components are
        # emitted dependencies-first, which is the evaluation order.
        index = {}
        low = {}
        onstack = set()
        stack = []
        counter = 0
        for root in affected:
            if root in index:
                continue
            work = [(root, None)]
            while work:
                v, it = work[-1]
                if it is None:
                    index[v] = low[v] = counter
                    counter += 1
                    stack.append(v)
                    onstack.add(v)
                    c = cells.get(v)
                    succ = [d for d in c.deps if d in affected] if c is not None and c.ast is not None else []
                    it = iter(succ)
                    work[-1] = (v, it)
                advanced = False
                for w in it:
                    if w not in index:
                        work.append((w, None))
                        advanced = True
                        break
                    if w in onstack:
                        low[v] = min(low[v], index[w])
                if advanced:
                    continue
                work.pop()
                if work:
                    p = work[-1][0]
                    low[p] = min(low[p], low[v])
                if low[v] == index[v]:
                    comp = []
                    while True:
                        w = stack.pop()
                        onstack.discard(w)
                        comp.append(w)
                        if w == v:
                            break
                    self.finish_component(comp)

    def finish_component(self, comp):
        cells = self.cells
        if len(comp) > 1:
            for k in comp:
                cells[k].value = CYCLE
            return
        k = comp[0]
        c = cells.get(k)
        if c is None:
            return
        if c.ast is not None and k in c.deps:
            c.value = CYCLE
        else:
            c.value = self.evaluate(c)

    # -- output -------------------------------------------------------------

    def dump(self, out):
        for key in sorted(self.cells):
            out.append(cell_name(key) + ' ' + display(self.cells[key].value))


def parse_cell_name(s):
    i = 0
    while i < len(s) and 'A' <= s[i] <= 'Z':
        i += 1
    return (int(s[i:]), col_index(s[:i]))


def main():
    sheet = Sheet()
    out = []
    for line in sys.stdin.read().split('\n'):
        if not line:
            continue
        if line.startswith('set '):
            sp = line.index(' ', 4)
            sheet.set(parse_cell_name(line[4:sp]), line[sp + 1:])
        elif line.startswith('get '):
            out.append(display(sheet.value_of(parse_cell_name(line[4:]))))
        elif line.startswith('clear '):
            sheet.clear(parse_cell_name(line[6:]))
        elif line == 'dump':
            sheet.dump(out)
        else:
            raise ValueError('unknown command: ' + line)
    sys.stdout.write('\n'.join(out) + ('\n' if out else ''))


if __name__ == '__main__':
    main()
