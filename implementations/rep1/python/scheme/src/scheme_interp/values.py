"""Runtime representations of Scheme values.

========================  ==========================================
Scheme value              Python representation
========================  ==========================================
integer (machine word)    ``int`` with ``|n| < 2**62``
integer (larger)          :class:`scheme_interp.bignum.BigInt`
boolean                   ``bool``
string                    ``str`` (strings are immutable)
symbol                    :class:`Symbol` (interned; compare by identity)
pair                      :class:`Pair`
empty list                :data:`NIL`
void                      :data:`VOID`
closure                   :class:`Closure`
primitive procedure       a plain Python function
========================  ==========================================
"""

from __future__ import annotations

from types import FunctionType
from typing import Any, Callable, Iterable, Optional


class Symbol:
    """An interned symbol.  Use :func:`intern` to obtain one."""

    __slots__ = ("name",)

    def __init__(self, name: str) -> None:
        self.name = name

    def __repr__(self) -> str:
        return f"Symbol({self.name!r})"


_symbol_table: dict[str, Symbol] = {}


def intern(name: str) -> Symbol:
    """Return the unique :class:`Symbol` called ``name``."""
    sym = _symbol_table.get(name)
    if sym is None:
        sym = _symbol_table[name] = Symbol(name)
    return sym


class Pair:
    """A mutable cons cell."""

    __slots__ = ("car", "cdr")

    def __init__(self, car: Any, cdr: Any) -> None:
        self.car = car
        self.cdr = cdr

    def __repr__(self) -> str:
        from .printer import write_string

        return f"Pair<{write_string(self)}>"


class _Singleton:
    __slots__ = ("_name",)

    def __init__(self, name: str) -> None:
        self._name = name

    def __repr__(self) -> str:
        return self._name


#: The empty list.
NIL = _Singleton("NIL")
#: The value of ``define``, ``set!``, ``display`` and friends.
VOID = _Singleton("VOID")

#: Key under which a frame (a ``dict``) stores its parent frame.  It is not a
#: :class:`Symbol`, so it can never collide with a Scheme variable.
PARENT = _Singleton("PARENT")


class Closure:
    """A user-defined procedure: parameters, analysed body and environment."""

    __slots__ = ("params", "rest", "body", "env", "nparams")

    def __init__(
        self,
        params: tuple[Symbol, ...],
        rest: Optional[Symbol],
        body: Callable[[dict], Any],
        env: dict,
    ) -> None:
        self.params = params
        self.rest = rest
        self.body = body
        self.env = env
        self.nparams = len(params)


#: Python type of primitive procedures (plain functions).
PrimitiveType = FunctionType


def is_procedure(x: Any) -> bool:
    """True if ``x`` is a Scheme procedure (closure or primitive)."""
    t = type(x)
    return t is Closure or t is FunctionType


def list_to_scheme(items: Iterable[Any], tail: Any = NIL) -> Any:
    """Build a Scheme list from a Python iterable (optionally improper)."""
    seq = items if isinstance(items, (list, tuple)) else list(items)
    result = tail
    for item in reversed(seq):
        result = Pair(item, result)
    return result


def scheme_to_list(x: Any) -> list[Any]:
    """Convert a proper Scheme list to a Python list.

    Raises :class:`ValueError` if ``x`` is not a proper list.
    """
    out = []
    while type(x) is Pair:
        out.append(x.car)
        x = x.cdr
    if x is not NIL:
        raise ValueError("not a proper list")
    return out
