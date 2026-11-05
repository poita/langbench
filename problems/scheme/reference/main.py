#!/usr/bin/env python3
"""Reference interpreter for the langbench `scheme` problem.

Reads a Scheme program from stdin, evaluates each top-level form in order
and writes the results to stdout exactly as SPEC.md describes.

Forms are compiled into Python closures (one per syntax node) before they
run. Tail calls return a TailCall record instead of recursing, and `call`
loops on those records, so tail-recursive Scheme loops run in constant
Python stack. Non-tail recursion still uses the Python stack, which is why
`main` runs on a thread with a large stack and a high recursion limit.
"""
import sys
import threading


class SchemeError(Exception):
    """A runtime error; `category` is the word printed after `error: `."""

    def __init__(self, category):
        Exception.__init__(self, category)
        self.category = category


class Symbol:
    __slots__ = ('name',)

    def __init__(self, name):
        self.name = name


_symtab = {}


def sym(name):
    s = _symtab.get(name)
    if s is None:
        s = _symtab[name] = Symbol(name)
    return s


class Pair:
    __slots__ = ('car', 'cdr')

    def __init__(self, car, cdr):
        self.car = car
        self.cdr = cdr


class Nil:
    __slots__ = ()


class Void:
    __slots__ = ()


NIL = Nil()
VOID = Void()
MISSING = object()


class Closure:
    __slots__ = ('params', 'rest', 'body', 'env')

    def __init__(self, params, rest, body, env):
        self.params = params
        self.rest = rest
        self.body = body
        self.env = env


class Primitive:
    __slots__ = ('name', 'fn', 'lo', 'hi')

    def __init__(self, name, fn, lo, hi):
        self.name = name
        self.fn = fn
        self.lo = lo
        self.hi = hi


class TailCall:
    __slots__ = ('proc', 'args')

    def __init__(self, proc, args):
        self.proc = proc
        self.args = args


class Env:
    __slots__ = ('vars', 'parent')

    def __init__(self, vars, parent):
        self.vars = vars
        self.parent = parent


# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------

DELIMS = set(' \t\r\n()\'";')
ESCAPES = {'n': '\n', 't': '\t', '\\': '\\', '"': '"'}


def tokenize(src):
    """Yields ('(' | ')' | "'" | 'str' | 'atom', text) tokens."""
    i, n = 0, len(src)
    toks = []
    while i < n:
        c = src[i]
        if c in ' \t\r\n':
            i += 1
        elif c == ';':
            while i < n and src[i] != '\n':
                i += 1
        elif c in '()\'':
            toks.append((c, c))
            i += 1
        elif c == '"':
            i += 1
            buf = []
            while src[i] != '"':
                if src[i] == '\\':
                    i += 1
                    buf.append(ESCAPES.get(src[i], src[i]))
                else:
                    buf.append(src[i])
                i += 1
            i += 1
            toks.append(('str', ''.join(buf)))
        else:
            j = i
            while j < n and src[j] not in DELIMS:
                j += 1
            toks.append(('atom', src[i:j]))
            i = j
    return toks


def is_int_token(t):
    body = t[1:] if t[0] in '+-' else t
    return body != '' and body.isascii() and body.isdigit()


def parse_all(src):
    toks = tokenize(src)
    pos = [0]

    def read():
        kind, text = toks[pos[0]]
        pos[0] += 1
        if kind == '(':
            items = []
            tail = NIL
            while True:
                kind2, text2 = toks[pos[0]]
                if kind2 == ')':
                    pos[0] += 1
                    break
                if kind2 == 'atom' and text2 == '.':
                    pos[0] += 1
                    tail = read()
                    pos[0] += 1
                    break
                items.append(read())
            lst = tail
            for x in reversed(items):
                lst = Pair(x, lst)
            return lst
        if kind == "'":
            return Pair(QUOTE, Pair(read(), NIL))
        if kind == 'str':
            return text
        if text == '#t':
            return True
        if text == '#f':
            return False
        if is_int_token(text):
            return int(text)
        return sym(text)

    forms = []
    while pos[0] < len(toks):
        forms.append(read())
    return forms


# ---------------------------------------------------------------------------
# Printer
# ---------------------------------------------------------------------------

def write_str(x, display=False):
    parts = []
    _write(x, display, parts)
    return ''.join(parts)


def _write(x, display, out):
    t = type(x)
    if t is int:
        out.append(str(x))
    elif t is bool:
        out.append('#t' if x else '#f')
    elif t is str:
        if display:
            out.append(x)
        else:
            out.append('"')
            out.append(x.replace('\\', '\\\\').replace('"', '\\"')
                        .replace('\n', '\\n').replace('\t', '\\t'))
            out.append('"')
    elif t is Symbol:
        out.append(x.name)
    elif x is NIL:
        out.append('()')
    elif t is Pair:
        out.append('(')
        _write(x.car, display, out)
        x = x.cdr
        while type(x) is Pair:
            out.append(' ')
            _write(x.car, display, out)
            x = x.cdr
        if x is not NIL:
            out.append(' . ')
            _write(x, display, out)
        out.append(')')
    elif t is Closure or t is Primitive:
        out.append('#<procedure>')
    else:
        out.append('#<void>')


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

