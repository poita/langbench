"""A small Scheme interpreter.

Public API::

    from scheme_interp import run_program, Interpreter

    run_program("(display (+ 1 2))")      # -> '3'
    interp = Interpreter()
    interp.run("(define x 10)")           # globals persist across run() calls
    interp.run("(* x x)")                 # -> '100\\n'

Lower-level pieces: :func:`read_all` (reader), :func:`write_string` /
:func:`display_string` (printer), :mod:`scheme_interp.bignum` (arithmetic).
"""

from .errors import SchemeError, SchemeSyntaxError
from .interpreter import Interpreter
from .printer import display_string, write_string
from .reader import read_all, read_iter
from .runner import call_with_deep_stack, run_program

__all__ = [
    "Interpreter",
    "SchemeError",
    "SchemeSyntaxError",
    "call_with_deep_stack",
    "display_string",
    "read_all",
    "read_iter",
    "run_program",
    "write_string",
]
__version__ = "1.0.0"
