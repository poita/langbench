"""The deterministic parallel-build simulation.

:func:`simulate` runs the specification's event loop: cache hits are settled
at the current instant, ready steps are dispatched lowest-serial-first to the
lowest-numbered free worker, and the clock jumps to the next completion.
Ready sets are heaps, so every ready-set operation is O(log R).
"""

from __future__ import annotations

import heapq
from dataclasses import dataclass, field
from typing import Sequence

from .commands import CommandResult
from .errors import KilnError
from .graph import PHONY, SOURCE, STEP, Node
from .state import StateEntry, is_fresh
from .vfs import VirtualFS

__all__ = ["Event", "Schedule", "simulate"]


@dataclass(slots=True)
class Event:
    """One log event of a build: ``hit``, ``run``, ``fail`` or ``cancel``."""

    kind: str
    serial: int
    start: int
    end: int
    worker: int
    target: bytes
    command: bytes


@dataclass
class Schedule:
    """The outcome of a simulated build."""

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
    in_hashes: list[tuple[bytes, bytes]]
    dep_hashes: list[tuple[bytes, bytes]]


def simulate(
    nodes: Sequence[Node],
    jobs: int,
    fs: VirtualFS,
    state: dict[bytes, StateEntry],
) -> Schedule:
    """Run the build over the reachable ``nodes``.

    ``fs`` and ``state`` are updated in place: successful steps write their
    outputs and replace their state entries; failed and cancelled steps lose
    their entries.
    """
    sched = Schedule()
    events = sched.events

    # Pending counts and reverse edges over the reachable set.
    for n in nodes:
        n.pending = len(n.succ)
    for n in nodes:
        for s in n.succ:
            s.dependents.append(n)

    undecided: list[tuple[int, Node]] = []   # steps ready but not yet checked
    stale: list[tuple[int, Node]] = []       # steps ready and known stale

    def complete(start: Node) -> None:
        stack = [start]
        while stack:
            n = stack.pop()
            for d in n.dependents:
                d.pending -= 1
                if d.pending == 0:
                    if d.kind == STEP:
                        heapq.heappush(undecided, (d.serial, d))
                    else:
                        stack.append(d)

    # Initialisation: sources complete at time 0; childless phonies too.
    initial = [n for n in nodes if n.kind == SOURCE or n.pending == 0]
    for n in initial:
        if n.kind == STEP:
            heapq.heappush(undecided, (n.serial, n))
        else:
            complete(n)

    time = 0
    free = list(range(jobs))               # a sorted list is a valid min-heap
    finishing: list[tuple[int, int]] = []  # heap of (end time, worker)
    running: dict[int, _Running] = {}

    while True:
        # (A) settle cache hits at the current time
        while undecided:
            _, n = heapq.heappop(undecided)
            step = n.step
            if is_fresh(state.get(step.primary), step, fs):
                sched.hits += 1
                events.append(Event("hit", n.serial, time, time, 0, step.primary, step.command))
                complete(n)
            else:
                heapq.heappush(stale, (n.serial, n))

        # (B) dispatch
        while stale and free:
            _, n = heapq.heappop(stale)
            w = heapq.heappop(free)
            step = n.step
            end = time + step.cost
            event = Event("run", n.serial, time, end, w, step.primary, step.command)
            events.append(event)
            running[w] = _execute(n, event, fs)
            heapq.heappush(finishing, (end, w))

        # (C) advance the clock
        if not running:
            break
        time = finishing[0][0]
        done: list[_Running] = []
        failed: list[_Running] = []
        while finishing and finishing[0][0] == time:
            _, w = heapq.heappop(finishing)
            r = running.pop(w)
            heapq.heappush(free, w)
            if r.error is not None:
                r.event.kind = "fail"
                failed.append(r)
                continue
            _commit(r, fs, state)
            sched.ran += 1
            done.append(r)
        if failed:
            failed.sort(key=lambda r: r.node.serial)
            sched.error = failed[0].error
            for w in sorted(running):
                r = running[w]
                r.event.kind = "cancel"
                state.pop(r.node.step.primary, None)
            for r in failed:
                state.pop(r.node.step.primary, None)
            break
        for r in done:
            complete(r.node)

    events.sort(key=lambda e: (e.start, e.serial))
    sched.time = max([0] + [e.end for e in events])
    return sched


def _execute(node: Node, event: Event, fs: VirtualFS) -> _Running:
    """Run the step's command against the workspace as it stands now.

    A command reads everything at its start time, so it is evaluated here;
    its outputs are only written when the simulated clock reaches its end.
    """
    step = node.step
    paths = step.file_inputs
    contents = [fs.read(p) for p in paths]
    try:
        result = step.spec.run(step.args, paths, contents, fs.read)
    except KilnError as err:
        return _Running(node, event, None, err, [], [])
    in_hashes = [(p, fs.hash(p)) for p in paths]
    dep_hashes = [(p, fs.hash(p)) for p in result.discovered]
    return _Running(node, event, result, None, in_hashes, dep_hashes)


def _commit(r: _Running, fs: VirtualFS, state: dict[bytes, StateEntry]) -> None:
    """Write a finished step's outputs and replace its state entry."""
    step = r.node.step
    result = r.result
    fs.write(step.outs[0], result.content)
    outs = [(step.outs[0], fs.hash(step.outs[0]))]
    if step.depfile is not None:
        fs.write(step.depfile, result.depfile)
        outs.append((step.depfile, fs.hash(step.depfile)))
    state[step.primary] = StateEntry(
        step.primary, step.command, r.in_hashes, r.dep_hashes, outs
    )
