"""The dependency graph: validation, target resolution, cycles, reachability."""

from __future__ import annotations

from collections.abc import Sequence

from .errors import KilnError
from .evaluator import Evaluation
from .steps import Step
from .vfs import VirtualFS

STEP, PHONY, SOURCE = 0, 1, 2


class Node:
    """A graph node: a step, a phony target or a source file."""

    __slots__ = ("kind", "name", "step", "succ", "dependents", "pending", "colour")

    def __init__(self, kind: int, name: bytes, step: Step | None = None) -> None:
        self.kind = kind
        self.name = name  # name used in messages
        self.step = step
        self.succ: list[Node] = []  # distinct ordering dependencies
        self.dependents: list[Node] = []
        self.pending = 0
        self.colour = 0  # 0 white, 1 grey, 2 black

    def __repr__(self) -> str:
        return f"Node({self.name!r})"


class Graph:
    """The graph of one build, built from an :class:`Evaluation`."""

    def __init__(self, evaluation: Evaluation, vfs: VirtualFS) -> None:
        self.evaluation = evaluation
        self.vfs = vfs
        self.step_nodes: list[Node] = [Node(STEP, s.primary, s) for s in evaluation.steps]
        self.phony_nodes: dict[bytes, Node] = {
            name: Node(PHONY, b"@" + name) for name in evaluation.phonies
        }
        self._by_output: dict[bytes, Node] = {}
        self._sources: dict[bytes, Node] = {}

    # -- validation ------------------------------------------------------------

    def validate(self) -> None:
        """Whole-graph validation; also computes every node's successor list."""
        self._check_duplicate_outputs()
        self._resolve_references()
        for ref in self.evaluation.defaults:
            if self.resolve(ref) is None:
                raise KilnError("E_UNKNOWN_TARGET", ref)

    def _check_duplicate_outputs(self) -> None:
        claimed = self._by_output
        for node in self.step_nodes:
            for out in node.step.full_outputs:  # type: ignore[union-attr]
                if out in claimed:
                    raise KilnError("E_DUP_OUTPUT", out)
                claimed[out] = node

    def _resolve_references(self) -> None:
        for node in self.step_nodes:
            step = node.step
            assert step is not None
            deps = [self._require(ref, node) for ref in step.inputs]
            deps += [self._require(ref, node) for ref in step.after]
            node.succ = _distinct(deps)
        for name, refs in self.evaluation.phonies.items():
            node = self.phony_nodes[name]
            node.succ = _distinct([self._require(ref, node) for ref in refs])

    def _require(self, ref: bytes, owner: Node) -> Node:
        node = self.resolve(ref)
        if node is None:
            raise KilnError("E_MISSING_INPUT", ref + b" required by " + owner.name)
        return node

    def resolve(self, ref: bytes) -> Node | None:
        """Resolve a target reference to a node, or ``None``."""
        if ref[:1] == b"@":
            return self.phony_nodes.get(ref[1:])
        node = self._by_output.get(ref)
        if node is not None:
            return node
        node = self._sources.get(ref)
        if node is None and ref in self.vfs:
            node = self._sources[ref] = Node(SOURCE, ref)
        return node

    # -- targets, cycles, reachability -------------------------------------------

    def request(self, targets: Sequence[bytes]) -> list[Node]:
        """Resolve the requested targets (the default list when none given)."""
        wanted = _distinct(targets if targets else self.evaluation.defaults)
        if not wanted:
            raise KilnError("E_NO_DEFAULT")
        nodes = []
        for ref in wanted:
            node = self.resolve(ref)
            if node is None:
                raise KilnError("E_UNKNOWN_TARGET", ref)
            nodes.append(node)
        return nodes

    def reachable(self, roots: Sequence[Node]) -> list[Node]:
        """Detect cycles from *roots* and return the reachable nodes.

        Uses the specification's exact depth-first search so the reported
        cycle is deterministic.  Raises ``E_CYCLE``.
        """
        visited: list[Node] = []
        for root in roots:
            if root.colour != 0:
                continue
            root.colour = 1
            visited.append(root)
            stack: list[list] = [[root, 0]]
            position = {id(root): 0}
            while stack:
                top = stack[-1]
                node, i = top
                succ = node.succ
                if i < len(succ):
                    top[1] = i + 1
                    m = succ[i]
                    if m.colour == 1:
                        j = position[id(m)]
                        names = [entry[0].name for entry in stack[j:]] + [m.name]
                        raise KilnError("E_CYCLE", b" -> ".join(names))
                    if m.colour == 0:
                        m.colour = 1
                        visited.append(m)
                        position[id(m)] = len(stack)
                        stack.append([m, 0])
                else:
                    node.colour = 2
                    del position[id(node)]
                    stack.pop()
        for node in visited:
            for s in node.succ:
                s.dependents.append(node)
            node.pending = len(node.succ)
        return visited


def _distinct(items: Sequence) -> list:
    """Remove duplicates keeping the first occurrence."""
    seen = set()
    out = []
    for x in items:
        key = id(x) if not isinstance(x, bytes) else x
        if key not in seen:
            seen.add(key)
            out.append(x)
    return out
