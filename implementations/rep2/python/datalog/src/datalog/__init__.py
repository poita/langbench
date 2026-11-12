"""A Datalog engine with stratified negation.

Typical use::

    >>> from datalog import parse, evaluate
    >>> model = evaluate(parse("edge(1, 2). edge(2, 3). "
    ...                        "path(X, Y) :- edge(X, Y). "
    ...                        "path(X, Z) :- edge(X, Y), path(Y, Z)."))
    >>> model.relation("path", 2)
    [(1, 2), (1, 3), (2, 3)]

Public API:

* :func:`parse` -- source text to :class:`Program`
* :func:`evaluate` -- :class:`Program` to :class:`Model` (semi-naive evaluation)
* :class:`Model` -- ``relation(name, arity)`` and ``query(atom)``
* :func:`solve` -- source text to the command-line tool's output text
* :class:`DatalogError` and its subclasses ``ParseError``,
  ``UnsafeRuleError``, ``StratificationError``
"""

from .engine import Model, evaluate
from .errors import DatalogError, ParseError, StratificationError, UnsafeRuleError
from .parser import parse
from .solve import solve
from .syntax import Atom, Comparison, Literal, Program, Rule, Variable

__all__ = [
    "Atom", "Comparison", "DatalogError", "Literal", "Model", "ParseError", "Program",
    "Rule", "StratificationError", "UnsafeRuleError", "Variable", "evaluate", "parse", "solve",
]
