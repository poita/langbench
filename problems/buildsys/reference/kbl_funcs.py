"""KBL built-in functions, the value total order, and the glob matcher."""
from kiln_err import KilnError, vtype, need_type
from kiln_vfs import is_generated, STATE_PATH

MASK64 = (1 << 64) - 1
INT_MIN = -(1 << 63)
INT_MAX = (1 << 63) - 1

_RANK = {b"bool": 0, b"int": 1, b"str": 2, b"list": 3}


def wrap64(n):
    n &= MASK64
    if n >= 1 << 63:
        n -= 1 << 64
    return n


def cmp_vals(a, b):
    """The total order: bool < int < str < list, then type-specific."""
    ta = vtype(a)
    tb = vtype(b)
    if ta != tb:
        return -1 if _RANK[ta] < _RANK[tb] else 1
    if ta == b"list":
        n = min(len(a), len(b))
        for i in range(n):
            c = cmp_vals(a[i], b[i])
            if c:
                return c
        if len(a) == len(b):
            return 0
        return -1 if len(a) < len(b) else 1
    if a == b:
        return 0
    return -1 if a < b else 1


def sort_key(v):
    """A Python-comparable key that reproduces the total order exactly: the
    type rank always differs when the types do, so values of different types
    are never compared directly."""
    t = vtype(v)
    if t == b"list":
        return (3, tuple(sort_key(e) for e in v))
    return (_RANK[t], v)


def val_eq(a, b):
    """Deep structural equality; values of different types are never equal."""
    ta = vtype(a)
    if ta != vtype(b):
        return False
    if ta == b"list":
        if len(a) != len(b):
            return False
        for i in range(len(a)):
            if not val_eq(a[i], b[i]):
                return False
        return True
    return a == b


def render_scalar(v):
    """The text interpolation and ``str()`` produce for a scalar."""
    t = vtype(v)
    if t == b"str":
        return v
    if t == b"int":
        return b"%d" % v
    if t == b"bool":
        return b"true" if v else b"false"
    raise KilnError(b"E_INTERP", b"list")


# ---------------------------------------------------------------- glob

GLOBSTAR = object()


class BadPattern(Exception):
    pass


def _parse_class(pat, i):
    """Parse a character class starting at ``pat[i] == '['``; return
    ``((negated, items), next_index)``."""
    n = len(pat)
    j = i + 1
    neg = False
    if j < n and pat[j] == 0x21:        # '!'
        neg = True
        j += 1
    items = []
    while True:
        if j >= n:
            raise BadPattern()
        if pat[j] == 0x5D:              # ']'
            if not items:
                raise BadPattern()
            return (neg, items), j + 1
        if (j + 2 < n and pat[j + 1] == 0x2D and pat[j + 2] != 0x5D):
            lo = pat[j]
            hi = pat[j + 2]
            if lo > hi:
                raise BadPattern()
            items.append((lo, hi))
            j += 3
        else:
            items.append((pat[j], pat[j]))
            j += 1


def _compile_component(comp):
    if comp == b"**":
        return GLOBSTAR
    items = []
    i = 0
    n = len(comp)
    while i < n:
        c = comp[i]
        if c == 0x2A:                   # '*'
            items.append(("star", 0))
            i += 1
        elif c == 0x3F:                 # '?'
            items.append(("any", 0))
            i += 1
        elif c == 0x5B:                 # '['
            cls, i = _parse_class(comp, i)
            items.append(("class", cls))
        else:
            items.append(("lit", c))
            i += 1
    return items


def compile_pattern(pat):
    """Compile a glob pattern; raise ``BadPattern`` when malformed."""
    if not pat or pat.startswith(b"/") or pat.endswith(b"/"):
        raise BadPattern()
    comps = pat.split(b"/")
    out = []
    for comp in comps:
        if not comp:
            raise BadPattern()
        out.append(_compile_component(comp))
    return out


def _class_match(cls, byte):
    neg, items = cls
    hit = False
    for lo, hi in items:
        if lo <= byte <= hi:
            hit = True
            break
    return hit != neg


def _match_component(items, s):
    n = len(s)
    cur = {0}
    for kind, arg in items:
        nxt = set()
        if kind == "star":
            for p in cur:
                for q in range(p, n + 1):
                    nxt.add(q)
        elif kind == "any":
            for p in cur:
                if p < n:
                    nxt.add(p + 1)
        elif kind == "lit":
            for p in cur:
                if p < n and s[p] == arg:
                    nxt.add(p + 1)
        else:
            for p in cur:
                if p < n and _class_match(arg, s[p]):
                    nxt.add(p + 1)
        if not nxt:
            return False
        cur = nxt
    return n in cur


