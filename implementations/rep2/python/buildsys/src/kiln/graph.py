"""The dependency graph: nodes, reference resolution, validation, cycles."""

from __future__ import annotations

from typing import Sequence

from .errors import KilnError
from .evaluator import Program
from .steps import Step
from .vfs import VirtualFS

__all__ = ["Node", "Graph", "STEP", "PHONY", "SOURCE"]

STEP, PHONY, SOURCE = 0, 1, 2
_WHITE, _GREY, _BLACK = 0, 1, 2


class Node:
    """A graph node: a step, a phony target or a source file."""

    __slots__ = ("kind", "name", "step", "succ", "dependents", "pending", "colour", "serial")

    def __init__(self, kind: int, name: bytes, step: Step | None = None) -> None:
        self.kind = kind
        self.name = name                # name used in messages
        self.step = step
        self.serial = step.serial if step is not None else -1
        self.succ: list[Node] = []      # ordering dependencies, deduplicated
        self.dependents: list[Node] = []
        self.pending = 0
        self.colour = _WHITE


class Graph:
    """The graph of one build, constructed and validated from a :class:`Program`."""

    def __init__(self, program: Program, fs: VirtualFS) -> None:
        self.program = program
        self.fs = fs
        self.step_nodes: list[Node] = [Node(STEP, s.primary, s) for s in program.steps]
        self._by_output: dict[bytes, Node] = {}
        self._phony: dict[bytes, Node] = {
            name: Node(PHONY, b"@" + name) for name in program.phonies
        }
        self._sources: dict[bytes, Node] = {}
        self._validate()

    # ---- construction and whole-graph validation ----------------------------------

    def _validate(self) -> None:
        program = self.program
        owner = self._by_output
        # 1. duplicate outputs
        for node in self.step_nodes:
            for path in node.step.outputs:  # type: ignore[union-attr]
                if path in owner:
                    raise KilnError("E_DUP_OUTPUT", path)
                owner[path] = node
        # 2. reference resolution (steps in serial order, then phonies)
        for node in self.step_nodes:
            step = node.step
            assert step is not None
            deps = [self._resolve_dep(r, node.name) for r in step.ins]
            deps += [self._resolve_dep(r, node.name) for r in step.afters]
            node.succ = _dedup(deps)
        for name, refs in program.phonies.items():
            node = self._phony[name]
            node.succ = _dedup([self._resolve_dep(r, node.name) for r in refs])
        # 3. the default target list
        for ref in program.defaults:
            if self.resolve(ref) is None:
                raise KilnError("E_UNKNOWN_TARGET", ref)

    def resolve(self, ref: bytes) -> Node | None:
        """Resolve a target reference to a node, or ``None``."""
        if ref.startswith(b"@"):
            return self._phony.get(ref[1:])
        node = self._by_output.get(ref)
        if node is not None:
            return node
        node = self._sources.get(ref)
        if node is None and self.fs.exists(ref):
            node = self._sources[ref] = Node(SOURCE, ref)
        return node

    def _resolve_dep(self, ref: bytes, owner_name: bytes) -> Node:
        node = self.resolve(ref)
        if node is None:
            raise KilnError("E_MISSING_INPUT", b"%b required by %b" % (ref, owner_name))
        return node

    # ---- requested targets and cycle detection -------------------------------------

    def request(self, targets: Sequence[bytes]) -> list[Node]:
        """Resolve the requested targets (the defaults when ``targets`` is empty)."""
        names = list(targets) if targets else list(self.program.defaults)
        if not names:
            raise KilnError("E_NO_DEFAULT")
        roots: list[Node] = []
        for ref in dict.fromkeys(names):
            node = self.resolve(ref)
            if node is None:
                raise KilnError("E_UNKNOWN_TARGET", ref)
            roots.append(node)
        return roots

    def reachable(self, roots: Sequence[Node]) -> list[Node]:
        """Nodes reachable from ``roots``; raises ``E_CYCLE`` if there is a cycle.

        Uses the specification's exact depth-first search so the reported cycle
        is deterministic.
        """
        order: list[Node] = []
        for root in roots:
            if root.colour != _WHITE:
                continue
            root.colour = _GREY
            order.append(root)
            stack: list[list] = [[root, 0]]
            while stack:
                top = stack[-1]
                node, i = top
                succ = node.succ
                if i < len(succ):
                    top[1] = i + 1
                    m = succ[i]
                    if m.colour == _GREY:
                        j = next(k for k, frame in enumerate(stack) if frame[0] is m)
                        names = [frame[0].name for frame in stack[j:]] + [m.name]
                        raise KilnError("E_CYCLE", b" -> ".join(names))
                    if m.colour == _WHITE:
                        m.colour = _GREY
                        order.append(m)
                        stack.append([m, 0])
                else:
                    node.colour = _BLACK
                    stack.pop()
        return order


def _dedup(nodes: list[Node]) -> list[Node]:
    seen: set[int] = set()
    out: list[Node] = []
    for n in nodes:
        k = id(n)
        if k not in seen:
            seen.add(k)
            out.append(n)
    return out
