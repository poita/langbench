"""One build: configuration phases followed by scheduling and execution."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field

from .errors import KilnError
from .evaluator import evaluate
from .graph import Graph
from .paths import STATE_FILE
from .scheduler import Event, execute
from .state import State, parse_state, render_state
from .vfs import VirtualFS

ROOT_BUILD_FILE = b"main.kiln"


@dataclass(slots=True)
class BuildResult:
    """The outcome of a build.

    A configuration error leaves ``events`` empty and the workspace untouched.
    An execution error keeps the events scheduled so far.
    """

    error: KilnError | None = None
    events: list[Event] = field(default_factory=list)
    ran: int = 0
    hits: int = 0
    time: int = 0

    @property
    def ok(self) -> bool:
        return self.error is None


class Builder:
    """Runs builds against one :class:`VirtualFS`.

    Every :meth:`build` evaluates the build files afresh; only the file system
    (with its hashes and glob index) and a memo of the last parsed state file
    persist between builds.
    """

    def __init__(self, vfs: VirtualFS) -> None:
        self.vfs = vfs
        self._state_src: bytes | None = None
        self._state_val: State = {}

    def _load_state(self) -> State:
        content = self.vfs.get(STATE_FILE)
        if content is None or content != self._state_src:
            self._state_val = parse_state(content)
            self._state_src = content
        return dict(self._state_val)

    def build(self, targets: Sequence[bytes] = (), workers: int = 1) -> BuildResult:
        """Build *targets* (the default targets when empty) on *workers* workers."""
        vfs = self.vfs
        try:
            if ROOT_BUILD_FILE not in vfs:
                raise KilnError("E_NO_BUILD_FILE", ROOT_BUILD_FILE)
            evaluation = evaluate(vfs, ROOT_BUILD_FILE)
            graph = Graph(evaluation, vfs)
            graph.validate()
            roots = graph.request(targets)
            reachable = graph.reachable(roots)
        except KilnError as exc:
            return BuildResult(error=exc)
        state = self._load_state()
        outcome = execute(reachable, vfs, state, workers)
        content = render_state(state)
        vfs.write(STATE_FILE, content)
        self._state_src = content
        self._state_val = state
        return BuildResult(
            error=outcome.error,
            events=outcome.events,
            ran=outcome.ran,
            hits=outcome.hits,
            time=outcome.time,
        )
