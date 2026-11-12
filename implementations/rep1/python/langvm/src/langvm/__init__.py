"""langvm: a compiler and stack virtual machine for the Vellum language.

Public API
----------
``run_source(text)``
    Compile and run a module stream; returns a :class:`RunResult` whose
    ``output`` is exactly what the ``langvm`` command prints.
``compile_program(text)``
    Compile only; returns a bytecode :class:`Image` or raises
    :class:`CompileError`.
``VM(image, out)``
    Execute an image, appending output chunks to the list ``out``; raises
    :class:`Panic` on a run-time error.
"""

from .api import CompileError, Panic, RunResult, compile_program, run_source
from .compiler import Image
from .vm import VM

__all__ = [
    "CompileError", "Image", "Panic", "RunResult", "VM", "compile_program", "run_source",
]
__version__ = "0.1.0"
