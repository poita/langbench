#!/usr/bin/env python3
"""Reference CDCL SAT solver for the `sat` problem.

Reads a DIMACS CNF on stdin and prints "SAT" plus a full assignment, or
"UNSAT". The solver is a compact MiniSat-style CDCL: two watched literals,
first-UIP conflict analysis with clause minimisation, VSIDS decision heuristic
on an indexed binary heap, phase saving, Luby restarts and activity-based
learnt clause deletion.

Literal encoding: variable v (0-based) is literal 2v when positive and 2v+1
when negative, so negation is `lit ^ 1` and the variable is `lit >> 1`.
"""
import sys

sys.setrecursionlimit(10000)


def parse_dimacs(data):
    """Return (nvars, clauses) where clauses are lists of DIMACS literals."""
    nvars = None
    tokens = []
    for line in data.split("\n"):
        s = line.strip()
        if not s or s[0] == "c":
            continue
        if s[0] == "p":
            parts = s.split()
            nvars = int(parts[2])
            continue
        tokens.extend(s.split())
    clauses = []
    cur = []
    for t in tokens:
        x = int(t)
        if x == 0:
            clauses.append(cur)
            cur = []
        else:
            cur.append(x)
    if nvars is None:
        nvars = 0
    return nvars, clauses


class VarHeap:
    """Max-heap of variables ordered by activity, with position tracking so a
    variable's key can be increased in place."""

    def __init__(self, activity):
        self.act = activity
        self.heap = []
        self.pos = [-1] * len(activity)

    def _up(self, i):
        heap, pos, act = self.heap, self.pos, self.act
        v = heap[i]
        a = act[v]
        while i > 0:
            p = (i - 1) >> 1
            u = heap[p]
            if act[u] >= a:
                break
            heap[i] = u
            pos[u] = i
            i = p
        heap[i] = v
        pos[v] = i

    def _down(self, i):
        heap, pos, act = self.heap, self.pos, self.act
        n = len(heap)
        v = heap[i]
        a = act[v]
        while True:
            l = 2 * i + 1
            if l >= n:
                break
            r = l + 1
            c = r if r < n and act[heap[r]] > act[heap[l]] else l
            u = heap[c]
            if act[u] <= a:
                break
            heap[i] = u
            pos[u] = i
            i = c
        heap[i] = v
        pos[v] = i

    def push(self, v):
        if self.pos[v] >= 0:
            return
        self.pos[v] = len(self.heap)
        self.heap.append(v)
        self._up(self.pos[v])

    def pop(self):
        heap, pos = self.heap, self.pos
        top = heap[0]
        last = heap.pop()
        pos[top] = -1
        if heap:
            heap[0] = last
            pos[last] = 0
            self._down(0)
        return top

    def bumped(self, v):
        if self.pos[v] >= 0:
            self._up(self.pos[v])

    def __len__(self):
        return len(self.heap)


def luby(y, x):
    """The x-th element (0-based) of the Luby restart sequence scaled by y."""
    size, seq = 1, 0
    while size < x + 1:
        seq += 1
        size = 2 * size + 1
    while size - 1 != x:
        size = (size - 1) >> 1
        seq -= 1
        x = x % size
    return y ** seq


