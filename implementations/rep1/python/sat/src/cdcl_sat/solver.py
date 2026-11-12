"""CDCL SAT solver core.

MiniSat-style: two watched literals, first-UIP learning with local clause
minimisation, VSIDS branching with phase saving, Luby restarts and
activity-based learnt-clause deletion.

Internally variables are 0-based and a literal is ``2*v`` (positive) or
``2*v + 1`` (negative), so ``lit ^ 1`` is the negation and ``lit >> 1`` the
variable. The public API uses DIMACS integers.
"""

from __future__ import annotations

from typing import Iterable, List, Optional, Sequence

from .heap import VarHeap
from .luby import luby

_VAR_DECAY = 0.95
_CLA_DECAY = 0.999
_RESTART_BASE = 100
_MAX_LEARNTS_MIN = 2000
_MAX_LEARNTS_GROWTH = 1.1


class Clause(list):
    """A clause: a list of internal literals plus learnt-clause bookkeeping.

    ``c[0]`` and ``c[1]`` are the watched literals. For a reason clause,
    ``c[0]`` is the literal it implied.
    """

    __slots__ = ("learnt", "act", "dead")

    def __init__(self, lits: Iterable[int], learnt: bool = False) -> None:
        super().__init__(lits)
        self.learnt = learnt
        self.act = 0.0
        self.dead = False


