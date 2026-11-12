"""The 132 built-in functions (SPEC section 15).

``make_builtins(vm)`` returns a list indexed by built-in id (see
:data:`langvm.prelude.BUILTIN_ID`).  Built-ins that call back into Vellum code
(``listMap``, ``sortBy``, ...) use ``vm.call``.
"""

from __future__ import annotations

import math
import re
import struct

from .diagnostics import Panic
from .floatfmt import show_float_at
from .prelude import BUILTIN_NAMES
from .program import ERR_UID, NONE_UID, OK_UID, SOME_UID
from .values import Char, veq

M64 = (1 << 64) - 1
B63 = 1 << 63
IMIN = -B63
IMAX = B63 - 1
NONE = (NONE_UID,)

_INT_RE = re.compile(r"[+-]?[0-9]+\Z")
_FLOAT_RE = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z")
_SPACE = " \t\n\v\f\r"
_UPPER = {c: c - 32 for c in range(97, 123)}
_LOWER = {c: c + 32 for c in range(65, 91)}
_DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"


def wrap(x: int) -> int:
    """Wrap a Python int to the signed 64-bit range."""
    return ((x + B63) & M64) - B63


def some(x):
    return (SOME_UID, x)


# ----------------------------------------------------------------- integers
def abs_i(x):
    return x if x >= 0 else wrap(-x)


