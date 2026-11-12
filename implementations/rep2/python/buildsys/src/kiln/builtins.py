"""The 39 built-in functions of KBL.

:func:`make_builtins` returns a table from function name to
:class:`Builtin`; calling :meth:`Builtin.call` performs the arity check, the
argument type checks and then runs the function, in the order the
specification fixes.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from functools import partial
from typing import Any, Callable

from .errors import KilnError, type_error
from .globs import GlobSyntaxError, compile_glob
from .values import INT_MAX, INT_MIN, equal, sort_key, stringify, type_name, wrap_int
from .vfs import VirtualFS

__all__ = ["Builtin", "make_builtins", "BUILTIN_NAMES"]

# Parameter type codes -> (accepted Python types, KBL expected-token text).
_TYPES: dict[str, tuple[frozenset, str]] = {
    "S": (frozenset({bytes}), "str"),
    "I": (frozenset({int}), "int"),
    "B": (frozenset({bool}), "bool"),
    "L": (frozenset({list}), "list"),
    "SL": (frozenset({bytes, list}), "str|list"),
    "SI": (frozenset({bytes, int}), "str|int"),
    "SIB": (frozenset({bytes, int, bool}), "str|int|bool"),
}

_INT_RE = re.compile(rb"-?[0-9]+")


@dataclass(slots=True)
class Builtin:
    """A built-in function: its name, parameter codes and implementation."""

    name: bytes
    params: tuple[str, ...]          # codes from ``_TYPES`` or "V" (any)
    impl: Callable[..., Any]
    min_args: int
    max_args: int

    def call(self, args: list) -> Any:
        n = len(args)
        if n < self.min_args or n > self.max_args:
            if self.min_args == self.max_args:
                expected = b"%d" % self.min_args
            else:
                expected = b"%d-%d" % (self.min_args, self.max_args)
            raise KilnError("E_ARITY", b"fn %b: expected %b, got %d" % (self.name, expected, n))
        params = self.params
        for i, value in enumerate(args):
            code = params[i] if i < len(params) else params[-1]
            if code != "V":
                allowed, text = _TYPES[code]
                if type(value) not in allowed:
                    raise type_error(b"fn %b argument %d" % (self.name, i + 1), text, type_name(value))
        return self.impl(*args)


def _arg_error(fn: str, reason: str) -> KilnError:
    return KilnError("E_ARG", f"fn {fn}: {reason}")


# ---- implementations --------------------------------------------------------------

def _count(l: list) -> int:
    return len(l)


def _trim(s: bytes) -> bytes:
    return s.strip(b" \t\n\r")


def _upper(s: bytes) -> bytes:
    return s.upper()  # bytes.upper only touches ASCII letters


def _lower(s: bytes) -> bytes:
    return s.lower()


def _replace(s: bytes, frm: bytes, to: bytes) -> bytes:
    if not frm:
        raise _arg_error("replace", "empty pattern")
    return s.replace(frm, to)


def _clamp_window(n: int, start: int, count: int) -> tuple[int, int]:
    if start < 0:
        start += n
    start = 0 if start < 0 else n if start > n else start
    count = 0 if count < 0 else min(count, n - start)
    return start, count


def _substr(s: bytes, start: int, count: int) -> bytes:
    start, count = _clamp_window(len(s), start, count)
    return s[start:start + count]


def _slice(l: list, start: int, count: int) -> list:
    start, count = _clamp_window(len(l), start, count)
    return l[start:start + count]


def _split(s: bytes, sep: bytes) -> list:
    if not sep:
        raise _arg_error("split", "empty separator")
    return s.split(sep)


def _join(l: list, sep: bytes) -> bytes:
    pieces = []
    for i, e in enumerate(l):
        t = type(e)
        if t is bytes:
            pieces.append(e)
        elif t is int:
            pieces.append(b"%d" % e)
        else:
            raise type_error(b"fn join element %d" % i, "str|int", type_name(e))
    return sep.join(pieces)


def _str(v: Any) -> bytes:
    return stringify(v)


def _int(v: Any) -> int:
    if type(v) is int:
        return v
    if _INT_RE.fullmatch(v) is None:
        raise _arg_error("int", "bad integer")
    n = int(v)
    if n < INT_MIN or n > INT_MAX:
        raise _arg_error("int", "bad integer")
    return n


def _dirname(p: bytes) -> bytes:
    i = p.rfind(b"/")
    return b"" if i < 0 else p[:i]


def _basename(p: bytes) -> bytes:
    return p[p.rfind(b"/") + 1:]


def _split_ext(p: bytes) -> tuple[bytes, bytes]:
    b = _basename(p)
    i = b.rfind(b".")
    if i <= 0:
        return b, b""
    return b[:i], b[i:]


def _stem(p: bytes) -> bytes:
    return _split_ext(p)[0]


def _ext(p: bytes) -> bytes:
    return _split_ext(p)[1]


def _pathjoin(*parts: bytes) -> bytes:
    return b"/".join(p for p in parts if p)


def _map(l: list, pat: bytes) -> list:
    pieces = []
    i = 0
    n = len(pat)
    while i < n:
        j = pat.find(b"%", i)
        if j < 0:
            pieces.append(pat[i:])
            break
        pieces.append(pat[i:j])
        if j + 1 < n and pat[j + 1] == 0x25:
            pieces.append(b"%")
            i = j + 2
        else:
            pieces.append(None)  # the element
            i = j + 1
    out = []
    for k, e in enumerate(l):
        if type(e) is not bytes:
            raise type_error(b"fn map element %d" % k, "str", type_name(e))
        out.append(b"".join([e if p is None else p for p in pieces]))
    return out


def _filter_impl(name: str, keep_matching: bool, l: list, pat: bytes) -> list:
    try:
        glob = compile_glob(pat)
    except GlobSyntaxError:
        raise _arg_error(name, "bad pattern") from None
    out = []
    match = glob.match
    for i, e in enumerate(l):
        if type(e) is not bytes:
            raise type_error(b"fn %b element %d" % (name.encode(), i), "str", type_name(e))
        if match(e) == keep_matching:
            out.append(e)
    return out


def _sort(l: list) -> list:
    return sorted(l, key=sort_key)


def _uniq(l: list) -> list:
    seen = set()
    out = []
    for e in l:
        t = type(e)
        k = (t, e) if t is bytes or t is int or t is bool else sort_key(e)
        if k not in seen:
            seen.add(k)
            out.append(e)
    return out


def _reverse(l: list) -> list:
    return l[::-1]


def _first(l: list) -> Any:
    if not l:
        raise _arg_error("first", "empty list")
    return l[0]


def _last(l: list) -> Any:
    if not l:
        raise _arg_error("last", "empty list")
    return l[-1]


def _has(l: list, v: Any) -> bool:
    return any(equal(e, v) for e in l)


def _indexof(l: list, v: Any) -> int:
    for i, e in enumerate(l):
        if equal(e, v):
            return i
    return -1


def _range(n: int) -> list:
    if n < 0:
        raise _arg_error("range", "negative")
    return list(range(n))


def _sum(l: list) -> int:
    total = 0
    for i, e in enumerate(l):
        if type(e) is not int:
            raise type_error(b"fn sum element %d" % i, "int", type_name(e))
        total += e
    return wrap_int(total)


def _flatten(l: list) -> list:
    out: list = []
    for e in l:
        if type(e) is list:
            out.extend(e)
        else:
            out.append(e)
    return out


def _zip(a: list, b: list) -> list:
    return [[x, y] for x, y in zip(a, b)]


def _glob(fs: VirtualFS, pat: bytes) -> list:
    try:
        glob = compile_glob(pat)
    except GlobSyntaxError:
        raise _arg_error("glob", "bad pattern") from None
    return fs.glob(glob)


_PURE: list[tuple[str, tuple[str, ...], Callable[..., Any], int | None]] = [
    ("len", ("SL",), len, None),
    ("count", ("L",), _count, None),
    ("upper", ("S",), _upper, None),
    ("lower", ("S",), _lower, None),
    ("trim", ("S",), _trim, None),
    ("replace", ("S", "S", "S"), _replace, None),
    ("starts_with", ("S", "S"), bytes.startswith, None),
    ("ends_with", ("S", "S"), bytes.endswith, None),
    ("contains", ("S", "S"), lambda s, n: n in s, None),
    ("substr", ("S", "I", "I"), _substr, None),
    ("split", ("S", "S"), _split, None),
    ("join", ("L", "S"), _join, None),
    ("str", ("SIB",), _str, None),
    ("int", ("SI",), _int, None),
    ("dirname", ("S",), _dirname, None),
    ("basename", ("S",), _basename, None),
    ("stem", ("S",), _stem, None),
    ("ext", ("S",), _ext, None),
    ("pathjoin", ("S",), _pathjoin, 8),
    ("map", ("L", "S"), _map, None),
    ("filter", ("L", "S"), partial(_filter_impl, "filter", True), None),
    ("reject", ("L", "S"), partial(_filter_impl, "reject", False), None),
    ("sort", ("L",), _sort, None),
    ("uniq", ("L",), _uniq, None),
    ("reverse", ("L",), _reverse, None),
    ("first", ("L",), _first, None),
    ("last", ("L",), _last, None),
    ("slice", ("L", "I", "I"), _slice, None),
    ("has", ("L", "V"), _has, None),
    ("indexof", ("L", "V"), _indexof, None),
    ("range", ("I",), _range, None),
    ("sum", ("L",), _sum, None),
    ("flatten", ("L",), _flatten, None),
    ("zip", ("L", "L"), _zip, None),
    ("is_str", ("V",), lambda v: type(v) is bytes, None),
    ("is_int", ("V",), lambda v: type(v) is int, None),
    ("is_bool", ("V",), lambda v: type(v) is bool, None),
    ("is_list", ("V",), lambda v: type(v) is list, None),
]

#: Names of every built-in function.
BUILTIN_NAMES = frozenset([n.encode() for n, *_ in _PURE] + [b"glob"])


def make_builtins(fs: VirtualFS) -> dict[bytes, Builtin]:
    """Build the function table, binding ``glob`` to ``fs``."""
    table: dict[bytes, Builtin] = {}
    for name, params, impl, max_args in _PURE:
        if max_args is None:
            lo = hi = len(params)
        else:  # variadic: 1 .. max_args arguments, all of the last parameter's type
            lo, hi = 1, max_args
        table[name.encode()] = Builtin(name.encode(), params, impl, lo, hi)
    table[b"glob"] = Builtin(b"glob", ("S",), partial(_glob, fs), 1, 1)
    return table
