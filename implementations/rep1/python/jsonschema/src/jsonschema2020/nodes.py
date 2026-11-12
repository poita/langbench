"""Compiled schema nodes, the annotation collector and the schema registry."""

from __future__ import annotations

from fractions import Fraction
from typing import Any, Callable, Dict, List, Optional, Tuple

from . import uri
from .errors import RefResolutionError

__all__ = ["Ann", "Node", "Registry", "TRUE_NODE", "FALSE_NODE"]

#: A compiled keyword: ``check(instance, scope, ann) -> bool``.
Check = Callable[[Any, Tuple[str, ...], Optional["Ann"]], bool]

_NUMBER_TYPES = (int, Fraction)


class Ann:
    """Evaluated-items / evaluated-properties collected for one schema object."""

    __slots__ = ("items", "props")

    def __init__(self) -> None:
        self.items: set = set()
        self.props: set = set()

    def merge(self, other: "Ann") -> None:
        if other.items:
            self.items |= other.items
        if other.props:
            self.props |= other.props


class Node:
    """One compiled schema object (or boolean schema).

    ``evaluate`` runs the keyword checks that apply to the instance's type and
    then the ``unevaluated*`` keywords, which need the annotations the other
    keywords produced (spec section 4.2).
    """

    __slots__ = ("base", "raw", "const", "any_checks", "type_checks", "unev_checks")

    def __init__(self, base: str, raw: Any, const: Optional[bool] = None) -> None:
        self.base = base
        self.raw = raw
        self.const = const
        self.any_checks: List[Check] = []
        self.type_checks: Dict[type, List[Check]] = {}
        self.unev_checks: Dict[type, List[Check]] = {}

    # -- construction --------------------------------------------------------

    def add(self, types: Optional[Tuple[type, ...]], check: Check) -> None:
        """Register *check*; ``types`` limits it to instances of those Python
        types (``None`` means every instance)."""
        if types is None:
            self.any_checks.append(check)
        else:
            for t in types:
                self.type_checks.setdefault(t, []).append(check)

    def add_unevaluated(self, instance_type: type, check: Check) -> None:
        self.unev_checks.setdefault(instance_type, []).append(check)

    def freeze(self) -> None:
        """Convert the check lists to tuples once compilation is complete."""
        self.any_checks = tuple(self.any_checks)  # type: ignore[assignment]
        self.type_checks = {t: tuple(c) for t, c in self.type_checks.items()}  # type: ignore[misc]
        self.unev_checks = {t: tuple(c) for t, c in self.unev_checks.items()}  # type: ignore[misc]

    # -- evaluation ----------------------------------------------------------

    def evaluate(self, instance: Any, scope: Tuple[str, ...], ann: Optional[Ann]) -> bool:
        """Does *instance* satisfy this schema?

        ``scope`` is the dynamic scope (outermost base URI first).  When *ann*
        is not ``None`` the evaluated items / properties of this schema are
        added to it, but only if the schema accepts the instance.
        """
        const = self.const
        if const is not None:
            return const
        base = self.base
        if not scope or scope[-1] != base:
            scope = scope + (base,)
        itype = type(instance)
        unev = self.unev_checks.get(itype) if self.unev_checks else None
        local = Ann() if unev else ann
        for check in self.any_checks:
            if not check(instance, scope, local):
                return False
        typed = self.type_checks.get(itype)
        if typed:
            for check in typed:
                if not check(instance, scope, local):
                    return False
        if unev:
            for check in unev:
                if not check(instance, scope, local):
                    return False
            if ann is not None:
                ann.merge(local)  # type: ignore[arg-type]
        return True


TRUE_NODE = Node("", True, True)
FALSE_NODE = Node("", False, False)
TRUE_NODE.freeze()
FALSE_NODE.freeze()


class Registry:
    """Index of schema resources, anchors and compiled nodes."""

    def __init__(self) -> None:
        #: base URI -> the node of the schema resource registered there
        self.resources: Dict[str, Node] = {}
        #: (base URI, name) -> node, for ``$anchor``
        self.anchors: Dict[Tuple[str, str], Node] = {}
        #: (base URI, name) -> node, for ``$dynamicAnchor``
        self.dynamic_anchors: Dict[Tuple[str, str], Node] = {}
        #: id(raw schema dict) -> compiled node
        self.nodes: Dict[int, Node] = {}
        #: callback compiling a raw schema found at a pointer target
        self.compile_late: Optional[Callable[[Any, str], Node]] = None

    def lookup_anchor(self, doc: str, name: str) -> Optional[Node]:
        node = self.anchors.get((doc, name))
        if node is None:
            node = self.dynamic_anchors.get((doc, name))
        return node

    def resolve(self, doc: str, fragment: str) -> Node:
        """Find the node a reference with document part *doc* and (already
        percent-decoded) *fragment* designates."""
        resource = self.resources.get(doc)
        if fragment == "":
            if resource is None:
                raise RefResolutionError(f"unknown schema resource {doc!r}")
            return resource
        if fragment.startswith("/"):
            if resource is None:
                raise RefResolutionError(f"unknown schema resource {doc!r}")
            try:
                target = uri.evaluate_pointer(resource.raw, fragment)
            except uri.PointerError as exc:
                raise RefResolutionError(f"{exc} (in {doc!r})") from None
            if target is True:
                return TRUE_NODE
            if target is False:
                return FALSE_NODE
            node = self.nodes.get(id(target))
            if node is None:
                if type(target) is not dict or self.compile_late is None:
                    raise RefResolutionError(
                        f"pointer {fragment!r} in {doc!r} does not designate a schema"
                    )
                node = self.compile_late(target, resource.base)
            return node
        node = self.lookup_anchor(doc, fragment)
        if node is None:
            raise RefResolutionError(f"unknown anchor {fragment!r} in {doc!r}")
        return node