def div_floor(a, b):
    if b == 0:
        raise Panic("divide by zero")
    return wrap(a // b)


def mod_floor(a, b):
    if b == 0:
        raise Panic("modulo by zero")
    return a % b


def pow_i(base, exp):
    if exp < 0:
        raise Panic("negative exponent")
    return wrap(pow(base, exp, 1 << 64))


def gcd_i(a, b):
    return wrap(math.gcd(a, b))


def pop_count(x):
    return (x & M64).bit_count()


def clz(x):
    return 64 - (x & M64).bit_length()


def ctz(x):
    m = x & M64
    if m == 0:
        return 64
    return (m & -m).bit_length() - 1


def show_int_radix(x, radix):
    if radix < 2 or radix > 36:
        raise Panic("radix out of range")
    if x == 0:
        return "0"
    n = abs(x)
    out = []
    while n:
        n, r = divmod(n, radix)
        out.append(_DIGITS[r])
    if x < 0:
        out.append("-")
    return "".join(reversed(out))


def parse_int(s):
    if not _INT_RE.match(s):
        return NONE
    digits = s.lstrip("+-").lstrip("0")
    if len(digits) > 19:
        return NONE
    v = int(s)
    if IMIN <= v <= IMAX:
        return (SOME_UID, v)
    return NONE


def parse_int_radix(s, radix):
    if radix < 2 or radix > 36:
        raise Panic("radix out of range")
    i = 0
    neg = False
    if s[:1] in ("+", "-"):
        neg = s[0] == "-"
        i = 1
    body = s[i:]
    if not body:
        return NONE
    v = 0
    for ch in body:
        d = _DIGITS.find(ch.lower()) if ch.isascii() else -1
        if d < 0 or d >= radix:
            return NONE
        v = v * radix + d
        if v > (1 << 70):
            return NONE
    if neg:
        v = -v
    if IMIN <= v <= IMAX:
        return (SOME_UID, v)
    return NONE


# ------------------------------------------------------------------- floats
def sqrt_f(x):
    if x < 0:
        return math.nan
    return math.sqrt(x)


def _round_to(x, mode):
    if x != x or x in (math.inf, -math.inf) or x == 0 or abs(x) >= 4503599627370496.0:
        return x
    if mode == 0:
        r = float(math.floor(x))
    elif mode == 1:
        r = float(math.ceil(x))
    elif mode == 2:
        r = float(math.trunc(x))
    else:
        ax = abs(x)
        f = math.floor(ax)
        r = float(f + 1 if ax - f >= 0.5 else f)
        r = math.copysign(r, x)
    if r == 0:
        return math.copysign(0.0, x)
    return r


def floor_f(x):
    return _round_to(x, 0)


def ceil_f(x):
    return _round_to(x, 1)


def trunc_f(x):
    return _round_to(x, 2)


def round_f(x):
    return _round_to(x, 3)


def cmp_f(a, b):
    if a < b:
        return -1
    if a > b:
        return 1
    if a == b:
        return 0
    an = a != a
    bn = b != b
    if an and bn:
        return 0
    return 1 if an else -1


def min_f(a, b):
    return a if cmp_f(a, b) <= 0 else b


def max_f(a, b):
    return a if cmp_f(a, b) >= 0 else b


def fmod_f(a, b):
    try:
        return math.fmod(a, b)
    except ValueError:
        return math.nan


def fdiv(a, b):
    """IEEE division without Python's ZeroDivisionError."""
    try:
        return a / b
    except ZeroDivisionError:
        if a != a or a == 0:
            return math.nan
        neg = (math.copysign(1.0, a) < 0) != (math.copysign(1.0, b) < 0)
        return -math.inf if neg else math.inf


def pow_f(x, n):
    if n < 0:
        if n == IMIN:
            raise Panic("negative exponent")
        return fdiv(1.0, pow_f(x, -n))
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


def trunc_to_int(x):
    if x != x or x in (math.inf, -math.inf):
        raise Panic("float out of integer range")
    v = int(x)
    if v < IMIN or v > IMAX:
        raise Panic("float out of integer range")
    return v


def show_float_at_(x, d):
    if d < 0 or d > 17:
        raise Panic("digits out of range")
    return show_float_at(x, d)


def float_bits(x):
    return struct.unpack("<q", struct.pack("<d", x))[0]


def float_from_bits(b):
    return struct.unpack("<d", struct.pack("<q", b))[0]


def parse_float(s):
    if not _FLOAT_RE.match(s):
        return NONE
    try:
        return (SOME_UID, float(s))
    except (ValueError, OverflowError):  # pragma: no cover - defensive
        return NONE


# -------------------------------------------------------------- chars / str
def chr_(n):
    if n < 0 or n > 0x10FFFF or 0xD800 <= n <= 0xDFFF:
        raise Panic("invalid char code")
    return Char(chr(n))


def is_digit(c):
    return "0" <= c <= "9"


def is_alpha(c):
    return "a" <= c <= "z" or "A" <= c <= "Z"


def is_alnum(c):
    return "0" <= c <= "9" or "a" <= c <= "z" or "A" <= c <= "Z"


def is_space(c):
    return c in _SPACE


def to_upper_c(c):
    return Char(chr(ord(c) - 32)) if "a" <= c <= "z" else c


def to_lower_c(c):
    return Char(chr(ord(c) + 32)) if "A" <= c <= "Z" else c


def cmp_c(a, b):
    return -1 if a < b else (1 if a > b else 0)


def _escape(s, quote):
    out = []
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == quote:
            out.append("\\" + quote)
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif o < 0x20 or o == 0x7F:
            out.append("\\u{%x}" % o)
        else:
            out.append(ch)
    return "".join(out)


def quote_char(c):
    return "'" + _escape(c, "'") + "'"


def quote_str(s):
    return '"' + _escape(s, '"') + '"'


def char_at(s, i):
    if i < 0 or i >= len(s):
        raise Panic("index out of bounds")
    return Char(s[i])


def substr(s, a, b):
    if a < 0 or a > b or b > len(s):
        raise Panic("index out of bounds")
    return s[a:b]


def str_repeat(s, n):
    if n < 0:
        raise Panic("negative count")
    return s * n


def str_split(s, sep):
    if sep == "":
        raise Panic("empty separator")
    return s.split(sep)


def str_replace(s, a, b):
    if a == "":
        raise Panic("empty separator")
    return s.replace(a, b)


def str_cmp(a, b):
    return -1 if a < b else (1 if a > b else 0)


def pad_left(s, width, c):
    if width < 0:
        raise Panic("negative count")
    n = width - len(s)
    return s if n <= 0 else str(c) * n + s


def pad_right(s, width, c):
    if width < 0:
        raise Panic("negative count")
    n = width - len(s)
    return s if n <= 0 else s + str(c) * n


def fmt(template, args):
    out = []
    i = 0
    n = len(template)
    used = 0
    while i < n:
        c = template[i]
        if c == "{":
            if i + 1 >= n:
                raise Panic("bad format")
            d = template[i + 1]
            if d == "{":
                out.append("{")
            elif d == "}":
                if used < len(args):
                    out.append(args[used])
                used += 1
            else:
                raise Panic("bad format")
            i += 2
        elif c == "}":
            if i + 1 < n and template[i + 1] == "}":
                out.append("}")
                i += 2
            else:
                raise Panic("bad format")
        else:
            j = i + 1
            while j < n and template[j] not in "{}":
                j += 1
            out.append(template[i:j])
            i = j
    if used != len(args):
        raise Panic("bad format")
    return "".join(out)


# -------------------------------------------------------------------- lists
def pop_(xs):
    if not xs:
        raise Panic("empty list")
    return xs.pop()


def insert(xs, i, x):
    if i < 0 or i > len(xs):
        raise Panic("index out of bounds")
    xs.insert(i, x)


def remove_at(xs, i):
    if i < 0 or i >= len(xs):
        raise Panic("index out of bounds")
    return xs.pop(i)


def list_repeat(x, n):
    if n < 0:
        raise Panic("negative count")
    return [x] * n


def slice_(xs, a, b):
    if a < 0 or a > b or b > len(xs):
        raise Panic("index out of bounds")
    return xs[a:b]


def list_first(xs):
    if not xs:
        raise Panic("empty list")
    return xs[0]


def list_last(xs):
    if not xs:
        raise Panic("empty list")
    return xs[-1]


_SIMPLE = (int, str, Char, bool)


def list_index_of(xs, x):
    if type(x) in _SIMPLE:
        try:
            return xs.index(x)
        except ValueError:
            return -1
    for i, y in enumerate(xs):
        if veq(y, x):
            return i
    return -1


def list_flatten(xss):
    out = []
    for xs in xss:
        out.extend(xs)
    return out


# --------------------------------------------------------------------- maps
def map_get(m, k):
    if k in m:
        return (SOME_UID, m[k])
    return NONE


def map_del(m, k):
    if k in m:
        del m[k]
        return True
    return False


def unwrap(o):
    if o[0] == SOME_UID:
        return o[1]
    raise Panic("unwrap of None")


def unwrap_ok(r):
    if r[0] == OK_UID:
        return r[1]
    raise Panic("unwrap of Err")


def unwrap_err(r):
    if r[0] == ERR_UID:
        return r[1]
    raise Panic("unwrap of Ok")


def make_builtins(vm) -> list:
    """Build the built-in table for one VM instance."""
    out = vm.out
    write = out.append
    call1 = vm.call1
    call2 = vm.call2

    def print_(s):
        write(s)
        write("\n")

    def panic(msg):
        raise Panic(msg)

    def list_map(xs, f):
        return [call1(f, x) for x in xs]

    def list_filter(xs, f):
        return [x for x in xs if call1(f, x)]

    def list_fold(xs, acc, f):
        for x in xs:
            acc = call2(f, acc, x)
        return acc

    def list_any(xs, f):
        for x in xs:
            if call1(f, x):
                return True
        return False

    def list_all(xs, f):
        for x in xs:
            if not call1(f, x):
                return False
        return True

    def list_find(xs, f):
        for x in xs:
            if call1(f, x):
                return (SOME_UID, x)
        return NONE

    def list_find_index(xs, f):
        i = 0
        for x in xs:
            if call1(f, x):
                return i
            i += 1
        return -1

    def sort_by(xs, cmp):
        src = list(xs)
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
                    if call2(cmp, src[a], src[b]) <= 0:
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

    table = {
        "print": print_,
        "emit": write,
        "panic": panic,
        "intMin": lambda: IMIN,
        "intMax": lambda: IMAX,
        "absI": abs_i,
        "minI": lambda a, b: a if a <= b else b,
        "maxI": lambda a, b: a if a >= b else b,
        "signI": lambda x: (x > 0) - (x < 0),
        "cmpI": lambda a, b: (a > b) - (a < b),
        "divFloor": div_floor,
        "modFloor": mod_floor,
        "powI": pow_i,
        "gcdI": gcd_i,
        "popCount": pop_count,
        "clz": clz,
        "ctz": ctz,
        "toFloat": float,
        "showInt": str,
        "showIntRadix": show_int_radix,
        "parseInt": parse_int,
        "parseIntRadix": parse_int_radix,
        "sqrtF": sqrt_f,
        "absF": abs,
        "floorF": floor_f,
        "ceilF": ceil_f,
        "truncF": trunc_f,
        "roundF": round_f,
        "minF": min_f,
        "maxF": max_f,
        "fmodF": fmod_f,
        "powF": pow_f,
        "isNanF": lambda x: x != x,
        "isInfF": lambda x: x == math.inf or x == -math.inf,
        "cmpF": cmp_f,
        "truncToInt": trunc_to_int,
        "showFloat": lambda x: show_float_at(x, 6),
        "showFloatAt": show_float_at_,
        "floatBits": float_bits,
        "floatFromBits": float_from_bits,
        "parseFloat": parse_float,
        "infF": lambda: math.inf,
        "nanF": lambda: math.nan,
        "piF": lambda: 3.141592653589793,
        "showBool": lambda b: "true" if b else "false",
        "ord": ord,
        "chr": chr_,
        "isDigit": is_digit,
        "isAlpha": is_alpha,
        "isAlnum": is_alnum,
        "isSpace": is_space,
        "isUpper": lambda c: "A" <= c <= "Z",
        "isLower": lambda c: "a" <= c <= "z",
        "toUpperC": to_upper_c,
        "toLowerC": to_lower_c,
        "cmpC": cmp_c,
        "showChar": str,
        "quoteChar": quote_char,
        "strLen": len,
        "charAt": char_at,
        "substr": substr,
        "strCat": lambda a, b: a + b,
        "strRepeat": str_repeat,
        "strIndexOf": lambda s, sub: s.find(sub),
        "strLastIndexOf": lambda s, sub: s.rfind(sub),
        "strContains": lambda s, sub: sub in s,
        "startsWith": lambda s, p: s.startswith(p),
        "endsWith": lambda s, p: s.endswith(p),
        "strSplit": str_split,
        "strJoin": lambda parts, sep: sep.join(parts),
        "strReplace": str_replace,
        "trim": lambda s: s.strip(_SPACE),
        "trimLeft": lambda s: s.lstrip(_SPACE),
        "trimRight": lambda s: s.rstrip(_SPACE),
        "upper": lambda s: s.translate(_UPPER),
        "lower": lambda s: s.translate(_LOWER),
        "strCmp": str_cmp,
        "chars": lambda s: list(map(Char, s)),
        "strOfChars": "".join,
        "strReverse": lambda s: s[::-1],
        "quoteStr": quote_str,
        "padLeft": pad_left,
        "padRight": pad_right,
        "listNew": list,
        "listLen": len,
        "push": lambda xs, x: xs.append(x),
        "pop": pop_,
        "insert": insert,
        "removeAt": remove_at,
        "clear": lambda xs: xs.clear(),
        "listRepeat": list_repeat,
        "listConcat": lambda a, b: a + b,
        "slice": slice_,
        "listCopy": list,
        "reverseList": lambda xs: xs[::-1],
        "listFirst": list_first,
        "listLast": list_last,
        "listMap": list_map,
        "listFilter": list_filter,
        "listFold": list_fold,
        "listAny": list_any,
        "listAll": list_all,
        "listFind": list_find,
        "listFindIndex": list_find_index,
        "listIndexOf": list_index_of,
        "listContains": lambda xs, x: list_index_of(xs, x) >= 0,
        "listZip": lambda a, b: list(zip(a, b)),
        "listFlatten": list_flatten,
        "sortBy": sort_by,
        "mapNew": dict,
        "mapLen": len,
        "mapHas": lambda m, k: k in m,
        "mapGet": map_get,
        "mapGetOr": lambda m, k, d: m.get(k, d),
        "mapSet": lambda m, k, v: m.__setitem__(k, v),
        "mapDel": map_del,
        "keysOf": list,
        "valuesOf": lambda m: list(m.values()),
        "pairsOf": lambda m: list(m.items()),
        "mapClear": lambda m: m.clear(),
        "mapCopy": dict,
        "isSome": lambda o: o[0] == SOME_UID,
        "isNone": lambda o: o[0] == NONE_UID,
        "unwrap": unwrap,
        "unwrapOr": lambda o, d: o[1] if o[0] == SOME_UID else d,
        "isOk": lambda r: r[0] == OK_UID,
        "isErr": lambda r: r[0] == ERR_UID,
        "unwrapOk": unwrap_ok,
        "unwrapErr": unwrap_err,
        "fst": lambda t: t[0],
        "snd": lambda t: t[1],
        "fmt": fmt,
    }
    return [table[name] for name in BUILTIN_NAMES]
