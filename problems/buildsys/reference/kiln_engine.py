"""Graph construction, the state file, the command set and the scheduler."""
import heapq

from kiln_err import KilnError
from kiln_vfs import (is_ws_path, is_ident, is_generated, STATE_PATH,
                      lines_of, join_lines, hexhash)
from kbl_funcs import _replace_bytes
from kbl_eval import COMMANDS, evaluate_build


# ------------------------------------------------------------------ graph

class GraphNode(object):
    __slots__ = ("kind", "name", "step", "succs", "serial")

    def __init__(self, kind, name, step=None):
        self.kind = kind
        self.name = name
        self.step = step
        self.succs = []
        self.serial = step.serial if step is not None else -1


class Graph(object):
    """The three-kinded dependency graph of one build."""

    def __init__(self, build, workspace):
        self.build = build
        self.ws = workspace
        self.nodes = {}
        self.outmap = {}
        self._build_nodes()

    def _build_nodes(self):
        build = self.build
        for step in build.steps:
            for p in step.full_outs:
                if p in self.outmap:
                    raise KilnError(b"E_DUP_OUTPUT", p)
                self.outmap[p] = step
        for step in build.steps:
            self.nodes[step.primary] = GraphNode(b"step", step.primary, step)
        for name in build.phony_order:
            self.nodes[b"@" + name] = GraphNode(b"phony", b"@" + name)

    def resolve(self, ref):
        """Resolve a target reference to a node, or None."""
        if ref.startswith(b"@"):
            name = ref[1:]
            if name in self.build.phony:
                return self.nodes[ref]
            return None
        step = self.outmap.get(ref)
        if step is not None:
            return self.nodes[step.primary]
        if self.ws.exists(ref):
            node = self.nodes.get(ref)
            if node is None:
                node = GraphNode(b"source", ref)
                self.nodes[ref] = node
            return node
        return None

    def validate(self):
        """Phase 3: reference resolution, then the default list."""
        for step in self.build.steps:
            for ref in step.ins:
                if self.resolve(ref) is None:
                    raise KilnError(
                        b"E_MISSING_INPUT",
                        ref + b" required by " + step.primary)
            for ref in step.afters:
                if self.resolve(ref) is None:
                    raise KilnError(
                        b"E_MISSING_INPUT",
                        ref + b" required by " + step.primary)
        for name in self.build.phony_order:
            for dep in self.build.phony[name]:
                if self.resolve(dep) is None:
                    raise KilnError(
                        b"E_MISSING_INPUT",
                        dep + b" required by @" + name)
        for target in self.build.defaults:
            if self.resolve(target) is None:
                raise KilnError(b"E_UNKNOWN_TARGET", target)
        self._link()

    def _link(self):
        for step in self.build.steps:
            node = self.nodes[step.primary]
            node.succs = _dedup(
                [self.resolve(r) for r in step.ins] +
                [self.resolve(r) for r in step.afters])
        for name in self.build.phony_order:
            node = self.nodes[b"@" + name]
            node.succs = _dedup(
                [self.resolve(d) for d in self.build.phony[name]])

    def requested(self, targets):
        """Phase 4: the requested target nodes."""
        if targets:
            refs = _dedup(targets)
        else:
            refs = _dedup(self.build.defaults)
            if not refs:
                raise KilnError(b"E_NO_DEFAULT")
        nodes = []
        for ref in refs:
            node = self.resolve(ref)
            if node is None:
                raise KilnError(b"E_UNKNOWN_TARGET", ref)
            nodes.append(node)
        return _dedup(nodes)

    def cycle_check(self, roots):
        """Phase 5: the deterministic depth-first search. Returns the
        reachable set."""
        WHITE, GREY, BLACK = 0, 1, 2
        colour = {}
        for node in self.nodes.values():
            colour[id(node)] = WHITE
        for root in roots:
            if colour[id(root)] != WHITE:
                continue
            colour[id(root)] = GREY
            stack = [[root, 0]]
            while stack:
                top = stack[-1]
                node, i = top[0], top[1]
                if i < len(node.succs):
                    top[1] = i + 1
                    m = node.succs[i]
                    if colour[id(m)] == GREY:
                        j = 0
                        for k, frame in enumerate(stack):
                            if frame[0] is m:
                                j = k
                                break
                        names = [frame[0].name for frame in stack[j:]]
                        names.append(m.name)
                        raise KilnError(b"E_CYCLE", b" -> ".join(names))
                    if colour[id(m)] == WHITE:
                        colour[id(m)] = GREY
                        stack.append([m, 0])
                else:
                    colour[id(node)] = BLACK
                    stack.pop()
        return [n for n in self.nodes.values() if colour[id(n)] != WHITE]