def match_pattern(compiled, candidate):
    """True when the compiled pattern matches the whole candidate string."""
    ccomps = candidate.split(b"/")
    np = len(compiled)
    nc = len(ccomps)
    memo = {}

    def go(pi, ci):
        key = pi * (nc + 1) + ci
        got = memo.get(key)
        if got is not None:
            return got
        if pi == np:
            r = ci == nc
        elif compiled[pi] is GLOBSTAR:
            r = False
            for k in range(ci, nc + 1):
                if go(pi + 1, k):
                    r = True
                    break
        else:
            r = (ci < nc and _match_component(compiled[pi], ccomps[ci])
                 and go(pi + 1, ci + 1))
        memo[key] = r
        return r

    return go(0, 0)


def compile_or_fail(pat, fname):
    try:
        return compile_pattern(pat)
    except BadPattern:
        raise KilnError(b"E_ARG", b"fn " + fname + b": bad pattern")


# ---------------------------------------------------------- built-ins

def _arg(args, i, expected, name):
    site = b"fn " + name + b" argument " + b"%d" % (i + 1)
    return need_type(args[i], expected, site)


def _clamp_range(n, start, count):
    if start < 0:
        start = n + start
    if start < 0:
        start = 0
    elif start > n:
        start = n
    if count < 0:
        count = 0
    elif count > n - start:
        count = n - start
    return start, count


def _replace_bytes(s, frm, to):
    out = bytearray()
    i = 0
    n = len(s)
    m = len(frm)
    while i < n:
        if s[i:i + m] == frm:
            out += to
            i += m
        else:
            out.append(s[i])
            i += 1
    return bytes(out)


def _split_bytes(s, sep):
    pieces = []
    i = 0
    while True:
        j = s.find(sep, i)
        if j < 0:
            pieces.append(s[i:])
            return pieces
        pieces.append(s[i:j])
        i = j + len(sep)


def _basename(p):
    j = p.rfind(b"/")
    return p if j < 0 else p[j + 1:]


def _stem_ext(p):
    b = _basename(p)
    j = b.rfind(b".")
    if j <= 0:
        return b, b""
    return b[:j], b[j:]


def _map_pattern(elem, pat):
    out = bytearray()
    i = 0
    n = len(pat)
    while i < n:
        if pat[i] == 0x25:              # '%'
            if i + 1 < n and pat[i + 1] == 0x25:
                out.append(0x25)
                i += 2
            else:
                out += elem
                i += 1
        else:
            out.append(pat[i])
            i += 1
    return bytes(out)


def _check_elements(lst, name):
    for i, e in enumerate(lst):
        t = vtype(e)
        if t != b"str":
            raise KilnError(
                b"E_TYPE",
                b"fn " + name + b" element " + b"%d" % i +
                b": expected str, got " + t)


def _f_len(ctx, a):
    v = _arg(a, 0, b"str|list", b"len")
    return len(v)


def _f_count(ctx, a):
    return len(_arg(a, 0, b"list", b"count"))


def _f_upper(ctx, a):
    return _arg(a, 0, b"str", b"upper").upper()


def _f_lower(ctx, a):
    return _arg(a, 0, b"str", b"lower").lower()


def _f_trim(ctx, a):
    return _arg(a, 0, b"str", b"trim").strip(b" \t\n\r")


def _f_replace(ctx, a):
    s = _arg(a, 0, b"str", b"replace")
    frm = _arg(a, 1, b"str", b"replace")
    to = _arg(a, 2, b"str", b"replace")
    if not frm:
        raise KilnError(b"E_ARG", b"fn replace: empty pattern")
    return _replace_bytes(s, frm, to)


def _f_starts_with(ctx, a):
    s = _arg(a, 0, b"str", b"starts_with")
    p = _arg(a, 1, b"str", b"starts_with")
    return s.startswith(p)


def _f_ends_with(ctx, a):
    s = _arg(a, 0, b"str", b"ends_with")
    p = _arg(a, 1, b"str", b"ends_with")
    return s.endswith(p)


def _f_contains(ctx, a):
    s = _arg(a, 0, b"str", b"contains")
    p = _arg(a, 1, b"str", b"contains")
    return p in s


