"""The 132 built-in functions: signatures for the checker, code for the VM."""

import math
import struct

from verrors import Panic
from lexer import lex
from vparser import Parser
from vtypes import TParam, T_UNIT
from items import TyCtx, Module, resolve_type, PRELUDE_OPTION, PRELUDE_RESULT
from values import VChar, UNIT, EnumVal

MASK64 = (1 << 64) - 1
INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1
INF = math.inf
NAN = struct.unpack('<d', struct.pack('<q', 0x7ff8000000000000))[0]
DIGITS36 = '0123456789abcdefghijklmnopqrstuvwxyz'
SPACE_CHARS = ' \t\n\x0b\x0c\r'


def wrap(x):
    x &= MASK64
    return x - (1 << 64) if x >= (1 << 63) else x


def tostr(s):
    """Return an exact `str`, so that a Char never passes for a Str."""
    return s if type(s) is str else '' + s


def some(v):
    return EnumVal(PRELUDE_OPTION, 0, (v,))


NONE_VAL = EnumVal(PRELUDE_OPTION, 1, ())


def none():
    return NONE_VAL


# --- signature parsing -----------------------------------------------------

class _SigProg:
    option = PRELUDE_OPTION
    result = PRELUDE_RESULT


_SIG_MOD = Module('', [], -1)


def parse_sig(text):
    """Parse `<T: Bound, U>(A, B) -> R` into (tparams, ptypes, ret)."""
    p = Parser(lex(text))
    names = []
    if p.at('<'):
        p.take()
        while True:
            n = p.expect('ident')
            bounds = []
            if p.at(':'):
                p.take()
                bounds.append(p.expect('ident').val)
                while p.at('+'):
                    p.take()
                    bounds.append(p.expect('ident').val)
            names.append((n.val, bounds))
            if p.at(','):
                p.take()
                continue
            break
        p.expect_gt()
    p.expect('(')
    past = []
    if not p.at(')'):
        while True:
            if p.at('ident') and p.peek_kind() == ':':
                p.take()
                p.take()
            past.append(p.parse_type())
            if p.at(','):
                p.take()
                continue
            break
    p.expect(')')
    rast = None
    if p.at('->'):
        p.take()
        rast = p.parse_type()
    params = {}
    order = []
    for name, bounds in names:
        tp = TParam(name, bounds)
        params[name] = tp
        order.append(tp)
    ctx = TyCtx(_SigProg, _SIG_MOD, params, None)
    ptypes = [resolve_type(ctx, a) for a in past]
    ret = resolve_type(ctx, rast) if rast is not None else T_UNIT
    return order, ptypes, ret


# --- number formatting -----------------------------------------------------

def show_float_at(x, d):
    if d < 0 or d > 17:
        raise Panic('digits out of range')
    if x != x:
        return 'nan'
    if x == INF:
        return 'inf'
    if x == -INF:
        return '-inf'
    return '%.*f' % (d, x)


def show_int_radix(x, radix):
    if radix < 2 or radix > 36:
        raise Panic('radix out of range')
    neg = x < 0
    n = -x if neg else x
    if n == 0:
        return '0'
    out = []
    while n:
        out.append(DIGITS36[n % radix])
        n //= radix
    if neg:
        out.append('-')
    return ''.join(reversed(out))


def parse_int_radix(s, radix):
    i = 0
    n = len(s)
    neg = False
    if i < n and (s[i] == '+' or s[i] == '-'):
        neg = s[i] == '-'
        i += 1
    if i >= n:
        return none()
    value = 0
    while i < n:
        c = s[i]
        d = DIGITS36.find(c.lower()) if c.isascii() and c.isalnum() else -1
        if d < 0 or d >= radix:
            return none()
        value = value * radix + d
        i += 1
    if neg:
        value = -value
    if value < INT_MIN or value > INT_MAX:
        return none()
    return some(value)