def _dedup(seq):
    out = []
    seen = set()
    for x in seq:
        key = id(x) if isinstance(x, GraphNode) else x
        if key in seen:
            continue
        seen.add(key)
        out.append(x)
    return out


# ------------------------------------------------------------- state file

class Entry(object):
    __slots__ = ("cmd", "ins", "deps", "outs")

    def __init__(self, cmd, ins, deps, outs):
        self.cmd = cmd
        self.ins = ins
        self.deps = deps
        self.outs = outs


class _Reject(Exception):
    pass


def _hexok(h):
    if len(h) != 16:
        return False
    for c in h:
        if not (48 <= c <= 57 or 97 <= c <= 102):
            return False
    return True


def _parse_pair(rest):
    parts = rest.split(b" ")
    if len(parts) != 2:
        raise _Reject()
    path, h = parts
    if not is_ws_path(path) or not _hexok(h):
        raise _Reject()
    return (path, h)


def read_state(ws):
    """Read ``.kiln-state``; any deviation yields the empty state."""
    if not ws.exists(STATE_PATH):
        return {}
    data = ws.read(STATE_PATH)
    try:
        if not data.endswith(b"\n"):
            raise _Reject()
        lines = data[:-1].split(b"\n")
        if not lines or lines[0] != b"kiln-state 1":
            raise _Reject()
        entries = {}
        i = 1
        n = len(lines)
        while i < n:
            line = lines[i]
            if not line.startswith(b"step "):
                raise _Reject()
            key = line[5:]
            if not is_ws_path(key):
                raise _Reject()
            i += 1
            if i >= n or not lines[i].startswith(b"cmd "):
                raise _Reject()
            cmd = lines[i][4:]
            if not cmd:
                raise _Reject()
            i += 1
            ins = []
            deps = []
            outs = []
            while i < n and lines[i].startswith(b"in "):
                ins.append(_parse_pair(lines[i][3:]))
                i += 1
            while i < n and lines[i].startswith(b"dep "):
                deps.append(_parse_pair(lines[i][4:]))
                i += 1
            while i < n and lines[i].startswith(b"out "):
                outs.append(_parse_pair(lines[i][4:]))
                i += 1
            if not outs:
                raise _Reject()
            if i >= n or lines[i] != b"end":
                raise _Reject()
            i += 1
            if key in entries or outs[0][0] != key:
                raise _Reject()
            entries[key] = Entry(cmd, ins, deps, outs)
        return entries
    except _Reject:
        return {}


def write_state(ws, state):
    out = [b"kiln-state 1"]
    for key in sorted(state):
        e = state[key]
        out.append(b"step " + key)
        out.append(b"cmd " + e.cmd)
        for p, h in e.ins:
            out.append(b"in " + p + b" " + h)
        for p, h in e.deps:
            out.append(b"dep " + p + b" " + h)
        for p, h in e.outs:
            out.append(b"out " + p + b" " + h)
        out.append(b"end")
    ws.write(STATE_PATH, b"\n".join(out) + b"\n")


def is_stale(step, state, ws):
    """The seven change-detection rules."""
    e = state.get(step.primary)
    if e is None:
        return True
    if e.cmd != step.cmd_string:
        return True
    if [p for p, _ in e.outs] != step.full_outs:
        return True
    if [p for p, _ in e.ins] != step.file_inputs:
        return True
    for group in (e.ins, e.deps, e.outs):
        for p, h in group:
            if not ws.exists(p) or ws.hash_of(p) != h:
                return True
    return False


# --------------------------------------------------------------- commands

