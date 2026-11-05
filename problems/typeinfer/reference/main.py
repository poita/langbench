#!/usr/bin/env python3
"""Reference Hindley-Milner type inferencer for the `typeinfer` problem.

Reads a program of `;;`-terminated top-level declarations from stdin and
prints the principal type of each one, or `error: <kind>` when inference
fails. Inference is Algorithm J: destructive unification over union-find
type variables, with Remy-style levels so that generalisation at `let`
costs time proportional to the type being generalised rather than to the
size of the environment.
"""
import sys
import threading

# ---------------------------------------------------------------------------
# Lexer
# ---------------------------------------------------------------------------

KEYWORDS = {'let', 'rec', 'in', 'fun', 'if', 'then', 'else', 'true', 'false'}
# Multi-character symbols are listed before their prefixes so that the longest
# match is tried first.
SYMBOLS = [';;', '->', '::', '<=', '>=', '&&', '||',
           '(', ')', '[', ']', ';', ',', '+', '-', '*', '/', '=', '<', '>']


def tokenize(src):
    """Returns a list of (kind, text) tokens; kind is int, ident, kw or sym."""
    toks = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            i += 1
            continue
        if c.isdigit() and c.isascii():
            j = i
            while j < n and src[j].isascii() and src[j].isdigit():
                j += 1
            toks.append(('int', src[i:j]))
            i = j
            continue
        if 'a' <= c <= 'z':
            j = i
            while j < n and (src[j].isascii() and (src[j].isalnum() or src[j] == '_')):
                j += 1
            word = src[i:j]
            toks.append(('kw' if word in KEYWORDS else 'ident', word))
            i = j
            continue
        for s in SYMBOLS:
            if src.startswith(s, i):
                toks.append(('sym', s))
                i += len(s)
                break
        else:
            raise SyntaxError('unexpected character %r at %d' % (c, i))
    toks.append(('eof', ''))
    return toks


# ---------------------------------------------------------------------------
# Parser: produces nested tuples whose first element names the node kind.
#   ('int',) ('bool',) ('unit',) ('var', name) ('fun', [params], body)
#   ('app', f, arg) ('let', name, rhs, body) ('letrec', name, rhs, body)
#   ('if', c, t, e) ('tuple', [items]) ('list', [items]) ('cons', hd, tl)
#   ('binop', op, lhs, rhs)
# ---------------------------------------------------------------------------