def parse_float_str(s):
    """Validate the exact grammar of `parseFloat` and convert."""
    i = 0
    n = len(s)
    if i < n and (s[i] == '+' or s[i] == '-'):
        i += 1
    digits = 0
    while i < n and s[i].isascii() and s[i].isdigit():
        i += 1
        digits += 1
    if digits:
        if i < n and s[i] == '.':
            i += 1
            while i < n and s[i].isascii() and s[i].isdigit():
                i += 1
    else:
        if i >= n or s[i] != '.':
            return None
        i += 1
        frac = 0
        while i < n and s[i].isascii() and s[i].isdigit():
            i += 1
            frac += 1
        if not frac:
            return None
    if i < n and (s[i] == 'e' or s[i] == 'E'):
        i += 1
        if i < n and (s[i] == '+' or s[i] == '-'):
            i += 1
        ed = 0
        while i < n and s[i].isascii() and s[i].isdigit():
            i += 1
            ed += 1
        if not ed:
            return None
    if i != n:
        return None
    try:
        return float(s)
    except (ValueError, OverflowError):
        return None


def fdiv(a, b):
    if b == 0.0:
        if a != a:
            return a
        if a == 0.0:
            return NAN
        s = math.copysign(1.0, a) * math.copysign(1.0, b)
        return INF if s > 0 else -INF
    return a / b


def ffloor(x):
    if x != x or x == INF or x == -INF or x == 0.0:
        return x
    r = float(math.floor(x))
    return r if r != 0.0 else math.copysign(0.0, x)


def fceil(x):
    if x != x or x == INF or x == -INF or x == 0.0:
        return x
    r = float(math.ceil(x))
    return r if r != 0.0 else math.copysign(0.0, x)


def ftrunc(x):
    if x != x or x == INF or x == -INF or x == 0.0:
        return x
    r = float(math.trunc(x))
    return r if r != 0.0 else math.copysign(0.0, x)


def fround(x):
    if x != x or x == INF or x == -INF or x == 0.0:
        return x
    num, den = abs(x).as_integer_ratio()
    q = (2 * num + den) // (2 * den)
    return math.copysign(float(q), x)


def fsqrt(x):
    if x != x:
        return x
    if x == 0.0:
        return x
    if x < 0.0:
        return NAN
    return math.sqrt(x)


def ffmod(a, b):
    if a != a or b != b:
        return NAN
    if a == INF or a == -INF or b == 0.0:
        return NAN
    if b == INF or b == -INF:
        return a
    return math.fmod(a, b)


def fcmp(a, b):
    an = a != a
    bn = b != b
    if an or bn:
        if an and bn:
            return 0
        return 1 if an else -1
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


def powf(x, n):
    if n < 0:
        if n == INT_MIN:
            raise Panic('negative exponent')
        return fdiv(1.0, powf(x, -n))
    r = 1.0
    b = x
    k = n
    while k > 0:
        if k & 1:
            r = r * b
        k >>= 1
        if k > 0:
            b = b * b
    return r


def escape_scalar(c, quote):
    o = ord(c)
    if c == '\\':
        return '\\\\'
    if c == quote:
        return '\\' + c
    if o == 10:
        return '\\n'
    if o == 13:
        return '\\r'
    if o == 9:
        return '\\t'
    if o < 0x20 or o == 0x7F:
        return '\\u{%x}' % o
    return c


def fmt_str(template, args):
    out = []
    used = 0
    i = 0
    n = len(template)
    while i < n:
        c = template[i]
        if c == '{':
            if i + 1 >= n:
                raise Panic('bad format')
            d = template[i + 1]
            if d == '{':
                out.append('{')
                i += 2
            elif d == '}':
                if used < len(args):
                    out.append(args[used])
                used += 1
                i += 2
            else:
                raise Panic('bad format')
        elif c == '}':
            if i + 1 >= n or template[i + 1] != '}':
                raise Panic('bad format')
            out.append('}')
            i += 2
        else:
            out.append(c)
            i += 1
    if used != len(args):
        raise Panic('bad format')
    return ''.join(out)


