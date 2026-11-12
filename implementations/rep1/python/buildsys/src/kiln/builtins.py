"""The 39 KBL built-in functions.

Each function is registered in :data:`BUILTINS` with its parameter types; the
evaluator performs the arity and type checks (in the order the specification
fixes) before calling the implementation.  Implementations raise their own
``E_ARG`` / ``E_TYPE`` errors.
"""

from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .errors import KilnError, arg_error, type_error
from .glob import MalformedPattern, Pattern, compile_pattern
from .values import (
    INT_MAX,
    INT_MIN,
    hashable_key,
    interpolate,
    sort_key,
    type_name,
    values_equal,
    wrap,
)


@dataclass(frozen=True, slots=True)
class Builtin:
    """A built-in function.

    ``params`` holds one type token per parameter (``any`` accepts every type;
    ``a|b`` accepts either).  For variadic functions ``max_args`` exceeds
    ``len(params)`` and the last token repeats.  ``needs_env`` functions receive
    the evaluator's environment (for ``glob``) as their first argument.
    """

    name: str
    params: tuple[str, ...]
    impl: Callable[..., Any]
    max_args: int | None = None
    needs_env: bool = False

    @property
    def min_args(self) -> int:
        return len(self.params)

    def arity_text(self) -> str:
        hi = self.max_args if self.max_args is not None else self.min_args
        return str(hi) if hi == self.min_args else f"{self.min_args}-{hi}"

    def accepts(self, count: int) -> bool:
        hi = self.max_args if self.max_args is not None else self.min_args
        return self.min_args <= count <= hi

    def check_types(self, args: list) -> None:
        for i, arg in enumerate(args, 1):
            expected = self.params[min(i, len(self.params)) - 1]
            if expected == "any":
                continue
            actual = type_name(arg)
            if actual != expected and actual not in expected.split("|"):
                raise type_error(f"fn {self.name} argument {i}", expected, actual)


BUILTINS: dict[bytes, Builtin] = {}


def _register(name: str, *params: str, max_args: int | None = None, env: bool = False):
    def deco(fn: Callable[..., Any]) -> Callable[..., Any]:
        BUILTINS[name.encode()] = Builtin(name, params, fn, max_args, env)
        return fn

    return deco


# -- strings ---------------------------------------------------------------------


@_register("len", "str|list")
def _len(v):
    return len(v)


@_register("count", "list")
def _count(v):
    return len(v)


@_register("upper", "str")
def _upper(s):
    return s.upper()


@_register("lower", "str")
def _lower(s):
    return s.lower()


@_register("trim", "str")
def _trim(s):
    return s.strip(b" \t\n\r")


@_register("replace", "str", "str", "str")
def _replace(s, old, new):
    if not old:
        raise arg_error("fn", "replace", "empty pattern")
    return s.replace(old, new)


@_register("starts_with", "str", "str")
def _starts_with(s, p):
    return s.startswith(p)


@_register("ends_with", "str", "str")
def _ends_with(s, p):
    return s.endswith(p)


@_register("contains", "str", "str")
def _contains(s, p):
    return p in s


def _clamp(n: int, start: int, count: int) -> tuple[int, int]:
    if start < 0:
        start += n
    start = min(max(start, 0), n)
    count = min(max(count, 0), n - start)
    return start, count


@_register("substr", "str", "int", "int")
def _substr(s, start, count):
    start, count = _clamp(len(s), start, count)
    return s[start : start + count]


@_register("split", "str", "str")
def _split(s, sep):
    if not sep:
        raise arg_error("fn", "split", "empty separator")
    return s.split(sep)


@_register("join", "list", "str")
def _join(items, sep):
    parts = []
    for i, item in enumerate(items):
        t = type(item)
        if t is bytes:
            parts.append(item)
        elif t is int:
            parts.append(b"%d" % item)
        else:
            raise type_error(f"fn join element {i}", "str|int", type_name(item))
    return sep.join(parts)


@_register("str", "str|int|bool")
def _str(v):
    return interpolate(v)


_INT_RE = re.compile(rb"-?[0-9]+")


@_register("int", "str|int")
def _int(v):
    if type(v) is int:
        return v
    if _INT_RE.fullmatch(v) is None:
        raise arg_error("fn", "int", "bad integer")
    n = int(v)
    if not INT_MIN <= n <= INT_MAX:
        raise arg_error("fn", "int", "bad integer")
    return n


@_register("dirname", "str")
def _dirname(p):
    i = p.rfind(b"/")
    return p[:i] if i >= 0 else b""


