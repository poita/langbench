"""datalog -- a Datalog engine with stratified negation.

Typical use::

    >>> import datalog
    >>> program = datalog.parse("edge(1, 2). edge(2, 3). "
    ...                         "path(X, Y) :- edge(X, Y). "
    ...                         "path(X, Z) :- edge(X, Y), path(Y, Z).")
    >>> model = datalog.evaluate(program)
    >>> model.query("path(1, X)")
    [(1, 2), (1, 3)]

Public API:

* :func:`parse` / :func:`parse_atom` -- text to syntax tree;
* :func:`evaluate` -- check a :class:`Program` and compute its :class:`Model`;
* :meth:`Model.query` / :meth:`Model.relation` -- read the result;
* :func:`run` -- text in, command-line-tool output out;
* :class:`DatalogError` and subclasses -- raised for malformed, unsafe or
  unstratifiable programs.
"""

from .api import answer, format_row, run
from .engine import Model, evaluate
from .errors import DatalogError, ParseError, StratificationError, UnsafeRuleError
from .parser import parse, parse_atom
from .syntax import Atom, Comparison, Const, Not, Program, Query, Rule, Var

__all__ = [
    "Atom", "Comparison", "Const", "DatalogError", "Model", "Not", "ParseError",
    "Program", "Query", "Rule", "StratificationError", "UnsafeRuleError", "Var",
    "answer", "evaluate", "format_row", "parse", "parse_atom", "run",
]
__version__ = "1.0.0"
