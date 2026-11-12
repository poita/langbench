"""Total-fit line breaking (Knuth-Plass style) over horizontal lists."""

from __future__ import annotations

from dataclasses import dataclass

from .hlist import BOX, GLUE, INF_PENALTY, PENALTY, Item

TIGHT, DECENT, LOOSE, VERY_LOOSE = 0, 1, 2, 3


@dataclass(frozen=True)
class BreakParams:
    """The line-breaking settings."""

    tolerance: int = 1000
    line_penalty: int = 10
    adj_demerits: int = 10000
    double_hyphen_demerits: int = 10000
    final_hyphen_demerits: int = 5000


@dataclass
class Breaking:
    """Result of breaking one list: ``lines`` are ``(a, b)`` breakpoint pairs."""

    lines: list[tuple[int, int]]
    total_demerits: int
    emergency: bool


class Metrics:
    """Prefix sums over a list, making any candidate line O(1) to measure."""

    def __init__(self, items: list[Item]) -> None:
        n = len(items)
        pw = [0] * (n + 1)
        py = [0] * (n + 1)
        pz = [0] * (n + 1)
        pi = [0] * (n + 1)
        for i, it in enumerate(items):
            pw[i + 1] = pw[i] + it.width
            if it.kind == GLUE:
                py[i + 1] = py[i] + it.stretch
                pz[i + 1] = pz[i] + it.shrink
                pi[i + 1] = pi[i] + (1 if it.inf else 0)
            else:
                py[i + 1] = py[i]
                pz[i + 1] = pz[i]
                pi[i + 1] = pi[i]
        self.items = items
        self.pw, self.py, self.pz, self.pi = pw, py, pz, pi
        # glue_end[i]: index of first non-glue item at or after i
        ge = [n] * (n + 2)
        for i in range(n - 1, -1, -1):
            ge[i] = ge[i + 1] if items[i].kind == GLUE else i
        self.glue_end = ge

    def line_start(self, a: int) -> int:
        """Index of the first item of the line after breakpoint *a*."""
        start = 0 if a == 0 else a + 1
        return self.glue_end[start]

    def span(self, a: int, b: int) -> tuple[int, int, int, bool]:
        """``(W, Y, Z, infinite)`` of the line between breakpoints *a* < *b*."""
        f = self.line_start(a)
        if f > b:
            f = b
        w = self.pw[b] - self.pw[f]
        it = self.items[b]
        if it.kind == PENALTY and it.pre is not None:
            w += it.pre.width
        return w, self.py[b] - self.py[f], self.pz[b] - self.pz[f], self.pi[b] > self.pi[f]


def breakpoints(items: list[Item]) -> list[int]:
    """Indices of all breakpoints (not including the notional breakpoint 0)."""
    out = []
    prev_box = False
    for i, it in enumerate(items):
        k = it.kind
        if k == GLUE:
            if i > 0 and prev_box:
                out.append(i)
        elif k == PENALTY and it.penalty < INF_PENALTY:
            if i > 0:
                out.append(i)
        prev_box = k == BOX
    return out


def break_lines(items: list[Item], measure: int, first_indent: int,
                params: BreakParams) -> Breaking:
    """Break a list into lines.  *measure* is the full measure; the first line
    is ``measure - first_indent`` wide."""
    metrics = Metrics(items)
    bps = breakpoints(items)
    result = _search(items, metrics, bps, measure, first_indent, params, False)
    if result is not None:
        return Breaking(result[0], result[1], False)
    result = _search(items, metrics, bps, measure, first_indent, params, True)
    return Breaking(result[0], result[1], True)


def _search(items, metrics, bps, measure, first_indent, params, pass2):
    pw, py, pz, pi = metrics.pw, metrics.py, metrics.pz, metrics.pi
    line_start = metrics.line_start
    tolerance = params.tolerance
    lp = params.line_penalty
    adj = params.adj_demerits
    dbl = params.double_hyphen_demerits
    fin = params.final_hyphen_demerits
    first_measure = measure - first_indent
    last = len(items) - 1

    n_bp = [0]
    n_cls = [DECENT]
    n_line = [0]
    n_tot = [0]
    n_prev = [-1]
    n_flag = [False]
    active = [0]

    for b in bps:
        it = items[b]
        if it.kind == GLUE:
            p = 0
            flag = False
            prew = 0
        else:
            p = it.penalty
            flag = it.flagged
            prew = it.pre.width if it.pre is not None else 0
        is_final = b == last
        if 0 <= p < INF_PENALTY:
            pterm = p * p
        elif -INF_PENALTY < p < 0:
            pterm = -(p * p)
        else:
            pterm = 0
        pwb, pyb, pzb, pib = pw[b], py[b], pz[b], pi[b]
        best_tot = [None, None, None, None]
        best_prev = [-1, -1, -1, -1]
        keep = []
        candidates = range(len(n_bp)) if pass2 else active
        for ni in candidates:
            a = n_bp[ni]
            f = line_start(a)
            if f > b:
                f = b
            W = pwb - pw[f] + prew
            Y = pyb - py[f]
            Z = pzb - pz[f]
            L = first_measure if a == 0 else measure
            d = L - W
            if not pass2:
                if W - prew - Z > L:
                    continue  # overfull for good: leaves the active set
                keep.append(ni)
            if d >= 0 and pib > pi[f]:
                bad = 0
                cls = DECENT
            elif d == 0:
                bad = 0
                cls = DECENT
            elif d > 0:
                if Y == 0:
                    if not pass2:
                        continue
                    bad = 10000
                    cls = VERY_LOOSE
                else:
                    bad = 100 * d * d * d // (Y * Y * Y)
                    if bad > 10000:
                        bad = 10000
                    cls = VERY_LOOSE if d > Y else (LOOSE if 2 * d > Y else DECENT)
            else:
                e = -d
                if Z == 0 or e > Z:
                    if not pass2:
                        continue
                    bad = 10000
                    cls = TIGHT
                else:
                    bad = 100 * e * e * e // (Z * Z * Z)
                    if bad > 10000:
                        bad = 10000
                    cls = TIGHT if 2 * e > Z else DECENT
            if not pass2 and bad > tolerance:
                continue
            dem = (lp + bad) ** 2 + pterm
            fl0 = n_flag[ni]
            if flag and fl0:
                dem += dbl
            if cls - n_cls[ni] > 1 or n_cls[ni] - cls > 1:
                dem += adj
            if is_final and fl0:
                dem += fin
            tot = n_tot[ni] + dem
            bt = best_tot[cls]
            if bt is None or tot < bt:
                best_tot[cls] = tot
                best_prev[cls] = ni
        if not pass2:
            active = keep
        for cls in range(4):
            if best_tot[cls] is not None:
                n_bp.append(b)
                n_cls.append(cls)
                prev = best_prev[cls]
                n_line.append(n_line[prev] + 1)
                n_tot.append(best_tot[cls])
                n_prev.append(prev)
                n_flag.append(flag)
                if not pass2:
                    active.append(len(n_bp) - 1)
        if not pass2 and not active:
            return None

    final = None
    for ni in range(len(n_bp) - 1, 0, -1):
        if n_bp[ni] != last:
            break
        if (final is None or (n_tot[ni], n_cls[ni], ni) < (n_tot[final], n_cls[final], final)):
            final = ni
    if final is None:
        return None
    chain = []
    ni = final
    while ni > 0:
        chain.append(n_bp[ni])
        ni = n_prev[ni]
    chain.append(0)
    chain.reverse()
    lines = list(zip(chain, chain[1:]))
    return lines, n_tot[final]
