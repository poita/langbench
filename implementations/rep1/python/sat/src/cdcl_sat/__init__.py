"""cdcl_sat: a MiniSat-style CDCL SAT solver in pure Python.

Public API::

    from cdcl_sat import solve, Solver, parse_dimacs, format_result

* :func:`solve` -- one-shot: ``solve(num_vars, clauses)`` returns a model or ``None``.
* :class:`Solver` -- incremental clause addition, then :meth:`Solver.solve`.
* :func:`parse_dimacs` / :func:`format_result` -- DIMACS CNF input and the
  ``SAT`` / ``UNSAT`` output format.

Literals are non-zero DIMACS integers: ``k`` is variable *k* true, ``-k`` false.
"""

from .dimacs import CNF, format_result, parse_dimacs
from .solver import Solver, solve

__all__ = ["CNF", "Solver", "format_result", "parse_dimacs", "solve"]
__version__ = "1.0.0"