def list_to_py(x):
    items = []
    while type(x) is Pair:
        items.append(x.car)
        x = x.cdr
    if x is not NIL:
        raise SchemeError('type-error')
    return items


def py_to_list(items, tail=NIL):
    lst = tail
    for v in reversed(items):
        lst = Pair(v, lst)
    return lst


def call(p, a):
    """Applies procedure p to argument list a, looping on tail calls."""
    while True:
        t = type(p)
        if t is Closure:
            params = p.params
            n = len(params)
            if p.rest is None:
                if len(a) != n:
                    raise SchemeError('arity-error')
                vars = dict(zip(params, a))
            else:
                if len(a) < n:
                    raise SchemeError('arity-error')
                vars = dict(zip(params, a))
                vars[p.rest] = py_to_list(a[n:])
            r = p.body(Env(vars, p.env))
        elif t is Primitive:
            n = len(a)
            if n < p.lo or (p.hi >= 0 and n > p.hi):
                raise SchemeError('arity-error')
            r = p.fn(a)
        else:
            raise SchemeError('type-error')
        if type(r) is not TailCall:
            return r
        p = r.proc
        a = r.args


QUOTE = sym('quote')
S_IF, S_DEFINE, S_SET, S_LAMBDA = sym('if'), sym('define'), sym('set!'), sym('lambda')
S_LET, S_LETSTAR, S_LETREC, S_BEGIN = sym('let'), sym('let*'), sym('letrec'), sym('begin')
S_COND, S_AND, S_OR, S_ELSE = sym('cond'), sym('and'), sym('or'), sym('else')


def comp(x, tail):
    """Compiles form x into a function env -> value (or TailCall when tail)."""
    t = type(x)
    if t is Symbol:
        return comp_ref(x)
    if t is not Pair:
        return lambda env: x
    head = x.car
    if type(head) is Symbol:
        sf = SPECIAL.get(head)
        if sf is not None:
            return sf(x, tail)
    return comp_app(x, tail)


def comp_ref(s):
    def ref(env):
        e = env
        while e is not None:
            v = e.vars.get(s, MISSING)
            if v is not MISSING:
                return v
            e = e.parent
        raise SchemeError('unbound-variable')
    return ref


def comp_app(x, tail):
    f = comp(x.car, False)
    args = [comp(a, False) for a in list_to_py(x.cdr)]
    n = len(args)
    if tail:
        if n == 1:
            a0 = args[0]
            return lambda env: TailCall(f(env), [a0(env)])
        if n == 2:
            a0, a1 = args
            return lambda env: TailCall(f(env), [a0(env), a1(env)])
        return lambda env: TailCall(f(env), [a(env) for a in args])
    if n == 1:
        a0 = args[0]
        return lambda env: call(f(env), [a0(env)])
    if n == 2:
        a0, a1 = args
        return lambda env: call(f(env), [a0(env), a1(env)])
    return lambda env: call(f(env), [a(env) for a in args])


def comp_body(forms, tail):
    """Compiles a non-empty sequence; every form but the last is non-tail."""
    fns = [comp(f, False) for f in forms[:-1]]
    last = comp(forms[-1], tail)
    if not fns:
        return last
    if len(fns) == 1:
        f0 = fns[0]

        def body1(env):
            f0(env)
            return last(env)
        return body1

    def body(env):
        for f in fns:
            f(env)
        return last(env)
    return body


def comp_quote(x, tail):
    datum = x.cdr.car
    return lambda env: datum


def comp_if(x, tail):
    parts = list_to_py(x.cdr)
    test = comp(parts[0], False)
    then = comp(parts[1], tail)
    if len(parts) > 2:
        els = comp(parts[2], tail)
        return lambda env: then(env) if test(env) is not False else els(env)
    return lambda env: then(env) if test(env) is not False else VOID


def parse_params(spec):
    params = []
    while type(spec) is Pair:
        params.append(spec.car)
        spec = spec.cdr
    rest = None if spec is NIL else spec
    return tuple(params), rest


def make_lambda(spec, body_forms):
    params, rest = parse_params(spec)
    body = comp_body(body_forms, True)
    return lambda env: Closure(params, rest, body, env)


def comp_define(x, tail):
    target = x.cdr.car
    if type(target) is Pair:
        name = target.car
        val = make_lambda(target.cdr, list_to_py(x.cdr.cdr))
    else:
        name = target
        val = comp(x.cdr.cdr.car, False)

    def define(env):
        env.vars[name] = val(env)
        return VOID
    return define


