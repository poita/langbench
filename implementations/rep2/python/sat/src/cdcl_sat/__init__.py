"""cdcl_sat: a MiniSat-style CDCL SAT solver in pure Python.

Public API
----------
:class:`Solver`
    Incremental-style solver: ``add_clause`` then ``solve``.
:func:`solve`
    One-shot helper taking DIMACS-style integer clauses.
:func:`parse_dimacs`, :func:`format_result`, :class:`Cnf`
    DIMACS CNF reading and result formatting.
"""

from .dimacs import Cnf, format_result, parse_dimacs
from .solver import Solver, solve

__all__ = ["Cnf", "Solver", "format_result", "parse_dimacs", "solve"]
__version__ = "1.0.0"
