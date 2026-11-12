"""One ``build``: the eight phases of the build algorithm."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Sequence

from .errors import KilnError
from .evaluator import evaluate
from .graph import Graph
from .paths import BUILD_FILE, STATE_PATH
from .scheduler import Event, simulate
from .state import parse_state, render_state
from .vfs import VirtualFS

__all__ = ["BuildResult", "build"]


@dataclass
class BuildResult:
    """The outcome of a build."""

    events: list[Event] = field(default_factory=list)
    ran: int = 0
    hits: int = 0
    time: int = 0
    error: KilnError | None = None

    @property
    def ok(self) -> bool:
        return self.error is None


def build(fs: VirtualFS, targets: Sequence[bytes] = (), jobs: int = 1) -> BuildResult:
    """Run a build of ``targets`` (the defaults if empty) on ``jobs`` workers.

    Configuration errors (phases 1-5) leave ``fs`` untouched and are returned
    in :attr:`BuildResult.error`.  Execution errors still update the workspace
    and ``.kiln-state``.
    """
    try:
        if not fs.exists(BUILD_FILE):
            raise KilnError("E_NO_BUILD_FILE", BUILD_FILE)
        program = evaluate(fs)
        graph = Graph(program, fs)
        roots = graph.request(targets)
        reachable = graph.reachable(roots)
    except KilnError as err:
        return BuildResult(error=err)

    state = parse_state(fs.read(STATE_PATH))
    sched = simulate(reachable, jobs, fs, state)
    fs.write(STATE_PATH, render_state(state))
    return BuildResult(sched.events, sched.ran, sched.hits, sched.time, sched.error)
