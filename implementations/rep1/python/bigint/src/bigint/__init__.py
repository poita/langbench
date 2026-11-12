"""Arbitrary-precision signed integer arithmetic, implemented from scratch.

Public API:

* :class:`BigInt` -- an immutable signed integer of unbounded size, built from
  and printed as decimal strings.
* :func:`evaluate_query` -- evaluate one ``"<a> <op> <b>"`` query line.
* :func:`evaluate_queries` -- evaluate many query lines.
* :class:`QueryError` -- raised by the query functions for the ``error`` cases.

The arithmetic lives in :mod:`bigint.magnitude` (unsigned digit-array
algorithms) and is wrapped with signs in :mod:`bigint.integer`.
"""

from .integer import BigInt
from .queries import QueryError, evaluate_queries, evaluate_query

__all__ = ["BigInt", "QueryError", "evaluate_query", "evaluate_queries"]
__version__ = "1.0.0"