def _f_substr(ctx, a):
    s = _arg(a, 0, b"str", b"substr")
    start = _arg(a, 1, b"int", b"substr")
    count = _arg(a, 2, b"int", b"substr")
    start, count = _clamp_range(len(s), start, count)
    return s[start:start + count]


def _f_split(ctx, a):
    s = _arg(a, 0, b"str", b"split")
    sep = _arg(a, 1, b"str", b"split")
    if not sep:
        raise KilnError(b"E_ARG", b"fn split: empty separator")
    return _split_bytes(s, sep)


def _f_join(ctx, a):
    lst = _arg(a, 0, b"list", b"join")
    sep = _arg(a, 1, b"str", b"join")
    pieces = []
    for i, e in enumerate(lst):
        t = vtype(e)
        if t == b"str":
            pieces.append(e)
        elif t == b"int":
            pieces.append(b"%d" % e)
        else:
            raise KilnError(
                b"E_TYPE", b"fn join element " + b"%d" % i +
                b": expected str|int, got " + t)
    return sep.join(pieces)


def _f_str(ctx, a):
    v = _arg(a, 0, b"str|int|bool", b"str")
    return render_scalar(v)


def _f_int(ctx, a):
    v = _arg(a, 0, b"str|int", b"int")
    if vtype(v) == b"int":
        return v
    body = v[1:] if v[:1] == b"-" else v
    if not body or not all(48 <= c <= 57 for c in body):
        raise KilnError(b"E_ARG", b"fn int: bad integer")
    n = int(v)
    if n < INT_MIN or n > INT_MAX:
        raise KilnError(b"E_ARG", b"fn int: bad integer")
    return n


def _f_dirname(ctx, a):
    p = _arg(a, 0, b"str", b"dirname")
    j = p.rfind(b"/")
    return b"" if j < 0 else p[:j]


def _f_basename(ctx, a):
    return _basename(_arg(a, 0, b"str", b"basename"))


def _f_stem(ctx, a):
    return _stem_ext(_arg(a, 0, b"str", b"stem"))[0]


def _f_ext(ctx, a):
    return _stem_ext(_arg(a, 0, b"str", b"ext"))[1]


def _f_pathjoin(ctx, a):
    parts = []
    for i in range(len(a)):
        v = _arg(a, i, b"str", b"pathjoin")
        if v:
            parts.append(v)
    return b"/".join(parts)


def _f_map(ctx, a):
    lst = _arg(a, 0, b"list", b"map")
    pat = _arg(a, 1, b"str", b"map")
    _check_elements(lst, b"map")
    return [_map_pattern(e, pat) for e in lst]


def _f_filter(ctx, a):
    lst = _arg(a, 0, b"list", b"filter")
    pat = _arg(a, 1, b"str", b"filter")
    compiled = compile_or_fail(pat, b"filter")
    _check_elements(lst, b"filter")
    return [e for e in lst if match_pattern(compiled, e)]


def _f_reject(ctx, a):
    lst = _arg(a, 0, b"list", b"reject")
    pat = _arg(a, 1, b"str", b"reject")
    compiled = compile_or_fail(pat, b"reject")
    _check_elements(lst, b"reject")
    return [e for e in lst if not match_pattern(compiled, e)]


def _f_sort(ctx, a):
    lst = _arg(a, 0, b"list", b"sort")
    return sorted(lst, key=sort_key)


def _f_uniq(ctx, a):
    lst = _arg(a, 0, b"list", b"uniq")
    out = []
    seen = set()
    for e in lst:
        k = sort_key(e)
        if k in seen:
            continue
        seen.add(k)
        out.append(e)
    return out


def _f_reverse(ctx, a):
    return list(reversed(_arg(a, 0, b"list", b"reverse")))


def _f_first(ctx, a):
    lst = _arg(a, 0, b"list", b"first")
    if not lst:
        raise KilnError(b"E_ARG", b"fn first: empty list")
    return lst[0]


def _f_last(ctx, a):
    lst = _arg(a, 0, b"list", b"last")
    if not lst:
        raise KilnError(b"E_ARG", b"fn last: empty list")
    return lst[-1]


def _f_slice(ctx, a):
    lst = _arg(a, 0, b"list", b"slice")
    start = _arg(a, 1, b"int", b"slice")
    count = _arg(a, 2, b"int", b"slice")
    start, count = _clamp_range(len(lst), start, count)
    return list(lst[start:start + count])


def _f_has(ctx, a):
    lst = _arg(a, 0, b"list", b"has")
    for e in lst:
        if val_eq(e, a[1]):
            return True
    return False