class Parser:
    def __init__(self, toks):
        self.toks = toks
        self.pos = 0

    def peek(self):
        return self.toks[self.pos]

    def next(self):
        t = self.toks[self.pos]
        self.pos += 1
        return t

    def at_sym(self, s):
        t = self.toks[self.pos]
        return t[0] == 'sym' and t[1] == s

    def at_kw(self, k):
        t = self.toks[self.pos]
        return t[0] == 'kw' and t[1] == k

    def expect_sym(self, s):
        if not self.at_sym(s):
            raise SyntaxError('expected %r, got %r' % (s, self.peek()[1]))
        self.pos += 1

    def expect_kw(self, k):
        if not self.at_kw(k):
            raise SyntaxError('expected %r, got %r' % (k, self.peek()[1]))
        self.pos += 1

    def ident(self):
        t = self.next()
        if t[0] != 'ident':
            raise SyntaxError('expected identifier, got %r' % (t[1],))
        return t[1]

    def params(self):
        """Zero or more parameter names, up to the following `=` or `->`."""
        names = []
        while self.peek()[0] == 'ident':
            names.append(self.next()[1])
        return names

    def declaration(self):
        """Parses one top-level declaration up to and including its `;;`.

        Returns ('let', name, expr), ('letrec', name, expr) or ('expr', expr).
        A declaration that starts with `let` is always a binding.
        """
        if self.at_kw('let'):
            self.next()
            if self.at_kw('rec'):
                self.next()
                name = self.ident()
                ps = self.params()
                if not ps:
                    raise SyntaxError('let rec needs a parameter')
                self.expect_sym('=')
                result = ('letrec', name, ('fun', ps, self.expr()))
            else:
                name = self.ident()
                ps = self.params()
                self.expect_sym('=')
                body = self.expr()
                result = ('let', name, ('fun', ps, body) if ps else body)
        else:
            result = ('expr', self.expr())
        self.expect_sym(';;')
        return result

    def expr(self):
        if self.at_kw('let'):
            self.next()
            if self.at_kw('rec'):
                self.next()
                name = self.ident()
                ps = self.params()
                if not ps:
                    raise SyntaxError('let rec needs a parameter')
                self.expect_sym('=')
                rhs = self.expr()
                self.expect_kw('in')
                body = self.expr()
                return ('letrec', name, ('fun', ps, rhs), body)
            name = self.ident()
            ps = self.params()
            self.expect_sym('=')
            rhs = self.expr()
            self.expect_kw('in')
            body = self.expr()
            return ('let', name, ('fun', ps, rhs) if ps else rhs, body)
        if self.at_kw('fun'):
            self.next()
            ps = self.params()
            if not ps:
                raise SyntaxError('fun needs a parameter')
            self.expect_sym('->')
            return ('fun', ps, self.expr())
        if self.at_kw('if'):
            self.next()
            c = self.expr()
            self.expect_kw('then')
            t = self.expr()
            self.expect_kw('else')
            e = self.expr()
            return ('if', c, t, e)
        return self.orexpr()

    def orexpr(self):
        e = self.andexpr()
        while self.at_sym('||'):
            self.next()
            e = ('binop', '||', e, self.andexpr())
        return e

    def andexpr(self):
        e = self.cmpexpr()
        while self.at_sym('&&'):
            self.next()
            e = ('binop', '&&', e, self.cmpexpr())
        return e

    def cmpexpr(self):
        # Comparisons are non-associative: at most one per operand chain.
        e = self.consexpr()
        if self.peek()[0] == 'sym' and self.peek()[1] in ('=', '<', '>', '<=', '>='):
            op = self.next()[1]
            e = ('binop', op, e, self.consexpr())
        return e

    def consexpr(self):
        # `::` is right-associative; the chain is collected iteratively so
        # that long literal lists do not recurse in the parser.
        items = [self.addexpr()]
        while self.at_sym('::'):
            self.next()
            items.append(self.addexpr())
        e = items[-1]
        for item in reversed(items[:-1]):
            e = ('cons', item, e)
        return e

    def addexpr(self):
        e = self.mulexpr()
        while self.peek()[0] == 'sym' and self.peek()[1] in ('+', '-'):
            op = self.next()[1]
            e = ('binop', op, e, self.mulexpr())
        return e

    def mulexpr(self):
        e = self.app()
        while self.peek()[0] == 'sym' and self.peek()[1] in ('*', '/'):
            op = self.next()[1]
            e = ('binop', op, e, self.app())
        return e

    def starts_atom(self):
        k, s = self.peek()
        if k in ('int', 'ident'):
            return True
        if k == 'kw':
            return s in ('true', 'false')
        return k == 'sym' and s in ('(', '[')

    def app(self):
        e = self.atom()
        while self.starts_atom():
            e = ('app', e, self.atom())
        return e

    def atom(self):
        k, s = self.next()
        if k == 'int':
            return ('int',)
        if k == 'ident':
            return ('var', s)
        if k == 'kw' and s in ('true', 'false'):
            return ('bool',)
        if k == 'sym' and s == '(':
            if self.at_sym(')'):
                self.next()
                return ('unit',)
            items = [self.expr()]
            while self.at_sym(','):
                self.next()
                items.append(self.expr())
            self.expect_sym(')')
            return items[0] if len(items) == 1 else ('tuple', items)
        if k == 'sym' and s == '[':
            if self.at_sym(']'):
                self.next()
                return ('list', [])
            items = [self.expr()]
            while self.at_sym(';'):
                self.next()
                items.append(self.expr())
            self.expect_sym(']')
            return ('list', items)
        raise SyntaxError('unexpected token %r' % (s,))


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

class TVar:
    __slots__ = ('link', 'level', 'id')
    counter = 0

    def __init__(self, level):
        self.link = None
        self.level = level
        TVar.counter += 1
        self.id = TVar.counter


class TCon:
    """A type constructor application: name is one of int, bool, unit, list,
    -> or tuple; args are the argument types."""
    __slots__ = ('name', 'args')

    def __init__(self, name, args=()):
        self.name = name
        self.args = args


T_INT = TCon('int')
T_BOOL = TCon('bool')
T_UNIT = TCon('unit')


def arrow(a, b):
    return TCon('->', (a, b))


def tlist(a):
    return TCon('list', (a,))


