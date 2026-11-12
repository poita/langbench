"""A MiniSat-style conflict-driven clause-learning (CDCL) SAT solver.

Internals
---------
Variables are 0-based internally; the literal of variable ``v`` is ``2*v``
(positive) or ``2*v + 1`` (negative), so negation is ``lit ^ 1``. The public
API uses DIMACS integers (``±(v + 1)``).

* Two watched literals per clause (the first two literals of ``Clause.lits``).
* First-UIP conflict analysis with local (non-recursive) minimisation.
* VSIDS branching (double-precision activities, decay 0.95) over an indexed
  heap, with phase saving (initial phase: false).
* Luby restarts (unit 100 conflicts) and activity-based learnt-clause
  deletion performed right after a restart.
"""

from __future__ import annotations

from typing import Iterable, List, Optional, Sequence

from .heap import ActivityHeap
from .luby import luby

_VAR_DECAY = 0.95
_CLA_DECAY = 0.999
_VAR_RESCALE_LIMIT = 1e100
_CLA_RESCALE_LIMIT = 1e20
_RESTART_UNIT = 100
_MAX_LEARNTS_FLOOR = 2000
_MAX_LEARNTS_GROWTH = 1.1


class Clause:
    """A stored clause of two or more literals."""

    __slots__ = ("lits", "learnt", "activity", "deleted")

    def __init__(self, lits: List[int], learnt: bool) -> None:
        self.lits = lits
        self.learnt = learnt
        self.activity = 0.0
        self.deleted = False