class Solver:
    def __init__(self, nvars):
        n = self.n = nvars
        self.val = [-1] * (2 * n)      # per literal: 1 true, 0 false, -1 unassigned
        self.level = [0] * n
        self.reason = [None] * n
        self.trail = []
        self.trail_lim = []
        self.qhead = 0
        self.watches = [[] for _ in range(2 * n)]
        self.clauses = []
        self.learnts = []
        self.cla_act = {}              # id(learnt clause) -> activity
        self.activity = [0.0] * n
        self.var_inc = 1.0
        self.var_decay = 0.95
        self.cla_inc = 1.0
        self.cla_decay = 0.999
        self.phase = [False] * n       # saved phase; False = try negative first
        self.heap = VarHeap(self.activity)
        for v in range(n):
            self.heap.push(v)
        self.seen = [False] * n
        self.ok = True

    # -- clause management -------------------------------------------------

    def add_clause(self, dimacs_lits):
        """Add an input clause; returns False if the formula is already
        unsatisfiable at the root level."""
        if not self.ok:
            return False
        lits = sorted({(abs(x) - 1) * 2 + (1 if x < 0 else 0) for x in dimacs_lits})
        # Drop tautologies (contain both p and -p): always satisfied.
        for i in range(1, len(lits)):
            if lits[i] == lits[i - 1] ^ 1:
                return True
        val = self.val
        lits = [l for l in lits if val[l] != 0]
        if any(val[l] == 1 for l in lits):
            return True
        if not lits:
            self.ok = False
            return False
        if len(lits) == 1:
            self.enqueue(lits[0], None)
            if self.propagate() is not None:
                self.ok = False
                return False
            return True
        self.clauses.append(lits)
        self.watches[lits[0]].append(lits)
        self.watches[lits[1]].append(lits)
        return True

    def enqueue(self, lit, reason):
        self.val[lit] = 1
        self.val[lit ^ 1] = 0
        v = lit >> 1
        self.level[v] = len(self.trail_lim)
        self.reason[v] = reason
        self.trail.append(lit)

    def propagate(self):
        """Unit propagation over the watch lists; returns a conflicting clause
        or None when a fixpoint is reached."""
        val = self.val
        watches = self.watches
        trail = self.trail
        while self.qhead < len(trail):
            p = trail[self.qhead]
            self.qhead += 1
            false_lit = p ^ 1
            ws = watches[false_lit]
            new_ws = []
            i = 0
            n = len(ws)
            while i < n:
                c = ws[i]
                i += 1
                if c[0] == false_lit:
                    c[0] = c[1]
                    c[1] = false_lit
                first = c[0]
                if val[first] == 1:
                    new_ws.append(c)
                    continue
                moved = False
                for k in range(2, len(c)):
                    lk = c[k]
                    if val[lk] != 0:
                        c[1] = lk
                        c[k] = false_lit
                        watches[lk].append(c)
                        moved = True
                        break
                if moved:
                    continue
                new_ws.append(c)
                if val[first] == 0:
                    new_ws.extend(ws[i:])
                    watches[false_lit] = new_ws
                    self.qhead = len(trail)
                    return c
                self.enqueue(first, c)
            watches[false_lit] = new_ws
        return None

    # -- conflict analysis -------------------------------------------------

    def bump_var(self, v):
        self.activity[v] += self.var_inc
        if self.activity[v] > 1e100:
            act = self.activity
            for i in range(self.n):
                act[i] *= 1e-100
            self.var_inc *= 1e-100
        self.heap.bumped(v)

    def bump_clause(self, c):
        k = id(c)
        a = self.cla_act.get(k)
        if a is None:
            return
        a += self.cla_inc
        self.cla_act[k] = a
        if a > 1e20:
            for kk in self.cla_act:
                self.cla_act[kk] *= 1e-20
            self.cla_inc *= 1e-20

    def analyze(self, confl):
        """First-UIP learning. Returns (learnt clause, backjump level) with the
        asserting literal at index 0."""
        seen = self.seen
        level = self.level
        reason = self.reason
        trail = self.trail
        cur_level = len(self.trail_lim)
        learnt = [None]
        p = None
        index = len(trail) - 1
        path = 0
        while True:
            self.bump_clause(confl)
            for q in confl:
                if q == p:
                    continue
                v = q >> 1
                if not seen[v] and level[v] > 0:
                    seen[v] = True
                    self.bump_var(v)
                    if level[v] >= cur_level:
                        path += 1
                    else:
                        learnt.append(q)
            while not seen[trail[index] >> 1]:
                index -= 1
            p = trail[index]
            index -= 1
            v = p >> 1
            confl = reason[v]
            seen[v] = False
            path -= 1
            if path == 0:
                break
        learnt[0] = p ^ 1

        # Local minimisation: drop a literal whose reason clause is implied by
        # the other literals of the learnt clause.
        out = [learnt[0]]
        for q in learnt[1:]:
            r = reason[q >> 1]
            if r is None:
                out.append(q)
                continue
            redundant = True
            for x in r:
                if x == (q ^ 1):
                    continue
                xv = x >> 1
                if not seen[xv] and level[xv] > 0:
                    redundant = False
                    break
            if not redundant:
                out.append(q)
        for q in learnt[1:]:
            seen[q >> 1] = False
        learnt = out

        if len(learnt) == 1:
            return learnt, 0
        # Put the literal with the highest level (other than the asserting
        # literal) at index 1 so it is watched.
        mi = 1
        for i in range(2, len(learnt)):
            if level[learnt[i] >> 1] > level[learnt[mi] >> 1]:
                mi = i
        learnt[1], learnt[mi] = learnt[mi], learnt[1]
        return learnt, level[learnt[1] >> 1]

    def backtrack(self, lvl):
        if len(self.trail_lim) <= lvl:
            return
        val = self.val
        phase = self.phase
        heap = self.heap
        reason = self.reason
        trail = self.trail
        stop = self.trail_lim[lvl]
        for i in range(len(trail) - 1, stop - 1, -1):
            lit = trail[i]
            v = lit >> 1
            val[lit] = -1
            val[lit ^ 1] = -1
            reason[v] = None
            phase[v] = (lit & 1) == 0
            heap.push(v)
        del trail[stop:]
        del self.trail_lim[lvl:]
        self.qhead = len(trail)

    def decide(self):
        heap = self.heap
        val = self.val
        while len(heap):
            v = heap.pop()
            if val[2 * v] == -1:
                self.trail_lim.append(len(self.trail))
                self.enqueue(2 * v if self.phase[v] else 2 * v + 1, None)
                return True
        return False

    # -- learnt clause database -------------------------------------------

    def reduce_db(self):
        """Delete roughly half of the learnt clauses with the lowest activity
        (keeping binaries), then rebuild the watch lists. Only called at
        decision level 0 so no reason pointers into learnt clauses matter."""
        cla_act = self.cla_act
        learnts = self.learnts
        learnts.sort(key=lambda c: cla_act[id(c)])
        half = len(learnts) // 2
        keep = []
        for i, c in enumerate(learnts):
            if i < half and len(c) > 2:
                del cla_act[id(c)]
            else:
                keep.append(c)
        self.learnts = keep
        watches = self.watches
        for w in watches:
            del w[:]
        for c in self.clauses:
            watches[c[0]].append(c)
            watches[c[1]].append(c)
        for c in keep:
            watches[c[0]].append(c)
            watches[c[1]].append(c)

    # -- main search -------------------------------------------------------

    def search(self, max_conflicts):
        conflicts = 0
        while True:
            confl = self.propagate()
            if confl is not None:
                if not self.trail_lim:
                    return False
                conflicts += 1
                learnt, lvl = self.analyze(confl)
                self.backtrack(lvl)
                if len(learnt) == 1:
                    self.enqueue(learnt[0], None)
                else:
                    self.learnts.append(learnt)
                    self.cla_act[id(learnt)] = self.cla_inc
                    self.watches[learnt[0]].append(learnt)
                    self.watches[learnt[1]].append(learnt)
                    self.enqueue(learnt[0], learnt)
                self.var_inc /= self.var_decay
                self.cla_inc /= self.cla_decay
            else:
                if conflicts >= max_conflicts:
                    self.backtrack(0)
                    return None
                if not self.decide():
                    return True

    def solve(self):
        if not self.ok:
            return False
        if self.propagate() is not None:
            self.ok = False
            return False
        max_learnts = max(len(self.clauses) // 3, 2000)
        restarts = 0
        while True:
            res = self.search(luby(2, restarts) * 100)
            if res is not None:
                return res
            restarts += 1
            if len(self.learnts) >= max_learnts:
                self.reduce_db()
                max_learnts = int(max_learnts * 1.1)

    def model(self):
        val = self.val
        return [(v + 1) if val[2 * v] == 1 else -(v + 1) for v in range(self.n)]


def main():
    data = sys.stdin.read()
    nvars, clauses = parse_dimacs(data)
    solver = Solver(nvars)
    for c in clauses:
        if not solver.add_clause(c):
            break
    out = sys.stdout
    if solver.solve():
        out.write("SAT\n")
        out.write(" ".join(map(str, solver.model() + [0])) + "\n")
    else:
        out.write("UNSAT\n")


if __name__ == "__main__":
    main()