class Solver:
    """An incremental-add CDCL solver.

    >>> s = Solver(2)
    >>> s.add_clause([1, 2]); s.add_clause([-1])
    True
    >>> s.solve()
    [False, True]
    """

    def __init__(self, num_vars: int = 0) -> None:
        self.num_vars = 0
        self.ok = True  # False once the formula is known unsatisfiable
        self.val: List[int] = []  # per literal: 1 true, -1 false, 0 unassigned
        self.level: List[int] = []
        self.reason: List[Optional[Clause]] = []
        self.polarity: List[int] = []  # saved phase as the literal bit (1 = false)
        self.activity: List[float] = []
        self.seen: List[int] = []
        self.watches: List[List[Clause]] = []
        self.heap = VarHeap(self.activity)
        self.trail: List[int] = []
        self.trail_lim: List[int] = []
        self.qhead = 0
        self.clauses: List[Clause] = []
        self.learnts: List[Clause] = []
        self.var_inc = 1.0
        self.cla_inc = 1.0
        self.max_learnts = float(_MAX_LEARNTS_MIN)
        self.conflicts = 0
        self.decisions = 0
        self.propagations = 0
        self.new_vars(num_vars)

    # ------------------------------------------------------------------ setup

    def new_vars(self, n: int) -> None:
        """Grow the variable set by ``n`` variables."""
        old = self.num_vars
        self.num_vars += n
        self.val.extend([0] * (2 * n))
        self.level.extend([0] * n)
        self.reason.extend([None] * n)
        self.polarity.extend([1] * n)
        self.activity.extend([0.0] * n)
        self.seen.extend([0] * n)
        self.watches.extend([] for _ in range(2 * n))
        self.heap.pos.extend([-1] * n)
        for v in range(old, self.num_vars):
            self.heap.insert(v)

    def add_clause(self, dimacs_lits: Iterable[int]) -> bool:
        """Add a clause of DIMACS literals (at the root level).

        Duplicates, tautologies and root-satisfied clauses are dropped and
        root-false literals removed; a unit is assigned and propagated.
        Returns ``False`` if the formula is now known to be unsatisfiable.
        """
        if not self.ok:
            return False
        val = self.val
        lits: List[int] = []
        have = set()
        for d in dimacs_lits:
            v = abs(d)
            if d == 0 or v > self.num_vars:
                raise ValueError(f"invalid literal {d} (num_vars={self.num_vars})")
            lit = 2 * (v - 1) + (d < 0)
            if lit ^ 1 in have or val[lit] == 1:
                return True  # tautology or already satisfied
            if lit in have or val[lit] == -1:
                continue
            have.add(lit)
            lits.append(lit)
        if not lits:
            self.ok = False
            return False
        if len(lits) == 1:
            self._enqueue(lits[0], None)
            self.ok = self._propagate() is None
            return self.ok
        c = Clause(lits)
        self.clauses.append(c)
        self._attach(c)
        return True

    def _attach(self, c: Clause) -> None:
        self.watches[c[0]].append(c)
        self.watches[c[1]].append(c)

    # ------------------------------------------------------------- assignment

    def _enqueue(self, lit: int, reason: Optional[Clause]) -> None:
        val = self.val
        val[lit] = 1
        val[lit ^ 1] = -1
        v = lit >> 1
        self.level[v] = len(self.trail_lim)
        self.reason[v] = reason
        self.trail.append(lit)

    def _backtrack(self, lvl: int) -> None:
        trail_lim = self.trail_lim
        if len(trail_lim) <= lvl:
            return
        trail, val, polarity, reason = self.trail, self.val, self.polarity, self.reason
        heap = self.heap
        pos = heap.pos
        start = trail_lim[lvl]
        for i in range(len(trail) - 1, start - 1, -1):
            lit = trail[i]
            v = lit >> 1
            val[lit] = 0
            val[lit ^ 1] = 0
            polarity[v] = lit & 1
            reason[v] = None
            if pos[v] < 0:
                heap.insert(v)
        del trail[start:]
        del trail_lim[lvl:]
        self.qhead = start

    def _propagate(self) -> Optional[Clause]:
        """Unit-propagate the trail; return a conflicting clause or ``None``."""
        trail, val, watches = self.trail, self.val, self.watches
        level, reason = self.level, self.reason
        dl = len(self.trail_lim)
        qhead = self.qhead
        confl = None
        while qhead < len(trail):
            p = trail[qhead]
            qhead += 1
            fl = p ^ 1  # literal that just became false
            ws = watches[fl]
            n = len(ws)
            i = j = 0
            while i < n:
                c = ws[i]
                i += 1
                if c[0] == fl:
                    c[0] = c[1]
                    c[1] = fl
                first = c[0]
                if val[first] == 1:
                    ws[j] = c
                    j += 1
                    continue
                for k in range(2, len(c)):
                    lk = c[k]
                    if val[lk] != -1:
                        c[1] = lk
                        c[k] = fl
                        watches[lk].append(c)
                        break
                else:
                    ws[j] = c
                    j += 1
                    if val[first] == -1:
                        confl = c
                        while i < n:
                            ws[j] = ws[i]
                            j += 1
                            i += 1
                        qhead = len(trail)
                    else:
                        val[first] = 1
                        val[first ^ 1] = -1
                        v = first >> 1
                        level[v] = dl
                        reason[v] = c
                        trail.append(first)
            del ws[j:]
        self.propagations += qhead - self.qhead
        self.qhead = qhead
        return confl

    # --------------------------------------------------------------- analysis

    def _bump_var(self, v: int) -> None:
        act = self.activity
        act[v] += self.var_inc
        if act[v] > 1e100:
            for i in range(len(act)):
                act[i] *= 1e-100
            self.var_inc *= 1e-100
        self.heap.increased(v)

    def _bump_clause(self, c: Clause) -> None:
        c.act += self.cla_inc
        if c.act > 1e20:
            for d in self.learnts:
                d.act *= 1e-20
            self.cla_inc *= 1e-20

    def _analyze(self, confl: Clause):
        """First-UIP analysis; returns ``(learnt_lits, backjump_level)``.

        ``learnt_lits[0]`` is the asserting literal and, if there is more than
        one literal, ``learnt_lits[1]`` has the backjump level.
        """
        seen, level, reason, trail = self.seen, self.level, self.reason, self.trail
        cur = len(self.trail_lim)
        learnt = [0]
        path = 0
        p = -1
        idx = len(trail) - 1
        while True:
            if confl.learnt:
                self._bump_clause(confl)
            for k in range(0 if p < 0 else 1, len(confl)):
                q = confl[k]
                v = q >> 1
                if not seen[v] and level[v] > 0:
                    self._bump_var(v)
                    seen[v] = 1
                    if level[v] >= cur:
                        path += 1
                    else:
                        learnt.append(q)
            while not seen[trail[idx] >> 1]:
                idx -= 1
            p = trail[idx]
            idx -= 1
            confl = reason[p >> 1]
            seen[p >> 1] = 0
            path -= 1
            if path == 0:
                break
        learnt[0] = p ^ 1

        # Local minimisation: drop a literal whose reason is covered by the clause.
        to_clear = learnt[1:]
        out = [learnt[0]]
        for q in to_clear:
            r = reason[q >> 1]
            if r is None:
                out.append(q)
                continue
            for k in range(1, len(r)):
                x = r[k] >> 1
                if not seen[x] and level[x] > 0:
                    out.append(q)
                    break
        for q in to_clear:
            seen[q >> 1] = 0

        if len(out) == 1:
            return out, 0
        best = 1
        for k in range(2, len(out)):
            if level[out[k] >> 1] > level[out[best] >> 1]:
                best = k
        out[1], out[best] = out[best], out[1]
        return out, level[out[1] >> 1]

    # --------------------------------------------------------------- reduction

    def _reduce_db(self) -> None:
        """Delete the lower-activity half of the learnts (binary ones are kept).

        Must be called at decision level 0, where no clause is a needed reason.
        """
        learnts = self.learnts
        learnts.sort(key=lambda c: c.act)
        half = len(learnts) // 2
        keep: List[Clause] = []
        removed = False
        for i, c in enumerate(learnts):
            if i < half and len(c) > 2:
                c.dead = True
                removed = True
            else:
                keep.append(c)
        self.learnts = keep
        if removed:
            for ws in self.watches:
                if ws:
                    ws[:] = [c for c in ws if not c.dead]

    # ------------------------------------------------------------------ search

    def _search(self, budget: int) -> Optional[bool]:
        """Search until ``budget`` conflicts; True = SAT, False = UNSAT, None = restart."""
        conflicts_here = 0
        trail_lim = self.trail_lim
        val = self.val
        polarity = self.polarity
        heap = self.heap
        while True:
            confl = self._propagate()
            if confl is not None:
                self.conflicts += 1
                conflicts_here += 1
                if not trail_lim:
                    return False
                lits, bj = self._analyze(confl)
                self._backtrack(bj)
                if len(lits) == 1:
                    self._enqueue(lits[0], None)
                else:
                    c = Clause(lits, True)
                    self.learnts.append(c)
                    self._attach(c)
                    self._bump_clause(c)
                    self._enqueue(lits[0], c)
                self.var_inc /= _VAR_DECAY
                self.cla_inc /= _CLA_DECAY
            else:
                if conflicts_here >= budget:
                    self._backtrack(0)
                    return None
                while True:
                    if not heap:
                        return True
                    v = heap.pop()
                    if val[2 * v] == 0:
                        break
                self.decisions += 1
                trail_lim.append(len(self.trail))
                self._enqueue(2 * v + polarity[v], None)

    def solve(self) -> Optional[List[bool]]:
        """Decide satisfiability.

        Returns a model (``model[i]`` is the value of variable ``i + 1``) or
        ``None`` if unsatisfiable.
        """
        if not self.ok:
            return None
        if self._propagate() is not None:
            self.ok = False
            return None
        self.max_learnts = max(len(self.clauses) // 3, _MAX_LEARNTS_MIN)
        restarts = 0
        while True:
            status = self._search(int(_RESTART_BASE * luby(2, restarts)))
            if status is not None:
                break
            restarts += 1
            if len(self.learnts) >= self.max_learnts:
                self._reduce_db()
                self.max_learnts *= _MAX_LEARNTS_GROWTH
        if not status:
            self.ok = False
            return None
        val = self.val
        model = [val[2 * v] == 1 for v in range(self.num_vars)]
        self._backtrack(0)
        return model


def solve(num_vars: int, clauses: Iterable[Sequence[int]]) -> Optional[List[bool]]:
    """Solve a CNF given as DIMACS-literal clauses over variables ``1..num_vars``.

    Returns a model list (index ``i`` is variable ``i + 1``) or ``None`` for UNSAT.
    """
    s = Solver(num_vars)
    for c in clauses:
        if not s.add_clause(c):
            return None
    return s.solve()