class Solver:
    """CDCL SAT solver.

    >>> s = Solver()
    >>> s.add_clause([1, -2]); s.add_clause([2, 3])
    True
    True
    >>> s.solve()
    True
    >>> s.model()  # doctest: +SKIP
    [-1, -2, 3]

    Clauses are lists of non-zero DIMACS integers. Variables are created on
    demand (``add_clause`` grows the variable count to fit). Clauses may be
    added between calls to :meth:`solve`.
    """

    def __init__(self, num_vars: int = 0) -> None:
        self._n = 0
        self._ok = True
        self._val: List[int] = []  # per literal: 1 true, -1 false, 0 unassigned
        self._level: List[int] = []
        self._reason: List[Optional[Clause]] = []
        self._activity: List[float] = []
        self._phase: List[bool] = []
        self._seen: List[int] = []
        self._watches: List[List[Clause]] = []
        self._order = ActivityHeap(self._activity)
        self._trail: List[int] = []
        self._trail_lim: List[int] = []
        self._qhead = 0
        self._clauses: List[Clause] = []
        self._learnts: List[Clause] = []
        self._var_inc = 1.0
        self._cla_inc = 1.0
        self._max_learnts = float(_MAX_LEARNTS_FLOOR)
        self._model: Optional[List[int]] = None
        self.conflicts = 0
        self.decisions = 0
        self.propagations = 0
        self.restarts = 0
        self._ensure_vars(num_vars)

    # ------------------------------------------------------------------ API

    @property
    def num_vars(self) -> int:
        """Number of variables known to the solver."""
        return self._n

    def new_var(self) -> int:
        """Create a fresh variable and return its DIMACS number."""
        self._ensure_vars(self._n + 1)
        return self._n

    def add_clause(self, lits: Iterable[int]) -> bool:
        """Add a clause given as DIMACS integers.

        The clause is simplified against the root-level assignment:
        duplicate literals, tautologies and satisfied clauses are dropped and
        false literals removed; units are assigned and propagated. Returns
        ``False`` if the formula became trivially unsatisfiable.
        """
        if not self._ok:
            return False
        self._cancel_until(0)
        lits = list(lits)
        top = max((abs(x) for x in lits), default=0)
        self._ensure_vars(top)
        val = self._val
        seen = set()
        out: List[int] = []
        for x in lits:
            lit = 2 * (x - 1) if x > 0 else 2 * (-x - 1) + 1
            if lit ^ 1 in seen or val[lit] == 1:
                return True  # tautology or already satisfied
            if lit in seen or val[lit] == -1:
                continue
            seen.add(lit)
            out.append(lit)
        if not out:
            self._ok = False
            return False
        if len(out) == 1:
            self._enqueue(out[0], None)
            self._ok = self._propagate() is None
            return self._ok
        clause = Clause(out, False)
        self._clauses.append(clause)
        self._attach(clause)
        return True

    def solve(self) -> bool:
        """Decide satisfiability. On ``True`` the model is in :meth:`model`."""
        self._model = None
        if not self._ok:
            return False
        if self._propagate() is not None:
            self._ok = False
            return False
        self._max_learnts = float(
            max(len(self._clauses) // 3, _MAX_LEARNTS_FLOOR)
        )
        self._order.rebuild(
            v for v in range(self._n) if self._val[2 * v] == 0
        )
        result: Optional[bool] = None
        restart = 0
        while result is None:
            budget = int(_RESTART_UNIT * luby(2, restart))
            result = self._search(budget)
            if result is None:
                restart += 1
                self.restarts += 1
                if len(self._learnts) >= self._max_learnts:
                    self._reduce_db()
                    self._max_learnts *= _MAX_LEARNTS_GROWTH
        if result:
            val = self._val
            self._model = [
                (v + 1) if val[2 * v] == 1 else -(v + 1) for v in range(self._n)
            ]
        else:
            self._ok = False
        self._cancel_until(0)
        return result

    def model(self) -> List[int]:
        """The last satisfying assignment as ``[±1, ..., ±num_vars]``.

        Variables not occurring in any clause are assigned false.
        """
        if self._model is None:
            raise RuntimeError("no model: solve() has not returned True")
        return list(self._model)

    # ------------------------------------------------------------ internals

    def _ensure_vars(self, n: int) -> None:
        old = self._n
        if n <= old:
            return
        extra = n - old
        self._n = n
        self._val.extend([0] * (2 * extra))
        self._level.extend([0] * extra)
        self._reason.extend([None] * extra)
        self._activity.extend([0.0] * extra)
        self._phase.extend([False] * extra)
        self._seen.extend([0] * extra)
        self._watches.extend([] for _ in range(2 * extra))
        self._order.grow(n)
        for v in range(old, n):
            self._order.insert(v)

    def _attach(self, clause: Clause) -> None:
        lits = clause.lits
        self._watches[lits[0]].append(clause)
        self._watches[lits[1]].append(clause)

    def _enqueue(self, lit: int, reason: Optional[Clause]) -> None:
        val = self._val
        val[lit] = 1
        val[lit ^ 1] = -1
        v = lit >> 1
        self._level[v] = len(self._trail_lim)
        self._reason[v] = reason
        self._trail.append(lit)

    def _propagate(self) -> Optional[Clause]:
        """Unit propagation; returns a conflicting clause or ``None``.

        ``watches[l]`` holds the clauses watching ``l``; they are visited when
        ``l`` becomes false.
        """
        val = self._val
        watches = self._watches
        trail = self._trail
        level = self._level
        reason = self._reason
        qhead = self._qhead
        confl: Optional[Clause] = None
        while qhead < len(trail):
            false_lit = trail[qhead] ^ 1
            qhead += 1
            ws = watches[false_lit]
            n = len(ws)
            i = j = 0
            while i < n:
                c = ws[i]
                i += 1
                lits = c.lits
                first = lits[0]
                if first == false_lit:
                    first = lits[1]
                    lits[0] = first
                    lits[1] = false_lit
                if val[first] == 1:
                    ws[j] = c
                    j += 1
                    continue
                for k in range(2, len(lits)):
                    lk = lits[k]
                    if val[lk] != -1:
                        lits[1] = lk
                        lits[k] = false_lit
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
                        break
                    # unit: first is implied by c
                    val[first] = 1
                    val[first ^ 1] = -1
                    v = first >> 1
                    level[v] = len(self._trail_lim)
                    reason[v] = c
                    trail.append(first)
            del ws[j:]
            if confl is not None:
                qhead = len(trail)
                break
        self.propagations += qhead - self._qhead
        self._qhead = qhead
        return confl

    def _cancel_until(self, target: int) -> None:
        lim = self._trail_lim
        if len(lim) <= target:
            return
        trail = self._trail
        val = self._val
        reason = self._reason
        phase = self._phase
        pos = self._order.pos
        insert = self._order.insert
        for idx in range(len(trail) - 1, lim[target] - 1, -1):
            lit = trail[idx]
            v = lit >> 1
            val[lit] = 0
            val[lit ^ 1] = 0
            reason[v] = None
            phase[v] = not (lit & 1)
            if pos[v] < 0:
                insert(v)
        del trail[lim[target]:]
        del lim[target:]
        self._qhead = len(trail)

    def _bump_var(self, v: int) -> None:
        act = self._activity
        act[v] += self._var_inc
        if act[v] > _VAR_RESCALE_LIMIT:
            for i in range(self._n):
                act[i] *= 1e-100
            self._var_inc *= 1e-100
        self._order.increased(v)

    def _bump_clause(self, c: Clause) -> None:
        c.activity += self._cla_inc
        if c.activity > _CLA_RESCALE_LIMIT:
            for lc in self._learnts:
                lc.activity *= 1e-20
            self._cla_inc *= 1e-20

    def _analyze(self, confl: Clause):
        """First-UIP analysis; returns ``(learnt_lits, backtrack_level)``.

        ``learnt_lits[0]`` is the asserting literal; for clauses longer than
        one literal ``learnt_lits[1]`` has the backtrack level.
        """
        seen = self._seen
        level = self._level
        reason = self._reason
        trail = self._trail
        cur_level = len(self._trail_lim)
        learnt = [0]
        path = 0
        idx = len(trail) - 1
        p = -1
        c: Optional[Clause] = confl
        while True:
            if c.learnt:
                self._bump_clause(c)
            lits = c.lits
            for k in range(0 if p == -1 else 1, len(lits)):
                q = lits[k]
                v = q >> 1
                if not seen[v] and level[v] > 0:
                    self._bump_var(v)
                    seen[v] = 1
                    if level[v] >= cur_level:
                        path += 1
                    else:
                        learnt.append(q)
            while not seen[trail[idx] >> 1]:
                idx -= 1
            p = trail[idx]
            idx -= 1
            c = reason[p >> 1]
            seen[p >> 1] = 0
            path -= 1
            if path <= 0:
                break
        learnt[0] = p ^ 1

        # Local minimisation: drop a literal whose reason clause is entirely
        # made of literals already in the learnt clause (or fixed at level 0).
        to_clear = learnt[:]
        j = 1
        for i in range(1, len(learnt)):
            q = learnt[i]
            r = reason[q >> 1]
            if r is None:
                learnt[j] = q
                j += 1
                continue
            rl = r.lits
            for k in range(1, len(rl)):
                u = rl[k] >> 1
                if not seen[u] and level[u] > 0:
                    learnt[j] = q
                    j += 1
                    break
        del learnt[j:]
        for q in to_clear:
            seen[q >> 1] = 0

        if len(learnt) == 1:
            return learnt, 0
        best = 1
        for i in range(2, len(learnt)):
            if level[learnt[i] >> 1] > level[learnt[best] >> 1]:
                best = i
        learnt[1], learnt[best] = learnt[best], learnt[1]
        return learnt, level[learnt[1] >> 1]

    def _search(self, budget: int) -> Optional[bool]:
        """Search until a verdict or ``budget`` conflicts (then ``None``)."""
        conflicts = 0
        val = self._val
        order = self._order
        phase = self._phase
        while True:
            confl = self._propagate()
            if confl is not None:
                self.conflicts += 1
                conflicts += 1
                if not self._trail_lim:
                    return False
                learnt, bt = self._analyze(confl)
                self._cancel_until(bt)
                if len(learnt) == 1:
                    self._enqueue(learnt[0], None)
                else:
                    c = Clause(learnt, True)
                    self._learnts.append(c)
                    self._attach(c)
                    self._bump_clause(c)
                    self._enqueue(learnt[0], c)
                self._var_inc /= _VAR_DECAY
                self._cla_inc /= _CLA_DECAY
            else:
                if conflicts >= budget:
                    self._cancel_until(0)
                    return None
                v = -1
                while len(order):
                    cand = order.pop_max()
                    if val[2 * cand] == 0:
                        v = cand
                        break
                if v < 0:
                    return True
                self.decisions += 1
                self._trail_lim.append(len(self._trail))
                self._enqueue(2 * v if phase[v] else 2 * v + 1, None)

    def _reduce_db(self) -> None:
        """Delete the lower-activity half of the learnt clauses.

        Called at decision level 0, so no learnt clause is the reason for a
        live assignment. Binary learnt clauses are always kept.
        """
        learnts = self._learnts
        learnts.sort(key=lambda c: c.activity)
        limit = len(learnts) // 2
        kept: List[Clause] = []
        for i, c in enumerate(learnts):
            if i < limit and len(c.lits) > 2:
                c.deleted = True
            else:
                kept.append(c)
        self._learnts = kept
        for ws in self._watches:
            if ws:
                ws[:] = [c for c in ws if not c.deleted]


def solve(clauses: Sequence[Sequence[int]], num_vars: Optional[int] = None):
    """Solve a CNF given as DIMACS-style integer clauses.

    Returns ``None`` if unsatisfiable, otherwise a model ``[±1, ..., ±n]``
    with one literal per variable, where ``n`` is ``num_vars`` (default: the
    largest variable occurring in ``clauses``).
    """
    solver = Solver(num_vars or 0)
    for clause in clauses:
        if not solver.add_clause(clause):
            return None
    if not solver.solve():
        return None
    return solver.model()