def _f_indexof(ctx, a):
    lst = _arg(a, 0, b"list", b"indexof")
    for i, e in enumerate(lst):
        if val_eq(e, a[1]):
            return i
    return -1


def _f_range(ctx, a):
    n = _arg(a, 0, b"int", b"range")
    if n < 0:
        raise KilnError(b"E_ARG", b"fn range: negative")
    return list(range(n))


def _f_sum(ctx, a):
    lst = _arg(a, 0, b"list", b"sum")
    total = 0
    for i, e in enumerate(lst):
        t = vtype(e)
        if t != b"int":
            raise KilnError(
                b"E_TYPE", b"fn sum element " + b"%d" % i +
                b": expected int, got " + t)
        total = wrap64(total + e)
    return total


def _f_flatten(ctx, a):
    lst = _arg(a, 0, b"list", b"flatten")
    out = []
    for e in lst:
        if vtype(e) == b"list":
            out.extend(e)
        else:
            out.append(e)
    return out


def _f_zip(ctx, a):
    x = _arg(a, 0, b"list", b"zip")
    y = _arg(a, 1, b"list", b"zip")
    return [[x[i], y[i]] for i in range(min(len(x), len(y)))]


def _f_is_str(ctx, a):
    return vtype(a[0]) == b"str"


def _f_is_int(ctx, a):
    return vtype(a[0]) == b"int"


def _f_is_bool(ctx, a):
    return vtype(a[0]) == b"bool"


def _f_is_list(ctx, a):
    return vtype(a[0]) == b"list"


def _f_glob(ctx, a):
    pat = _arg(a, 0, b"str", b"glob")
    compiled = compile_or_fail(pat, b"glob")
    out = []
    for p in ctx.workspace.files:
        if is_generated(p) or p == STATE_PATH:
            continue
        if match_pattern(compiled, p):
            out.append(p)
    out.sort()
    return out


BUILTINS = {
    b"len": (1, 1, _f_len),
    b"count": (1, 1, _f_count),
    b"upper": (1, 1, _f_upper),
    b"lower": (1, 1, _f_lower),
    b"trim": (1, 1, _f_trim),
    b"replace": (3, 3, _f_replace),
    b"starts_with": (2, 2, _f_starts_with),
    b"ends_with": (2, 2, _f_ends_with),
    b"contains": (2, 2, _f_contains),
    b"substr": (3, 3, _f_substr),
    b"split": (2, 2, _f_split),
    b"join": (2, 2, _f_join),
    b"str": (1, 1, _f_str),
    b"int": (1, 1, _f_int),
    b"dirname": (1, 1, _f_dirname),
    b"basename": (1, 1, _f_basename),
    b"stem": (1, 1, _f_stem),
    b"ext": (1, 1, _f_ext),
    b"pathjoin": (1, 8, _f_pathjoin),
    b"map": (2, 2, _f_map),
    b"filter": (2, 2, _f_filter),
    b"reject": (2, 2, _f_reject),
    b"sort": (1, 1, _f_sort),
    b"uniq": (1, 1, _f_uniq),
    b"reverse": (1, 1, _f_reverse),
    b"first": (1, 1, _f_first),
    b"last": (1, 1, _f_last),
    b"slice": (3, 3, _f_slice),
    b"has": (2, 2, _f_has),
    b"indexof": (2, 2, _f_indexof),
    b"range": (1, 1, _f_range),
    b"sum": (1, 1, _f_sum),
    b"flatten": (1, 1, _f_flatten),
    b"zip": (2, 2, _f_zip),
    b"is_str": (1, 1, _f_is_str),
    b"is_int": (1, 1, _f_is_int),
    b"is_bool": (1, 1, _f_is_bool),
    b"is_list": (1, 1, _f_is_list),
    b"glob": (1, 1, _f_glob),
}


def call_builtin(ctx, name, args):
    """Dispatch a built-in call: the name, then arity, then the function."""
    entry = BUILTINS.get(name)
    if entry is None:
        raise KilnError(b"E_UNKNOWN_FUNC", name)
    lo, hi, fn = entry
    n = len(args)
    if n < lo or n > hi:
        if lo == hi:
            want = b"%d" % lo
        else:
            want = b"%d-%d" % (lo, hi)
        raise KilnError(
            b"E_ARITY",
            b"fn " + name + b": expected " + want + b", got " + b"%d" % n)
    return fn(ctx, args)