def find(t):
    """Follows variable links to the representative type, compressing paths."""
    while isinstance(t, TVar) and t.link is not None:
        nxt = t.link
        if isinstance(nxt, TVar) and nxt.link is not None:
            t.link = nxt.link
        t = nxt
    return t


class InferError(Exception):
    def __init__(self, kind):
        Exception.__init__(self, kind)
        self.kind = kind


def bind_var(v, t):
    """Binds variable v to type t after checking that v does not occur in t.
    The same walk lowers the level of every variable in t to v's level, which
    is what keeps generalisation sound."""
    stack = [t]
    while stack:
        u = find(stack.pop())
        if isinstance(u, TVar):
            if u is v:
                raise InferError('occurs')
            if u.level > v.level:
                u.level = v.level
        else:
            stack.extend(u.args)
    v.link = t


def unify(a, b):
    """Unifies a with b. Sub-terms are unified left to right, depth first."""
    stack = [(a, b)]
    while stack:
        a, b = stack.pop()
        a = find(a)
        b = find(b)
        if a is b:
            continue
        if isinstance(a, TVar):
            bind_var(a, b)
        elif isinstance(b, TVar):
            bind_var(b, a)
        else:
            if a.name != b.name or len(a.args) != len(b.args):
                raise InferError('unify')
            # Pushed in reverse so that the leftmost pair is unified first.
            for pair in reversed(list(zip(a.args, b.args))):
                stack.append(pair)


# ---------------------------------------------------------------------------
# Schemes: a scheme is a type in which every variable whose level exceeds
# the level at which it was generalised is quantified. Instantiation copies
# such variables afresh; monomorphic bindings are stored with level -1 so
# that nothing in them is ever copied.
# ---------------------------------------------------------------------------

class Scheme:
    __slots__ = ('type', 'level')

    def __init__(self, type, level):
        self.type = type
        self.level = level


def instantiate(scheme, level):
    mapping = {}

    def copy(t):
        t = find(t)
        if isinstance(t, TVar):
            if t.level > scheme.level:
                v = mapping.get(t)
                if v is None:
                    v = mapping[t] = TVar(level)
                return v
            return t
        if not t.args:
            return t
        return TCon(t.name, tuple(copy(x) for x in t.args))

    return copy(scheme.type)


# ---------------------------------------------------------------------------
# Inference
# ---------------------------------------------------------------------------

class Env:
    """A persistent-ish environment: a chain of dicts, innermost first."""
    __slots__ = ('binds', 'parent')

    def __init__(self, binds, parent):
        self.binds = binds
        self.parent = parent

    def lookup(self, name):
        e = self
        while e is not None:
            s = e.binds.get(name)
            if s is not None:
                return s
            e = e.parent
        return None


def infer(env, node, level):
    kind = node[0]
    if kind == 'int':
        return T_INT
    if kind == 'bool':
        return T_BOOL
    if kind == 'unit':
        return T_UNIT
    if kind == 'var':
        s = env.lookup(node[1])
        if s is None:
            raise InferError('unbound')
        return instantiate(s, level)
    if kind == 'fun':
        binds = {}
        pts = []
        for p in node[1]:
            v = TVar(level)
            binds[p] = Scheme(v, level)
            pts.append(v)
        t = infer(Env(binds, env), node[2], level)
        for v in reversed(pts):
            t = arrow(v, t)
        return t
    if kind == 'app':
        tf = infer(env, node[1], level)
        ta = infer(env, node[2], level)
        r = TVar(level)
        unify(tf, arrow(ta, r))
        return r
    if kind == 'let':
        # The right-hand side is inferred one level deeper so that exactly the
        # variables created for it (and not unified with anything older) get
        # generalised.
        t = infer(env, node[2], level + 1)
        return infer(Env({node[1]: Scheme(t, level)}, env), node[3], level)
    if kind == 'letrec':
        v = TVar(level + 1)
        inner = Env({node[1]: Scheme(v, level + 1)}, env)
        t = infer(inner, node[2], level + 1)
        unify(v, t)
        return infer(Env({node[1]: Scheme(v, level)}, env), node[3], level)
    if kind == 'if':
        unify(infer(env, node[1], level), T_BOOL)
        t = infer(env, node[2], level)
        e = infer(env, node[3], level)
        unify(t, e)
        return t
    if kind == 'tuple':
        return TCon('tuple', tuple(infer(env, x, level) for x in node[1]))
    if kind == 'list':
        elem = TVar(level)
        for x in node[1]:
            unify(infer(env, x, level), elem)
        return tlist(elem)
    if kind == 'cons':
        hd = infer(env, node[1], level)
        tl = infer(env, node[2], level)
        unify(tl, tlist(hd))
        return tlist(hd)
    if kind == 'binop':
        op = node[1]
        if op in ('&&', '||'):
            operand, result = T_BOOL, T_BOOL
        elif op in ('+', '-', '*', '/'):
            operand, result = T_INT, T_INT
        else:
            operand, result = T_INT, T_BOOL
        unify(infer(env, node[2], level), operand)
        unify(infer(env, node[3], level), operand)
        return result
    raise AssertionError(kind)