class CommandResult(object):
    __slots__ = ("ins", "outs", "deps", "error")

    def __init__(self, ins=None, outs=None, deps=None, error=None):
        self.ins = ins or []
        self.outs = outs or []
        self.deps = deps or []
        self.error = error


def _preprocess(ws, root):
    emitted = []
    discovered = set()
    stack = []

    def expand(p):
        stack.append(p)
        for line in lines_of(ws.read(p)):
            if line.startswith(b"@need ") and len(line) > 6:
                q = line[6:]
                if not is_ws_path(q):
                    raise KilnError(b"E_NEED_PATH", q)
                if not ws.exists(q):
                    raise KilnError(
                        b"E_NEED_MISSING", q + b" needed by " + p)
                if q in stack:
                    raise KilnError(b"E_NEED_CYCLE", q)
                discovered.add(q)
                expand(q)
            else:
                emitted.append(line)
        stack.pop()

    expand(root)
    return emitted, sorted(discovered)


def exec_command(step, ws):
    """Read everything the command needs and compute its outputs. Execution
    errors are captured, not raised."""
    name = step.cmd_name
    args = step.cmd_args
    paths = step.file_inputs
    contents = [ws.read(p) for p in paths]
    in_pairs = [(paths[i], hexhash(contents[i])) for i in range(len(paths))]
    if name == b"preprocess":
        try:
            emitted, deps = _preprocess(ws, paths[0])
        except KilnError as err:
            return CommandResult(ins=in_pairs, error=err)
        content = join_lines(emitted)
        depcontent = b"kiln-deps 1\n" + b"".join(
            b"need " + d + b"\n" for d in deps)
        dep_pairs = [(d, hexhash(ws.read(d))) for d in deps]
        return CommandResult(
            ins=in_pairs,
            outs=[(step.outs[0], content), (step.depfile, depcontent)],
            deps=dep_pairs)
    if name == b"write":
        content = args[0]
    elif name == b"copy":
        content = contents[0]
    elif name == b"concat":
        content = b"".join(contents)
    elif name == b"upper":
        content = contents[0].upper()
    elif name == b"lower":
        content = contents[0].lower()
    elif name == b"grep":
        needle = args[0]
        content = join_lines([l for l in lines_of(contents[0])
                              if needle in l])
    elif name == b"replace":
        content = _replace_bytes(contents[0], args[0], args[1])
    elif name == b"sort_lines":
        content = join_lines(sorted(lines_of(contents[0])))
    elif name == b"reverse_lines":
        content = join_lines(list(reversed(lines_of(contents[0]))))
    elif name == b"dedup":
        seen = set()
        kept = []
        for l in lines_of(contents[0]):
            if l in seen:
                continue
            seen.add(l)
            kept.append(l)
        content = join_lines(kept)
    elif name == b"number":
        content = join_lines([b"%d: " % (i + 1) + l
                              for i, l in enumerate(lines_of(contents[0]))])
    elif name == b"indent":
        pad = b" " * args[0]
        content = join_lines([pad + l for l in lines_of(contents[0])])
    elif name == b"wrap":
        content = args[0] + contents[0] + args[1]
    elif name == b"count_lines":
        out = []
        total = 0
        for i, p in enumerate(paths):
            k = len(lines_of(contents[i]))
            total += k
            out.append(b"%d " % k + p)
        out.append(b"%d total" % total)
        content = join_lines(out)
    elif name == b"hash":
        content = join_lines([hexhash(contents[i]) + b" " + paths[i]
                              for i in range(len(paths))])
    else:
        raise AssertionError("unknown command")
    return CommandResult(ins=in_pairs, outs=[(step.outs[0], content)])


# -------------------------------------------------------------- scheduler

class Event(object):
    __slots__ = ("kind", "serial", "start", "end", "worker", "target",
                 "command")

    def __init__(self, kind, serial, start, end, worker, target, command):
        self.kind = kind
        self.serial = serial
        self.start = start
        self.end = end
        self.worker = worker
        self.target = target
        self.command = command