@_register("basename", "str")
def _basename(p):
    return p[p.rfind(b"/") + 1 :]


def _split_ext(p: bytes) -> tuple[bytes, bytes]:
    b = p[p.rfind(b"/") + 1 :]
    i = b.rfind(b".")
    if i <= 0:
        return b, b""
    return b[:i], b[i:]


@_register("stem", "str")
def _stem(p):
    return _split_ext(p)[0]


@_register("ext", "str")
def _ext(p):
    return _split_ext(p)[1]


@_register("pathjoin", "str", max_args=8)
def _pathjoin(*parts):
    return b"/".join([p for p in parts if p])


@_register("map", "list", "str")
def _map(items, pat):
    pieces: list[bytes | None] = []  # ``None`` marks the element slot
    literal = bytearray()
    i = 0
    n = len(pat)
    while i < n:
        c = pat[i]
        if c == 0x25:
            if i + 1 < n and pat[i + 1] == 0x25:
                literal.append(0x25)
                i += 2
                continue
            pieces.append(bytes(literal))
            pieces.append(None)
            literal.clear()
        else:
            literal.append(c)
        i += 1
    pieces.append(bytes(literal))
    out = []
    for idx, item in enumerate(items):
        if type(item) is not bytes:
            raise type_error(f"fn map element {idx}", "str", type_name(item))
        out.append(b"".join([item if p is None else p for p in pieces]))
    return out


def _compile(fn_name: str, pat: bytes) -> Pattern:
    try:
        return compile_pattern(pat)
    except MalformedPattern:
        raise arg_error("fn", fn_name, "bad pattern") from None


def _filter_impl(fn_name: str, items: list, pat: bytes, keep: bool) -> list:
    pattern = _compile(fn_name, pat)
    out = []
    for i, item in enumerate(items):
        if type(item) is not bytes:
            raise type_error(f"fn {fn_name} element {i}", "str", type_name(item))
        if pattern.match(item) == keep:
            out.append(item)
    return out


@_register("filter", "list", "str")
def _filter(items, pat):
    return _filter_impl("filter", items, pat, True)


@_register("reject", "list", "str")
def _reject(items, pat):
    return _filter_impl("reject", items, pat, False)


# -- lists -----------------------------------------------------------------------


@_register("sort", "list")
def _sort(items):
    return sorted(items, key=sort_key)


@_register("uniq", "list")
def _uniq(items):
    seen = set()
    out = []
    for item in items:
        k = hashable_key(item)
        if k not in seen:
            seen.add(k)
            out.append(item)
    return out


@_register("reverse", "list")
def _reverse(items):
    return items[::-1]


@_register("first", "list")
def _first(items):
    if not items:
        raise arg_error("fn", "first", "empty list")
    return items[0]


@_register("last", "list")
def _last(items):
    if not items:
        raise arg_error("fn", "last", "empty list")
    return items[-1]


@_register("slice", "list", "int", "int")
def _slice(items, start, count):
    start, count = _clamp(len(items), start, count)
    return items[start : start + count]


@_register("has", "list", "any")
def _has(items, v):
    return any(values_equal(x, v) for x in items)


@_register("indexof", "list", "any")
def _indexof(items, v):
    for i, x in enumerate(items):
        if values_equal(x, v):
            return i
    return -1


@_register("range", "int")
def _range(n):
    if n < 0:
        raise arg_error("fn", "range", "negative")
    return list(range(n))


@_register("sum", "list")
def _sum(items):
    total = 0
    for i, x in enumerate(items):
        if type(x) is not int:
            raise type_error(f"fn sum element {i}", "int", type_name(x))
        total += x
    return wrap(total)


@_register("flatten", "list")
def _flatten(items):
    out: list = []
    for x in items:
        if type(x) is list:
            out.extend(x)
        else:
            out.append(x)
    return out


@_register("zip", "list", "list")
def _zip(a, b):
    return [[x, y] for x, y in zip(a, b)]


@_register("is_str", "any")
def _is_str(v):
    return type(v) is bytes


@_register("is_int", "any")
def _is_int(v):
    return type(v) is int


@_register("is_bool", "any")
def _is_bool(v):
    return type(v) is bool


@_register("is_list", "any")
def _is_list(v):
    return type(v) is list


@_register("glob", "str", env=True)
def _glob(env, pat):
    pattern = _compile("glob", pat)
    return [p for p in env.vfs.glob_candidates(pattern.prefix) if pattern.match(p)]


__all__ = ["BUILTINS", "Builtin", "KilnError"]