def merge_sort(vm, src, cmp):
    n = len(src)
    if n <= 1:
        return src
    dst = [None] * n
    width = 1
    while width < n:
        i = 0
        while i < n:
            lo = i
            mid = min(i + width, n)
            hi = min(i + 2 * width, n)
            a = lo
            b = mid
            k = lo
            while a < mid and b < hi:
                if vm.invoke(cmp, [src[a], src[b]]) <= 0:
                    dst[k] = src[a]
                    a += 1
                else:
                    dst[k] = src[b]
                    b += 1
                k += 1
            while a < mid:
                dst[k] = src[a]
                a += 1
                k += 1
            while b < hi:
                dst[k] = src[b]
                b += 1
                k += 1
            i += 2 * width
        src, dst = dst, src
        width *= 2
    return src


def check_index(i, n):
    if i < 0 or i >= n:
        raise Panic('index out of bounds')


# --- the table -------------------------------------------------------------

BUILTINS = []           # (name, tparams, ptypes, ret, fn)
BUILTIN_INDEX = {}      # name -> index


def bi(name, sig, fn):
    order, ptypes, ret = parse_sig(sig)
    BUILTIN_INDEX[name] = len(BUILTINS)
    BUILTINS.append((name, order, ptypes, ret, fn))


def _register():
    from values import vals_equal

    # 15.1 output and panicking
    def f_print(vm, a):
        vm.out.append(a[0])
        vm.out.append('\n')
        return UNIT
    bi('print', '(s: Str)', f_print)

    def f_emit(vm, a):
        vm.out.append(a[0])
        return UNIT
    bi('emit', '(s: Str)', f_emit)

    def f_panic(vm, a):
        raise Panic(a[0])
    bi('panic', '(msg: Str)', f_panic)

    # 15.2 integers
    bi('intMin', '() -> Int', lambda vm, a: INT_MIN)
    bi('intMax', '() -> Int', lambda vm, a: INT_MAX)
    bi('absI', '(x: Int) -> Int', lambda vm, a: wrap(abs(a[0])))
    bi('minI', '(a: Int, b: Int) -> Int',
       lambda vm, a: a[0] if a[0] <= a[1] else a[1])
    bi('maxI', '(a: Int, b: Int) -> Int',
       lambda vm, a: a[0] if a[0] >= a[1] else a[1])
    bi('signI', '(x: Int) -> Int',
       lambda vm, a: -1 if a[0] < 0 else (1 if a[0] > 0 else 0))
    bi('cmpI', '(a: Int, b: Int) -> Int',
       lambda vm, a: -1 if a[0] < a[1] else (1 if a[0] > a[1] else 0))

    def f_divfloor(vm, a):
        if a[1] == 0:
            raise Panic('divide by zero')
        return wrap(a[0] // a[1])
    bi('divFloor', '(a: Int, b: Int) -> Int', f_divfloor)

    def f_modfloor(vm, a):
        if a[1] == 0:
            raise Panic('modulo by zero')
        return wrap(a[0] - wrap(a[0] // a[1]) * a[1])
    bi('modFloor', '(a: Int, b: Int) -> Int', f_modfloor)

    def f_powi(vm, a):
        if a[1] < 0:
            raise Panic('negative exponent')
        return wrap(pow(a[0] & MASK64, a[1], 1 << 64))
    bi('powI', '(base: Int, exp: Int) -> Int', f_powi)

    bi('gcdI', '(a: Int, b: Int) -> Int',
       lambda vm, a: wrap(math.gcd(abs(a[0]), abs(a[1]))))
    bi('popCount', '(x: Int) -> Int',
       lambda vm, a: bin(a[0] & MASK64).count('1'))

    def f_clz(vm, a):
        v = a[0] & MASK64
        return 64 - v.bit_length()
    bi('clz', '(x: Int) -> Int', f_clz)

    def f_ctz(vm, a):
        v = a[0] & MASK64
        if v == 0:
            return 64
        return (v & -v).bit_length() - 1
    bi('ctz', '(x: Int) -> Int', f_ctz)

    bi('toFloat', '(x: Int) -> Float', lambda vm, a: float(a[0]))
    bi('showInt', '(x: Int) -> Str', lambda vm, a: str(a[0]))
    bi('showIntRadix', '(x: Int, radix: Int) -> Str',
       lambda vm, a: show_int_radix(a[0], a[1]))
    bi('parseInt', '(s: Str) -> Option<Int>',
       lambda vm, a: parse_int_radix(a[0], 10))

    def f_parseintradix(vm, a):
        if a[1] < 2 or a[1] > 36:
            raise Panic('radix out of range')
        return parse_int_radix(a[0], a[1])
    bi('parseIntRadix', '(s: Str, radix: Int) -> Option<Int>', f_parseintradix)

    # 15.3 floats
    bi('sqrtF', '(x: Float) -> Float', lambda vm, a: fsqrt(a[0]))
    bi('absF', '(x: Float) -> Float', lambda vm, a: math.copysign(a[0], 1.0))
    bi('floorF', '(x: Float) -> Float', lambda vm, a: ffloor(a[0]))
    bi('ceilF', '(x: Float) -> Float', lambda vm, a: fceil(a[0]))
    bi('truncF', '(x: Float) -> Float', lambda vm, a: ftrunc(a[0]))
    bi('roundF', '(x: Float) -> Float', lambda vm, a: fround(a[0]))
    bi('minF', '(a: Float, b: Float) -> Float',
       lambda vm, a: a[0] if fcmp(a[0], a[1]) <= 0 else a[1])
    bi('maxF', '(a: Float, b: Float) -> Float',
       lambda vm, a: a[0] if fcmp(a[0], a[1]) >= 0 else a[1])
    bi('fmodF', '(a: Float, b: Float) -> Float',
       lambda vm, a: ffmod(a[0], a[1]))
    bi('powF', '(x: Float, n: Int) -> Float', lambda vm, a: powf(a[0], a[1]))
    bi('isNanF', '(x: Float) -> Bool', lambda vm, a: a[0] != a[0])
    bi('isInfF', '(x: Float) -> Bool',
       lambda vm, a: a[0] == INF or a[0] == -INF)
    bi('cmpF', '(a: Float, b: Float) -> Int', lambda vm, a: fcmp(a[0], a[1]))

    def f_trunctoint(vm, a):
        x = a[0]
        if x != x or x == INF or x == -INF:
            raise Panic('float out of integer range')
        t = math.trunc(x)
        if t < INT_MIN or t > INT_MAX:
            raise Panic('float out of integer range')
        return t
    bi('truncToInt', '(x: Float) -> Int', f_trunctoint)

    bi('showFloat', '(x: Float) -> Str', lambda vm, a: show_float_at(a[0], 6))
    bi('showFloatAt', '(x: Float, digits: Int) -> Str',
       lambda vm, a: show_float_at(a[0], a[1]))
    bi('floatBits', '(x: Float) -> Int',
       lambda vm, a: struct.unpack('<q', struct.pack('<d', a[0]))[0])
    bi('floatFromBits', '(bits: Int) -> Float',
       lambda vm, a: struct.unpack('<d', struct.pack('<q', a[0]))[0])

    def f_parsefloat(vm, a):
        v = parse_float_str(a[0])
        return none() if v is None else some(v)
    bi('parseFloat', '(s: Str) -> Option<Float>', f_parsefloat)

    bi('infF', '() -> Float', lambda vm, a: INF)
    bi('nanF', '() -> Float', lambda vm, a: NAN)
    bi('piF', '() -> Float',
       lambda vm, a: struct.unpack('<d', struct.pack('<q',
                                                     4614256656552045848))[0])

    # 15.4 bools and chars
    bi('showBool', '(b: Bool) -> Str', lambda vm, a: 'true' if a[0] else 'false')
    bi('ord', '(c: Char) -> Int', lambda vm, a: ord(a[0]))

    def f_chr(vm, a):
        n = a[0]
        if n < 0 or n > 0x10FFFF or 0xD800 <= n <= 0xDFFF:
            raise Panic('invalid char code')
        return VChar(chr(n))
    bi('chr', '(n: Int) -> Char', f_chr)

    bi('isDigit', '(c: Char) -> Bool', lambda vm, a: '0' <= a[0] <= '9')
    bi('isAlpha', '(c: Char) -> Bool',
       lambda vm, a: 'a' <= a[0] <= 'z' or 'A' <= a[0] <= 'Z')
    bi('isAlnum', '(c: Char) -> Bool',
       lambda vm, a: ('0' <= a[0] <= '9' or 'a' <= a[0] <= 'z'
                      or 'A' <= a[0] <= 'Z'))
    bi('isSpace', '(c: Char) -> Bool', lambda vm, a: a[0] in SPACE_CHARS)
    bi('isUpper', '(c: Char) -> Bool', lambda vm, a: 'A' <= a[0] <= 'Z')
    bi('isLower', '(c: Char) -> Bool', lambda vm, a: 'a' <= a[0] <= 'z')
    bi('toUpperC', '(c: Char) -> Char',
       lambda vm, a: VChar(chr(ord(a[0]) - 32)) if 'a' <= a[0] <= 'z' else a[0])
    bi('toLowerC', '(c: Char) -> Char',
       lambda vm, a: VChar(chr(ord(a[0]) + 32)) if 'A' <= a[0] <= 'Z' else a[0])
    bi('cmpC', '(a: Char, b: Char) -> Int',
       lambda vm, a: -1 if a[0] < a[1] else (1 if a[0] > a[1] else 0))
    bi('showChar', '(c: Char) -> Str', lambda vm, a: tostr(a[0]))
    bi('quoteChar', '(c: Char) -> Str',
       lambda vm, a: "'" + escape_scalar(tostr(a[0]), "'") + "'")

    # 15.5 strings
    bi('strLen', '(s: Str) -> Int', lambda vm, a: len(a[0]))

    def f_charat(vm, a):
        check_index(a[1], len(a[0]))
        return VChar(a[0][a[1]])
    bi('charAt', '(s: Str, i: Int) -> Char', f_charat)

    def f_substr(vm, a):
        s, f, t = a
        if f < 0 or f > t or t > len(s):
            raise Panic('index out of bounds')
        return s[f:t]
    bi('substr', '(s: Str, from: Int, to: Int) -> Str', f_substr)

    bi('strCat', '(a: Str, b: Str) -> Str', lambda vm, a: a[0] + a[1])

    def f_strrepeat(vm, a):
        if a[1] < 0:
            raise Panic('negative count')
        return a[0] * a[1]
    bi('strRepeat', '(s: Str, n: Int) -> Str', f_strrepeat)

    bi('strIndexOf', '(s: Str, sub: Str) -> Int',
       lambda vm, a: a[0].find(a[1]))
    bi('strLastIndexOf', '(s: Str, sub: Str) -> Int',
       lambda vm, a: a[0].rfind(a[1]))
    bi('strContains', '(s: Str, sub: Str) -> Bool',
       lambda vm, a: a[1] in a[0])
    bi('startsWith', '(s: Str, p: Str) -> Bool',
       lambda vm, a: a[0].startswith(a[1]))
    bi('endsWith', '(s: Str, p: Str) -> Bool',
       lambda vm, a: a[0].endswith(a[1]))

    def f_strsplit(vm, a):
        if a[1] == '':
            raise Panic('empty separator')
        return a[0].split(a[1])
    bi('strSplit', '(s: Str, sep: Str) -> [Str]', f_strsplit)

    bi('strJoin', '(parts: [Str], sep: Str) -> Str',
       lambda vm, a: a[1].join(a[0]))

    def f_strreplace(vm, a):
        if a[1] == '':
            raise Panic('empty separator')
        return a[0].replace(a[1], a[2])
    bi('strReplace', '(s: Str, from: Str, to: Str) -> Str', f_strreplace)

    bi('trim', '(s: Str) -> Str', lambda vm, a: a[0].strip(SPACE_CHARS))
    bi('trimLeft', '(s: Str) -> Str', lambda vm, a: a[0].lstrip(SPACE_CHARS))
    bi('trimRight', '(s: Str) -> Str', lambda vm, a: a[0].rstrip(SPACE_CHARS))

    def f_upper(vm, a):
        return ''.join(chr(ord(c) - 32) if 'a' <= c <= 'z' else c
                       for c in a[0])
    bi('upper', '(s: Str) -> Str', f_upper)

    def f_lower(vm, a):
        return ''.join(chr(ord(c) + 32) if 'A' <= c <= 'Z' else c
                       for c in a[0])
    bi('lower', '(s: Str) -> Str', f_lower)

    bi('strCmp', '(a: Str, b: Str) -> Int',
       lambda vm, a: -1 if a[0] < a[1] else (1 if a[0] > a[1] else 0))
    bi('chars', '(s: Str) -> [Char]',
       lambda vm, a: [VChar(c) for c in a[0]])
    bi('strOfChars', '(cs: [Char]) -> Str',
       lambda vm, a: tostr(''.join(a[0])))
    bi('strReverse', '(s: Str) -> Str', lambda vm, a: a[0][::-1])
    bi('quoteStr', '(s: Str) -> Str',
       lambda vm, a: '"' + ''.join(escape_scalar(c, '"') for c in a[0]) + '"')

    def f_padleft(vm, a):
        s, w, c = a
        if w < 0:
            raise Panic('negative count')
        if len(s) >= w:
            return s
        return tostr(c) * (w - len(s)) + s
    bi('padLeft', '(s: Str, width: Int, c: Char) -> Str', f_padleft)

    def f_padright(vm, a):
        s, w, c = a
        if w < 0:
            raise Panic('negative count')
        if len(s) >= w:
            return s
        return s + tostr(c) * (w - len(s))
    bi('padRight', '(s: Str, width: Int, c: Char) -> Str', f_padright)

    # 15.6 lists
    bi('listNew', '<T>() -> [T]', lambda vm, a: [])
    bi('listLen', '<T>(xs: [T]) -> Int', lambda vm, a: len(a[0]))

    def f_push(vm, a):
        a[0].append(a[1])
        return UNIT
    bi('push', '<T>(xs: [T], x: T)', f_push)

    def f_pop(vm, a):
        if not a[0]:
            raise Panic('empty list')
        return a[0].pop()
    bi('pop', '<T>(xs: [T]) -> T', f_pop)

    def f_insert(vm, a):
        xs, i, x = a
        if i < 0 or i > len(xs):
            raise Panic('index out of bounds')
        xs.insert(i, x)
        return UNIT
    bi('insert', '<T>(xs: [T], i: Int, x: T)', f_insert)

    def f_removeat(vm, a):
        xs, i = a
        check_index(i, len(xs))
        return xs.pop(i)
    bi('removeAt', '<T>(xs: [T], i: Int) -> T', f_removeat)

    def f_clear(vm, a):
        del a[0][:]
        return UNIT
    bi('clear', '<T>(xs: [T])', f_clear)

    def f_listrepeat(vm, a):
        if a[1] < 0:
            raise Panic('negative count')
        return [a[0]] * a[1]
    bi('listRepeat', '<T>(x: T, n: Int) -> [T]', f_listrepeat)

    bi('listConcat', '<T>(a: [T], b: [T]) -> [T]', lambda vm, a: a[0] + a[1])

    def f_slice(vm, a):
        xs, f, t = a
        if f < 0 or f > t or t > len(xs):
            raise Panic('index out of bounds')
        return xs[f:t]
    bi('slice', '<T>(xs: [T], from: Int, to: Int) -> [T]', f_slice)

    bi('listCopy', '<T>(xs: [T]) -> [T]', lambda vm, a: list(a[0]))
    bi('reverseList', '<T>(xs: [T]) -> [T]', lambda vm, a: a[0][::-1])

    def f_listfirst(vm, a):
        if not a[0]:
            raise Panic('empty list')
        return a[0][0]
    bi('listFirst', '<T>(xs: [T]) -> T', f_listfirst)

    def f_listlast(vm, a):
        if not a[0]:
            raise Panic('empty list')
        return a[0][-1]
    bi('listLast', '<T>(xs: [T]) -> T', f_listlast)

    def f_listmap(vm, a):
        xs, f = a
        out = []
        i = 0
        while i < len(xs):
            out.append(vm.invoke(f, [xs[i]]))
            i += 1
        return out
    bi('listMap', '<T, U>(xs: [T], f: fn(T) -> U) -> [U]', f_listmap)

    def f_listfilter(vm, a):
        xs, f = a
        out = []
        i = 0
        while i < len(xs):
            x = xs[i]
            if vm.invoke(f, [x]):
                out.append(x)
            i += 1
        return out
    bi('listFilter', '<T>(xs: [T], f: fn(T) -> Bool) -> [T]', f_listfilter)

    def f_listfold(vm, a):
        xs, acc, f = a
        i = 0
        while i < len(xs):
            acc = vm.invoke(f, [acc, xs[i]])
            i += 1
        return acc
    bi('listFold', '<T, A>(xs: [T], init: A, f: fn(A, T) -> A) -> A',
       f_listfold)

    def f_listany(vm, a):
        xs, f = a
        i = 0
        while i < len(xs):
            if vm.invoke(f, [xs[i]]):
                return True
            i += 1
        return False
    bi('listAny', '<T>(xs: [T], f: fn(T) -> Bool) -> Bool', f_listany)

    def f_listall(vm, a):
        xs, f = a
        i = 0
        while i < len(xs):
            if not vm.invoke(f, [xs[i]]):
                return False
            i += 1
        return True
    bi('listAll', '<T>(xs: [T], f: fn(T) -> Bool) -> Bool', f_listall)

    def f_listfind(vm, a):
        xs, f = a
        i = 0
        while i < len(xs):
            x = xs[i]
            if vm.invoke(f, [x]):
                return some(x)
            i += 1
        return none()
    bi('listFind', '<T>(xs: [T], f: fn(T) -> Bool) -> Option<T>', f_listfind)

    def f_listfindindex(vm, a):
        xs, f = a
        i = 0
        while i < len(xs):
            if vm.invoke(f, [xs[i]]):
                return i
            i += 1
        return -1
    bi('listFindIndex', '<T>(xs: [T], f: fn(T) -> Bool) -> Int',
       f_listfindindex)

    def f_listindexof(vm, a):
        xs, x = a
        i = 0
        while i < len(xs):
            if vals_equal(xs[i], x):
                return i
            i += 1
        return -1
    bi('listIndexOf', '<T: Eq>(xs: [T], x: T) -> Int', f_listindexof)

    def f_listcontains(vm, a):
        return f_listindexof(vm, a) >= 0
    bi('listContains', '<T: Eq>(xs: [T], x: T) -> Bool', f_listcontains)

    def f_listzip(vm, a):
        xs, ys = a
        n = min(len(xs), len(ys))
        return [(xs[i], ys[i]) for i in range(n)]
    bi('listZip', '<A, B>(a: [A], b: [B]) -> [(A, B)]', f_listzip)

    def f_listflatten(vm, a):
        out = []
        for inner in a[0]:
            out.extend(inner)
        return out
    bi('listFlatten', '<T>(xss: [[T]]) -> [T]', f_listflatten)

    def f_sortby(vm, a):
        return merge_sort(vm, list(a[0]), a[1])
    bi('sortBy', '<T>(xs: [T], cmp: fn(T, T) -> Int) -> [T]', f_sortby)

    # 15.7 maps
    bi('mapNew', '<K: Key, V>() -> #[K: V]', lambda vm, a: {})
    bi('mapLen', '<K: Key, V>(m: #[K: V]) -> Int', lambda vm, a: len(a[0]))
    bi('mapHas', '<K: Key, V>(m: #[K: V], k: K) -> Bool',
       lambda vm, a: a[1] in a[0])

    def f_mapget(vm, a):
        m, k = a
        if k in m:
            return some(m[k])
        return none()
    bi('mapGet', '<K: Key, V>(m: #[K: V], k: K) -> Option<V>', f_mapget)

    bi('mapGetOr', '<K: Key, V>(m: #[K: V], k: K, dflt: V) -> V',
       lambda vm, a: a[0][a[1]] if a[1] in a[0] else a[2])

    def f_mapset(vm, a):
        a[0][a[1]] = a[2]
        return UNIT
    bi('mapSet', '<K: Key, V>(m: #[K: V], k: K, v: V)', f_mapset)

    def f_mapdel(vm, a):
        m, k = a
        if k in m:
            del m[k]
            return True
        return False
    bi('mapDel', '<K: Key, V>(m: #[K: V], k: K) -> Bool', f_mapdel)

    bi('keysOf', '<K: Key, V>(m: #[K: V]) -> [K]',
       lambda vm, a: list(a[0].keys()))
    bi('valuesOf', '<K: Key, V>(m: #[K: V]) -> [V]',
       lambda vm, a: list(a[0].values()))
    bi('pairsOf', '<K: Key, V>(m: #[K: V]) -> [(K, V)]',
       lambda vm, a: [(k, v) for k, v in a[0].items()])

    def f_mapclear(vm, a):
        a[0].clear()
        return UNIT
    bi('mapClear', '<K: Key, V>(m: #[K: V])', f_mapclear)

    bi('mapCopy', '<K: Key, V>(m: #[K: V]) -> #[K: V]',
       lambda vm, a: dict(a[0]))

    # 15.8 Option, Result and tuples
    bi('isSome', '<T>(o: Option<T>) -> Bool', lambda vm, a: a[0].variant == 0)
    bi('isNone', '<T>(o: Option<T>) -> Bool', lambda vm, a: a[0].variant == 1)

    def f_unwrap(vm, a):
        if a[0].variant != 0:
            raise Panic('unwrap of None')
        return a[0].payload[0]
    bi('unwrap', '<T>(o: Option<T>) -> T', f_unwrap)

    bi('unwrapOr', '<T>(o: Option<T>, dflt: T) -> T',
       lambda vm, a: a[0].payload[0] if a[0].variant == 0 else a[1])
    bi('isOk', '<T, E>(r: Result<T, E>) -> Bool',
       lambda vm, a: a[0].variant == 0)
    bi('isErr', '<T, E>(r: Result<T, E>) -> Bool',
       lambda vm, a: a[0].variant == 1)

    def f_unwrapok(vm, a):
        if a[0].variant != 0:
            raise Panic('unwrap of Err')
        return a[0].payload[0]
    bi('unwrapOk', '<T, E>(r: Result<T, E>) -> T', f_unwrapok)

    def f_unwraperr(vm, a):
        if a[0].variant != 1:
            raise Panic('unwrap of Ok')
        return a[0].payload[0]
    bi('unwrapErr', '<T, E>(r: Result<T, E>) -> E', f_unwraperr)

    bi('fst', '<A, B>(t: (A, B)) -> A', lambda vm, a: a[0][0])
    bi('snd', '<A, B>(t: (A, B)) -> B', lambda vm, a: a[0][1])

    # 15.9 formatting
    bi('fmt', '(template: Str, args: [Str]) -> Str',
       lambda vm, a: fmt_str(a[0], a[1]))


_register()

BUILTIN_SIGS = {name: (tps, ps, r) for name, tps, ps, r, _f in BUILTINS}
BUILTIN_FNS = [f for _n, _t, _p, _r, f in BUILTINS]
BUILTIN_NAMES = [n for n, _t, _p, _r, _f in BUILTINS]