def comp_set(x, tail):
    name = x.cdr.car
    val = comp(x.cdr.cdr.car, False)

    def setbang(env):
        v = val(env)
        e = env
        while e is not None:
            if name in e.vars:
                e.vars[name] = v
                return VOID
            e = e.parent
        raise SchemeError('unbound-variable')
    return setbang


def comp_lambda(x, tail):
    return make_lambda(x.cdr.car, list_to_py(x.cdr.cdr))


def comp_begin(x, tail):
    return comp_body(list_to_py(x.cdr), tail)


def parse_bindings(b):
    names, inits = [], []
    for pair in list_to_py(b):
        names.append(pair.car)
        inits.append(pair.cdr.car)
    return names, inits


def comp_let(x, tail):
    if type(x.cdr.car) is Symbol:
        return comp_named_let(x, tail)
    names, inits = parse_bindings(x.cdr.car)
    inits = [comp(i, False) for i in inits]
    body = comp_body(list_to_py(x.cdr.cdr), tail)
    pairs = list(zip(names, inits))

    def let(env):
        return body(Env({n: i(env) for n, i in pairs}, env))
    return let


def comp_named_let(x, tail):
    name = x.cdr.car
    names, inits = parse_bindings(x.cdr.cdr.car)
    inits = [comp(i, False) for i in inits]
    body = comp_body(list_to_py(x.cdr.cdr.cdr), True)
    params = tuple(names)

    def named_let(env):
        args = [i(env) for i in inits]
        loop_env = Env({}, env)
        proc = Closure(params, None, body, loop_env)
        loop_env.vars[name] = proc
        if tail:
            return TailCall(proc, args)
        return call(proc, args)
    return named_let


def comp_letstar(x, tail):
    names, inits = parse_bindings(x.cdr.car)
    inits = [comp(i, False) for i in inits]
    body = comp_body(list_to_py(x.cdr.cdr), tail)
    pairs = list(zip(names, inits))

    def letstar(env):
        for n, i in pairs:
            env = Env({n: i(env)}, env)
        return body(Env({}, env))
    return letstar


def comp_letrec(x, tail):
    names, inits = parse_bindings(x.cdr.car)
    inits = [comp(i, False) for i in inits]
    body = comp_body(list_to_py(x.cdr.cdr), tail)
    pairs = list(zip(names, inits))

    def letrec(env):
        env = Env({}, env)
        for n, i in pairs:
            env.vars[n] = i(env)
        return body(env)
    return letrec


def comp_cond(x, tail):
    clauses = []
    for clause in list_to_py(x.cdr):
        parts = list_to_py(clause)
        if parts[0] is S_ELSE:
            clauses.append((None, comp_body(parts[1:], tail)))
        elif len(parts) == 1:
            clauses.append((comp(parts[0], False), None))
        else:
            clauses.append((comp(parts[0], False), comp_body(parts[1:], tail)))

    def cond(env):
        for test, body in clauses:
            if test is None:
                return body(env)
            v = test(env)
            if v is not False:
                return v if body is None else body(env)
        return VOID
    return cond


def comp_and(x, tail):
    parts = list_to_py(x.cdr)
    if not parts:
        return lambda env: True
    init = [comp(p, False) for p in parts[:-1]]
    last = comp(parts[-1], tail)

    def and_(env):
        for f in init:
            if f(env) is False:
                return False
        return last(env)
    return and_


def comp_or(x, tail):
    parts = list_to_py(x.cdr)
    if not parts:
        return lambda env: False
    init = [comp(p, False) for p in parts[:-1]]
    last = comp(parts[-1], tail)

    def or_(env):
        for f in init:
            v = f(env)
            if v is not False:
                return v
        return last(env)
    return or_


SPECIAL = {
    QUOTE: comp_quote, S_IF: comp_if, S_DEFINE: comp_define, S_SET: comp_set,
    S_LAMBDA: comp_lambda, S_LET: comp_let, S_LETSTAR: comp_letstar,
    S_LETREC: comp_letrec, S_BEGIN: comp_begin, S_COND: comp_cond,
    S_AND: comp_and, S_OR: comp_or,
}


# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

OUT = []


def need_ints(a):
    for v in a:
        if type(v) is not int:
            raise SchemeError('type-error')


def p_add(a):
    need_ints(a)
    return sum(a)


def p_sub(a):
    need_ints(a)
    if len(a) == 1:
        return -a[0]
    r = a[0]
    for v in a[1:]:
        r -= v
    return r


def p_mul(a):
    need_ints(a)
    r = 1
    for v in a:
        r *= v
    return r


def trunc_divmod(a):
    need_ints(a)
    x, y = a
    if y == 0:
        raise SchemeError('division-by-zero')
    q = abs(x) // abs(y)
    if (x < 0) != (y < 0):
        q = -q
    return q, x - y * q


