"""Abstract syntax of Datalog programs.

A *constant* is a Python ``int`` (an integer constant) or ``str`` (an
identifier constant).  A *term* is a constant or a :class:`Variable`.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator

Constant = int | str


@dataclass(frozen=True, slots=True)
class Variable:
    """A rule variable.  Each anonymous ``_`` gets its own unique name."""

    name: str


Term = Constant | Variable

#: A predicate is identified by its name together with its arity.
Signature = tuple[str, int]


@dataclass(frozen=True, slots=True)
class Atom:
    """``predicate(arg, ...)``."""

    predicate: str
    args: tuple[Term, ...]

    @property
    def signature(self) -> Signature:
        return (self.predicate, len(self.args))

    def variables(self) -> Iterator[Variable]:
        return (a for a in self.args if isinstance(a, Variable))


@dataclass(frozen=True, slots=True)
class Literal:
    """An atom in a rule body, optionally negated (``not atom``)."""

    atom: Atom
    negated: bool = False


COMPARISON_OPERATORS = ("<", "<=", ">", ">=", "=", "!=")


@dataclass(frozen=True, slots=True)
class Comparison:
    """A built-in comparison ``left op right`` in a rule body."""

    op: str
    left: Term
    right: Term

    def variables(self) -> Iterator[Variable]:
        return (t for t in (self.left, self.right) if isinstance(t, Variable))


BodyItem = Literal | Comparison


@dataclass(frozen=True, slots=True)
class Rule:
    """``head :- body.``; a fact is a rule with an empty body."""

    head: Atom
    body: tuple[BodyItem, ...] = ()

    @property
    def is_fact(self) -> bool:
        return not self.body


@dataclass(slots=True)
class Program:
    """A parsed program: its rules (including facts) and its queries, each in
    source order."""

    rules: list[Rule] = field(default_factory=list)
    queries: list[Atom] = field(default_factory=list)

    def constants(self) -> set[Constant]:
        """Every constant mentioned anywhere in the program."""
        found: set[Constant] = set()

        def scan(terms: tuple[Term, ...] | list[Term]) -> None:
            found.update(t for t in terms if not isinstance(t, Variable))

        for rule in self.rules:
            scan(rule.head.args)
            for item in rule.body:
                if isinstance(item, Literal):
                    scan(item.atom.args)
                else:
                    scan([item.left, item.right])
        for query in self.queries:
            scan(query.args)
        return found


def constant_key(c: Constant) -> tuple[int, int | str]:
    """Sort key implementing the total order on constants: integers (numeric)
    before identifiers (ASCII order)."""
    return (0, c) if isinstance(c, int) else (1, c)
