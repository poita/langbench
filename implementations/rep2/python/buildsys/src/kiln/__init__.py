"""Kiln: an incremental build system over a virtual file system.

Public API
----------

* :class:`VirtualFS` -- the in-memory workspace.
* :func:`build` -- run one build; returns a :class:`BuildResult`.
* :func:`run_session` / :func:`parse_session` -- execute a session script.
* :func:`evaluate` -- evaluate build files into a :class:`Program`.
* :class:`KilnError` -- the error type of every build failure.
"""

from .build import BuildResult, build
from .errors import KilnError
from .evaluator import Program, evaluate
from .hashing import fnv1a64, hash_hex
from .session import SessionStep, parse_session, run_session, run_session_dir
from .vfs import VirtualFS

__all__ = [
    "VirtualFS", "build", "BuildResult", "evaluate", "Program", "KilnError",
    "run_session", "run_session_dir", "parse_session", "SessionStep",
    "fnv1a64", "hash_hex",
]
__version__ = "1.0.0"