def p_quotient(a):
    return trunc_divmod(a)[0]


def p_remainder(a):
    return trunc_divmod(a)[1]


def make_cmp(op):
    def cmp(a):
        need_ints(a)
        for i in range(len(a) - 1):
            if not op(a[i], a[i + 1]):
                return False
        return True
    return cmp


def p_cons(a):
    return Pair(a[0], a[1])


def p_car(a):
    if type(a[0]) is not Pair:
        raise SchemeError('type-error')
    return a[0].car


def p_cdr(a):
    if type(a[0]) is not Pair:
        raise SchemeError('type-error')
    return a[0].cdr


def is_eq(x, y):
    if type(x) is int and type(y) is int:
        return x == y
    return x is y


def is_equal(x, y):
    while True:
        if type(x) is Pair and type(y) is Pair:
            if not is_equal(x.car, y.car):
                return False
            x, y = x.cdr, y.cdr
            continue
        if type(x) is str and type(y) is str:
            return x == y
        return is_eq(x, y)


def p_apply(a):
    spread = list_to_py(a[-1])
    return TailCall(a[0], a[1:-1] + spread)


def p_string_append(a):
    for v in a:
        if type(v) is not str:
            raise SchemeError('type-error')
    return ''.join(a)


def p_string_length(a):
    if type(a[0]) is not str:
        raise SchemeError('type-error')
    return len(a[0])


def p_number_to_string(a):
    if type(a[0]) is not int:
        raise SchemeError('type-error')
    return str(a[0])


def p_symbol_to_string(a):
    if type(a[0]) is not Symbol:
        raise SchemeError('type-error')
    return a[0].name


def p_display(a):
    OUT.append(write_str(a[0], True))
    return VOID


def p_newline(a):
    OUT.append('\n')
    return VOID


def p_error(a):
    raise SchemeError('user-error')


PRIMITIVES = [
    ('+', p_add, 0, -1),
    ('-', p_sub, 1, -1),
    ('*', p_mul, 0, -1),
    ('quotient', p_quotient, 2, 2),
    ('remainder', p_remainder, 2, 2),
    ('=', make_cmp(lambda x, y: x == y), 2, -1),
    ('<', make_cmp(lambda x, y: x < y), 2, -1),
    ('>', make_cmp(lambda x, y: x > y), 2, -1),
    ('<=', make_cmp(lambda x, y: x <= y), 2, -1),
    ('>=', make_cmp(lambda x, y: x >= y), 2, -1),
    ('cons', p_cons, 2, 2),
    ('car', p_car, 1, 1),
    ('cdr', p_cdr, 1, 1),
    ('list', lambda a: py_to_list(a), 0, -1),
    ('null?', lambda a: a[0] is NIL, 1, 1),
    ('pair?', lambda a: type(a[0]) is Pair, 1, 1),
    ('number?', lambda a: type(a[0]) is int, 1, 1),
    ('symbol?', lambda a: type(a[0]) is Symbol, 1, 1),
    ('string?', lambda a: type(a[0]) is str, 1, 1),
    ('boolean?', lambda a: type(a[0]) is bool, 1, 1),
    ('procedure?', lambda a: type(a[0]) in (Closure, Primitive), 1, 1),
    ('eq?', lambda a: is_eq(a[0], a[1]), 2, 2),
    ('equal?', lambda a: is_equal(a[0], a[1]), 2, 2),
    ('not', lambda a: a[0] is False, 1, 1),
    ('apply', p_apply, 2, -1),
    ('string-append', p_string_append, 0, -1),
    ('string-length', p_string_length, 1, 1),
    ('number->string', p_number_to_string, 1, 1),
    ('symbol->string', p_symbol_to_string, 1, 1),
    ('display', p_display, 1, 1),
    ('newline', p_newline, 0, 0),
    ('error', p_error, 0, -1),
]


def global_env():
    return Env({sym(n): Primitive(n, fn, lo, hi) for n, fn, lo, hi in PRIMITIVES}, None)


def run(src):
    genv = global_env()
    try:
        for form in parse_all(src):
            v = comp(form, False)(genv)
            if v is not VOID:
                OUT.append(write_str(v))
                OUT.append('\n')
    except SchemeError as e:
        OUT.append('error: %s\n' % e.category)
    except RecursionError:
        OUT.append('error: recursion-depth-exceeded\n')


def main():
    src = sys.stdin.read()
    run(src)
    sys.stdout.write(''.join(OUT))
    sys.stdout.flush()


if __name__ == '__main__':
    sys.set_int_max_str_digits(0)
    sys.setrecursionlimit(1_000_000)
    threading.stack_size(512 * 1024 * 1024)
    t = threading.Thread(target=main)
    t.start()
    t.join()
