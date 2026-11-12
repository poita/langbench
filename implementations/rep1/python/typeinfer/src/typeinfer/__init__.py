"""typeinfer: Hindley-Milner type inference for a small ML-like language.

Public API::

    >>> from typeinfer import infer_program
    >>> [r.render() for r in infer_program("let id = fun x -> x;; id 1;;")]
    ["id : 'a -> 'a", '- : int']

* :func:`infer_program` - check a whole program, one :class:`DeclResult` each.
* :class:`Inferencer` - the stateful checker (top-level environment) behind it.
* :func:`infer_type` - principal type of a single expression, as text.
* :func:`parse_program` / :mod:`typeinfer.syntax` - the parser and the AST.
* :func:`format_type` - render a :class:`Type`.
* :class:`TypeCheckError` (:class:`UnifyError`, :class:`OccursError`,
  :class:`UnboundVariableError`) and :class:`ParseError`.

Inference recurses on nesting depth; for very deep programs call it through
:func:`run_deep`.
"""

__version__ = "1.0.0"

from .errors import (
    OccursError,
    ParseError,
    TypeCheckError,
    TypeInferError,
    UnboundVariableError,
    UnifyError,
)
from .infer import DeclResult, Inferencer, infer_program, infer_type
from .parser import parse_expr, parse_program
from .pretty import format_type
from .runtime import run_deep
from .typerep import TCon, TVar, Type

__all__ = [
    "DeclResult",
    "Inferencer",
    "OccursError",
    "ParseError",
    "TCon",
    "TVar",
    "Type",
    "TypeCheckError",
    "TypeInferError",
    "UnboundVariableError",
    "UnifyError",
    "format_type",
    "infer_program",
    "infer_type",
    "parse_expr",
    "parse_program",
    "run_deep",
]
