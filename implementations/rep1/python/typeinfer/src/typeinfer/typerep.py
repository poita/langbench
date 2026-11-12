"""Representation of types: a shared graph of union-find nodes.

A type is either a :class:`TVar` (a unification variable) or a :class:`TCon`
(a type constructor applied to argument types).  Types are *graphs*, not
trees: the same node may be referenced from many places, so a type whose
printed form is exponentially large can have a linear number of nodes.

Every node has a ``link`` field.  A variable that has been bound points to its
value through ``link``; a constructor node that has been unified with an
equal constructor node points to it too (see :mod:`typeinfer.unify`).  Always
call :func:`resolve` before looking at a node.
"""

from __future__ import annotations

from itertools import count

#: Level of a quantified (generic) variable; larger than any real level.
GENERIC = 1 << 60

_stamps = count(1)


def new_stamp() -> int:
    """Return a fresh traversal stamp, used to visit each node once per walk."""
    return next(_stamps)


class Type:
    """Base class of type nodes."""

    __slots__ = ("link",)


class TVar(Type):
    """A type variable.  Unbound while ``link is None``.

    ``level`` is the let-nesting depth at which the variable was created
    (lowered by unification); it is :data:`GENERIC` once quantified.
    """

    __slots__ = ("level",)

    def __init__(self, level: int) -> None:
        self.link: Type | None = None
        self.level = level

    def __repr__(self) -> str:
        from .pretty import format_type

        return f"TVar({format_type(self)})"


class TCon(Type):
    """A type constructor (``int``, ``->``, ``*``, ``list`` ...) and its arguments."""

    __slots__ = ("name", "args", "mark")

    def __init__(self, name: str, args: tuple[Type, ...] = ()) -> None:
        self.link: Type | None = None
        self.name = name
        self.args = args
        self.mark = 0  # traversal stamp

    def __repr__(self) -> str:
        from .pretty import format_type

        return f"TCon({format_type(self)})"


def resolve(t: Type) -> Type:
    """Follow ``link`` chains to the representative node, compressing paths."""
    root = t.link
    if root is None:
        return t
    while root.link is not None:
        root = root.link
    while t is not root:
        nxt = t.link
        t.link = root
        t = nxt  # type: ignore[assignment]
    return root


INT = TCon("int")
BOOL = TCon("bool")
UNIT = TCon("unit")


def arrow(arg: Type, result: Type) -> TCon:
    """The function type ``arg -> result``."""
    return TCon("->", (arg, result))


def list_of(elem: Type) -> TCon:
    """The type ``elem list``."""
    return TCon("list", (elem,))


def tuple_of(items: tuple[Type, ...] | list[Type]) -> TCon:
    """The tuple type ``t1 * ... * tn`` (``n >= 2``)."""
    return TCon("*", tuple(items))


class Scheme:
    """What the environment stores for a name.

    ``poly`` tells whether ``type`` contains quantified variables.  A
    monomorphic binding (lambda parameter, a recursive name inside its own
    body, or a let-bound value with nothing to generalise) is used as is.
    """

    __slots__ = ("type", "poly")

    def __init__(self, type: Type, poly: bool = False) -> None:
        self.type = type
        self.poly = poly
