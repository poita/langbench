"""The :class:`Interpreter`: global state plus the evaluate-and-print loop."""

from __future__ import annotations

from typing import Any, Iterator

from .analyzer import analyze
from .errors import SchemeError
from .evaluator import call
from .primitives import make_primitives
from .printer import write_string
from .reader import read_iter
from .values import PARENT, VOID


class Interpreter:
    """A Scheme interpreter with its own global environment and output.

    >>> interp = Interpreter()
    >>> interp.run("(define x 6) (* x 7)")
    '42\\n'

    Output (``display``, ``newline`` and printed top-level values) is
    accumulated and returned by :meth:`run`.  The global environment persists
    across calls to :meth:`run`.
    """

    def __init__(self) -> None:
        self._out: list[str] = []
        self.globals: dict = make_primitives(self._out.append)
        self.globals[PARENT] = None

    def eval_forms(self, source: str) -> Iterator[Any]:
        """Evaluate each top-level form of ``source`` in turn, yielding values.

        Void results are yielded as :data:`scheme_interp.values.VOID`.  Output
        produced by ``display``/``newline`` is appended to the output buffer.
        Runtime errors propagate as :class:`SchemeError`.
        """
        for datum in read_iter(source):
            yield analyze(datum, False)(self.globals)

    def run(self, source: str) -> str:
        """Run a whole program and return everything it prints.

        Each non-void top-level value is written followed by a newline.  If a
        runtime error occurs, ``error: <category>`` and a newline are appended
        to the output (without inserting anything before it) and evaluation
        stops; no exception escapes.
        """
        out = self._out
        start = len(out)
        try:
            for value in self.eval_forms(source):
                if value is not VOID:
                    out.append(write_string(value))
                    out.append("\n")
        except SchemeError as e:
            out.append(f"error: {e.category}\n")
        text = "".join(out[start:])
        del out[start:]
        return text