def schedule(ws, graph, reachable, nworkers, state):
    """Run the simulation. Returns ``(events, error, ran, hits, time)``."""
    pending = {}
    preds = {}
    for node in reachable:
        pending[id(node)] = len(node.succs)
        preds[id(node)] = []
    for node in reachable:
        for m in node.succs:
            preds[id(m)].append(node)

    completed = set()
    events = []
    # `undecided` holds ready steps awaiting a freshness decision and
    # `dispatchable` holds ready steps already decided stale; both are heaps
    # keyed by serial, so ties always go to the lowest serial.
    undecided = []
    dispatchable = []

    def complete(node, when):
        queue = [node]
        qi = 0
        while qi < len(queue):
            x = queue[qi]
            qi += 1
            completed.add(id(x))
            for p in preds[id(x)]:
                pending[id(p)] -= 1
                if pending[id(p)] == 0:
                    if p.kind == b"step":
                        heapq.heappush(undecided, (p.serial, p))
                    else:
                        queue.append(p)

    for node in reachable:
        if node.kind == b"source":
            complete(node, 0)
    for node in reachable:
        if node.kind == b"phony" and id(node) not in completed \
                and pending[id(node)] == 0:
            complete(node, 0)
    seen_ready = set(s for s, _n in undecided)
    for node in reachable:
        if node.kind == b"step" and pending[id(node)] == 0 \
                and node.serial not in seen_ready:
            heapq.heappush(undecided, (node.serial, node))

    running = {}
    time = 0
    ran = 0
    hits = 0
    error = None

    while True:
        while undecided:
            _serial, node = heapq.heappop(undecided)
            if is_stale(node.step, state, ws):
                heapq.heappush(dispatchable, (node.serial, node))
            else:
                hits += 1
                events.append(Event(b"hit", node.serial, time, time, -1,
                                    node.name, node.step.cmd_string))
                complete(node, time)

        while dispatchable and len(running) < nworkers:
            _serial, node = heapq.heappop(dispatchable)
            worker = 0
            while worker in running:
                worker += 1
            end = time + node.step.cost
            ev = Event(b"run", node.serial, time, end, worker, node.name,
                       node.step.cmd_string)
            events.append(ev)
            running[worker] = (node, exec_command(node.step, ws), ev)

        if not running:
            break
        time = min(r[2].end for r in running.values())
        done = sorted(w for w, r in running.items() if r[2].end == time)
        failed = []
        finished = []
        for worker in done:
            node, result, ev = running.pop(worker)
            if result.error is not None:
                ev.kind = b"fail"
                failed.append((node, result.error))
            else:
                outs = []
                for path, content in result.outs:
                    ws.write(path, content)
                    outs.append((path, hexhash(content)))
                state[node.step.primary] = Entry(
                    node.step.cmd_string, result.ins, result.deps, outs)
                ran += 1
                finished.append(node)
        if failed:
            failed.sort(key=lambda t: t[0].serial)
            error = failed[0][1]
            for worker in sorted(running):
                node, result, ev = running[worker]
                ev.kind = b"cancel"
                state.pop(node.step.primary, None)
            running.clear()
            for node, _err in failed:
                state.pop(node.step.primary, None)
            break
        for node in finished:
            complete(node, time)

    events.sort(key=lambda e: (e.start, e.serial))
    total = 0
    for e in events:
        if e.kind == b"hit":
            total = max(total, e.start)
        else:
            total = max(total, e.end)
    return events, error, ran, hits, total


# ------------------------------------------------------------ build driver

def run_build(ws, targets, nworkers):
    """Run one ``build`` session step. Returns ``(events, result)`` where
    ``result`` is ``('ok', ran, hits, time)`` or ``('error', KilnError)``."""
    try:
        if not ws.exists(b"main.kiln"):
            raise KilnError(b"E_NO_BUILD_FILE", b"main.kiln")
        build = evaluate_build(ws)
        graph = Graph(build, ws)
        graph.validate()
        roots = graph.requested(targets)
        reachable = graph.cycle_check(roots)
    except KilnError as err:
        return [], ("error", err)
    state = read_state(ws)
    events, error, ran, hits, total = schedule(
        ws, graph, reachable, nworkers, state)
    write_state(ws, state)
    if error is not None:
        return events, ("error", error)
    return events, ("ok", ran, hits, total)
