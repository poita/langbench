"""Event-driven simulation of parallel step execution.

Steps become *ready* when every ordering dependency has completed.  A ready step
is immediately checked for freshness (a cache hit completes at once); stale
steps wait in a min-heap keyed by serial number and are dispatched to the
lowest-numbered free worker.  The clock then jumps to the next completion.
Every ready-set operation is O(log R).
"""

from __future__ import annotations

import heapq
from dataclasses import dataclass, field

from .commands import CommandResult
from .errors import KilnError
from .graph import PHONY, STEP, Node
from .state import State, is_fresh, make_entry
from .vfs import VirtualFS


@dataclass(slots=True)
class Event:
    """One line of a build's event log.

    ``kind`` is ``hit``, ``run``, ``fail`` or ``cancel``; for ``hit`` only
    ``start`` (the time) is meaningful.
    """

    kind: str
    serial: int
    start: int
    end: int
    worker: int
    target: bytes
    command: bytes


@dataclass(slots=True)
class Outcome:
    """The result of the scheduling phase."""

    events: list[Event] = field(default_factory=list)
    ran: int = 0
    hits: int = 0
    time: int = 0
    error: KilnError | None = None


@dataclass(slots=True)
class _Running:
    node: Node
    event: Event
    result: CommandResult | None
    error: KilnError | None
    input_hashes: list[bytes]
    dep_hashes: list[tuple[bytes, bytes]]


def execute(reachable: list[Node], vfs: VirtualFS, state: State, workers: int) -> Outcome:
    """Run the reachable part of the graph; *state* is updated in place."""
    return _Scheduler(reachable, vfs, state, workers).run()


class _Scheduler:
    def __init__(self, reachable: list[Node], vfs: VirtualFS, state: State, workers: int):
        self.reachable = reachable
        self.vfs = vfs
        self.state = state
        self.workers = workers
        self.out = Outcome()
        self.now = 0
        self.ready: list[tuple[int, Node]] = []  # stale steps, by serial
        self.free = list(range(workers))
        self.running: dict[int, _Running] = {}
        self.finish: list[tuple[int, int]] = []  # (end time, worker)

    # -- node completion ---------------------------------------------------------

    def _complete(self, first: Node) -> None:
        """Complete *first* and everything that thereby becomes ready."""
        work = [first]
        while work:
            node = work.pop()
            for dep in node.dependents:
                dep.pending -= 1
                if dep.pending:
                    continue
                if dep.kind == PHONY:
                    work.append(dep)
                elif self._decide(dep):
                    work.append(dep)

    def _decide(self, node: Node) -> bool:
        """Freshness decision for a newly ready step; True when it is a hit."""
        step = node.step
        assert step is not None
        if is_fresh(step, self.state.get(step.primary), self.vfs):
            self.out.hits += 1
            self.out.events.append(
                Event("hit", step.serial, self.now, self.now, -1, step.primary, step.command)
            )
            return True
        heapq.heappush(self.ready, (step.serial, node))
        return False

    # -- the main loop -------------------------------------------------------------

    def run(self) -> Outcome:
        out = self.out
        for node in [n for n in self.reachable if not n.pending]:
            if node.kind == STEP:
                if self._decide(node):
                    self._complete(node)
            else:
                self._complete(node)
        while True:
            self._dispatch()
            if not self.finish:
                break
            self.now = self.finish[0][0]
            if self._advance():
                break
        out.time = max(
            [0] + [e.start for e in out.events if e.kind == "hit"]
            + [e.end for e in out.events if e.kind != "hit"]
        )
        out.events.sort(key=lambda e: (e.start, e.serial))
        return out

    def _dispatch(self) -> None:
        ready, free = self.ready, self.free
        vfs = self.vfs
        while ready and free:
            _serial, node = heapq.heappop(ready)
            worker = heapq.heappop(free)
            step = node.step
            assert step is not None
            end = self.now + step.cost
            event = Event("run", step.serial, self.now, end, worker, step.primary, step.command)
            self.out.events.append(event)
            # The command reads everything it needs now ...
            inputs = [(p, vfs.read(p)) for p in step.file_inputs]
            result = error = None
            dep_hashes: list[tuple[bytes, bytes]] = []
            try:
                result = step.spec.run(step.cmd_args, inputs, vfs.get)
                for path in result.discovered:
                    dep_hashes.append((path, vfs.hash_content(vfs.read(path))))
            except KilnError as exc:
                error = exc
            hashes = [vfs.hash_content(c) for _p, c in inputs]
            self.running[worker] = _Running(node, event, result, error, hashes, dep_hashes)
            heapq.heappush(self.finish, (end, worker))

    def _advance(self) -> bool:
        """Advance the clock to the next completion; True when the build aborts."""
        finish, vfs = self.finish, self.vfs
        done = []
        while finish and finish[0][0] == self.now:
            done.append(heapq.heappop(finish)[1])  # ascending worker id
        failed: list[_Running] = []
        finished: list[_Running] = []
        for worker in done:
            heapq.heappush(self.free, worker)
            run = self.running.pop(worker)
            if run.error is not None:
                run.event.kind = "fail"
                failed.append(run)
                continue
            step = run.node.step
            result = run.result
            assert step is not None and result is not None
            contents = [result.output]
            if result.depfile is not None:
                contents.append(result.depfile)
            for path, content in zip(step.full_outputs, contents):
                vfs.write(path, content)
            out_hashes = [vfs.hash_content(c) for c in contents]
            self.state[step.primary] = make_entry(
                step, run.input_hashes, run.dep_hashes, out_hashes
            )
            self.out.ran += 1
            finished.append(run)
        if failed:
            failed.sort(key=lambda r: r.event.serial)
            self.out.error = failed[0].error
            for worker in sorted(self.running):
                run = self.running[worker]
                run.event.kind = "cancel"
                self.state.pop(run.node.step.primary, None)  # type: ignore[union-attr]
            for run in failed:
                self.state.pop(run.node.step.primary, None)  # type: ignore[union-attr]
            return True
        for run in finished:
            self._complete(run.node)
        return False
