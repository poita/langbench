"""Abstract syntax of Datalog programs.

All nodes are immutable, hashable dataclasses.  A *constant* is either an
``int`` or an identifier ``str``; see :mod:`datalog.constants` for the total
order on constants.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Union

#: Identifies a predicate: its name together with its arity.
PredicateKey = tuple[str, int]

#: Value of a constant: an integer or an identifier.
ConstantValue = Union[int, str]


@dataclass(frozen=True, slots=True)
class Var:
    """A logic variable.  Anonymous ``_`` variables are given unique names
    (``_1``, ``_2`` ...) by the parser, so every ``Var`` is a named variable."""

    name: str

    def __str__(self) -> str:
        return self.name


@dataclass(frozen=True, slots=True)
class Const:
    """A constant term."""

    value: ConstantValue

    def __str__(self) -> str:
        return str(self.value)


Term = Union[Var, Const]


@dataclass(frozen=True, slots=True)
class Atom:
    """``pred(arg, ...)``."""

    pred: str
    args: tuple[Term, ...]

    @property
    def key(self) -> PredicateKey:
        return (self.pred, len(self.args))

    def variables(self) -> set[str]:
        return {t.name for t in self.args if isinstance(t, Var)}

    def __str__(self) -> str:
        return f"{self.pred}({', '.join(map(str, self.args))})"


@dataclass(frozen=True, slots=True)
class Not:
    """A negated body atom, ``not pred(arg, ...)``."""

    atom: Atom

    def variables(self) -> set[str]:
        return self.atom.variables()

    def __str__(self) -> str:
        return f"not {self.atom}"


#: Comparison operators accepted in rule bodies.
COMPARISON_OPS = ("<", "<=", ">", ">=", "=", "!=")


@dataclass(frozen=True, slots=True)
class Comparison:
    """A built-in comparison ``left op right``."""

    op: str
    left: Term
    right: Term

    def variables(self) -> set[str]:
        return {t.name for t in (self.left, self.right) if isinstance(t, Var)}

    def __str__(self) -> str:
        return f"{self.left} {self.op} {self.right}"


Literal = Union[Atom, Not, Comparison]


@dataclass(frozen=True, slots=True)
class Rule:
    """``head :- body.``  A fact is a rule with an empty body."""

    head: Atom
    body: tuple[Literal, ...] = ()

    def __str__(self) -> str:
        if not self.body:
            return f"{self.head}."
        return f"{self.head} :- {', '.join(map(str, self.body))}."


@dataclass(frozen=True, slots=True)
class Query:
    """``?- atom.``"""

    atom: Atom

    def __str__(self) -> str:
        return f"?- {self.atom}."


@dataclass(frozen=True, slots=True)
class Program:
    """A parsed program: facts and rules (in ``rules``) plus the queries, each
    in source order."""

    rules: tuple[Rule, ...]
    queries: tuple[Query, ...]