def poly(build):
    """Builds a closed scheme from a function of fresh generic variables."""
    vs = [TVar(1) for _ in range(3)]
    return Scheme(build(*vs), 0)


def initial_env():
    b = {
        'not': poly(lambda a, b, c: arrow(T_BOOL, T_BOOL)),
        'fst': poly(lambda a, b, c: arrow(TCon('tuple', (a, b)), a)),
        'snd': poly(lambda a, b, c: arrow(TCon('tuple', (a, b)), b)),
        'hd': poly(lambda a, b, c: arrow(tlist(a), a)),
        'tl': poly(lambda a, b, c: arrow(tlist(a), tlist(a))),
        'null': poly(lambda a, b, c: arrow(tlist(a), T_BOOL)),
        'length': poly(lambda a, b, c: arrow(tlist(a), T_INT)),
        'map': poly(lambda a, b, c: arrow(arrow(a, b), arrow(tlist(a), tlist(b)))),
        'fold': poly(lambda a, b, c: arrow(arrow(a, arrow(b, a)), arrow(a, arrow(tlist(b), a)))),
    }
    return Env(b, None)


# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------

def var_name(i):
    letter = chr(ord('a') + i % 26)
    return "'" + letter + ('' if i < 26 else str(i // 26))


def show(t):
    """Renders a type with variables renamed in order of first appearance."""
    names = {}
    out = []

    def go(t, prec):
        # prec: 0 = arrow context, 1 = tuple element, 2 = list argument
        t = find(t)
        if isinstance(t, TVar):
            name = names.get(t)
            if name is None:
                name = names[t] = var_name(len(names))
            out.append(name)
            return
        if t.name == '->':
            if prec > 0:
                out.append('(')
            go(t.args[0], 1)
            out.append(' -> ')
            go(t.args[1], 0)
            if prec > 0:
                out.append(')')
        elif t.name == 'tuple':
            if prec > 1:
                out.append('(')
            for i, x in enumerate(t.args):
                if i:
                    out.append(' * ')
                go(x, 2)
            if prec > 1:
                out.append(')')
        elif t.name == 'list':
            go(t.args[0], 2)
            out.append(' list')
        else:
            out.append(t.name)

    go(t, 0)
    return ''.join(out)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def run(src, write):
    parser = Parser(tokenize(src))
    env = initial_env()
    while parser.peek()[0] != 'eof':
        decl = parser.declaration()
        try:
            if decl[0] == 'expr':
                t = infer(env, decl[1], 1)
                write('- : ' + show(t) + '\n')
            elif decl[0] == 'let':
                t = infer(env, decl[2], 1)
                env = Env({decl[1]: Scheme(t, 0)}, env)
                write(decl[1] + ' : ' + show(t) + '\n')
            else:
                v = TVar(1)
                inner = Env({decl[1]: Scheme(v, 1)}, env)
                t = infer(inner, decl[2], 1)
                unify(v, t)
                env = Env({decl[1]: Scheme(v, 0)}, env)
                write(decl[1] + ' : ' + show(v) + '\n')
        except InferError as e:
            write('error: ' + e.kind + '\n')


def main():
    src = sys.stdin.read()
    out = []
    run(src, out.append)
    sys.stdout.write(''.join(out))
    sys.stdout.flush()


if __name__ == '__main__':
    # Deep expressions recurse deeply, so inference runs on a thread with a
    # large stack; an exception on that thread still fails the process.
    sys.setrecursionlimit(1_000_000)
    threading.stack_size(1024 * 1024 * 1024)
    failure = []

    def guarded():
        try:
            main()
        except BaseException:
            import traceback
            traceback.print_exc()
            failure.append(1)

    t = threading.Thread(target=guarded)
    t.start()
    t.join()
    if failure:
        sys.exit(1)
