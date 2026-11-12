"""Kiln: an incremental build system over a virtual file system.

Public API
----------
:class:`VirtualFS`
    The in-memory workspace (path -> bytes, with hashes and a glob index).
:class:`Builder`
    Runs builds (``Builder(vfs).build(targets, workers)``) and maintains
    ``.kiln-state``.
:func:`run_session`
    Runs a ``session.txt`` script and returns the log text.
:func:`parse_file`, :func:`evaluate`
    Parse a KBL build file; evaluate a workspace's build files into steps.
:class:`KilnError`
    The single error a failed build reports.
"""

from .build import Builder, BuildResult
from .errors import KilnError
from .evaluator import Evaluation, evaluate
from .hashing import fnv1a64, hash_hex
from .parser import parse_file
from .session import parse_session, run_session
from .vfs import VirtualFS

__version__ = "1.0.0"

__all__ = [
    "BuildResult",
    "Builder",
    "Evaluation",
    "KilnError",
    "VirtualFS",
    "evaluate",
    "fnv1a64",
    "hash_hex",
    "parse_file",
    "parse_session",
    "run_session",
]
