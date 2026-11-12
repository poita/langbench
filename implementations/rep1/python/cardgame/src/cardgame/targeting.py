"""Target legality, candidate enumeration and automatic choice (SPEC 12, 13.4)."""

from __future__ import annotations

from typing import Iterator

from .interp import Ctx
from .state import Entry, Obj, Player, target_key


class TargetingMixin:
    """Target-specification checks shared by play, activation and triggers."""

    def spectral_protected(self, o: Obj, ctrl: Player) -> bool:
        """12.2: spectral units cannot be targeted by the opponent."""
        return (o.zone == "field" and self.has_kw(o, "spectral")
                and self.ctrl(o) is not ctrl)

    def target_legal(self, spec: tuple, t, ctrl: Player, source: Obj,
                     exclude: Entry | None) -> bool:
        """Is *t* a legal target for the target specification *spec*?"""
        kind, filters = spec
        if kind == "player":
            return isinstance(t, Player)
        if kind == "chained":
            return (isinstance(t, Entry) and t is not exclude
                    and t in self.chain)
        if kind == "any" and isinstance(t, Player):
            return True
        if not isinstance(t, Obj):
            return False
        if kind == "ashcard":
            return t.zone == "ash" and self.match_filters(
                filters, t, Ctx(ctrl, source))
        if t.zone != "field":
            return False
        ctype = "relic" if kind == "relic" else "unit"
        if t.card.type != ctype:
            return False
        if filters and not self.match_filters(filters, t, Ctx(ctrl, source)):
            return False
        return not (ctype == "unit" and self.spectral_protected(t, ctrl))

    def candidates(self, spec: tuple, ctrl: Player, source: Obj,
                   exclude: Entry | None) -> list:
        """All legal targets for *spec*, in ascending target-key order."""
        kind = spec[0]
        out: list = []
        if kind == "chained":
            out = [e for e in self.chain if e is not exclude]
            out.sort(key=lambda e: e.cid)
            return out
        if kind in ("player", "any"):
            out.extend(self.players)
            if kind == "player":
                return out
        if kind == "ashcard":
            pool = [o for p in self.players for o in p.ash]
            pool.sort(key=lambda o: (o.ts, o.oid))
        else:
            pool = list(self.field.values())
        for o in pool:
            if self.target_legal(spec, o, ctrl, source, exclude):
                out.append(o)
        return out

    def target_tuples(self, specs: list, ctrl: Player, source: Obj,
                      exclude: Entry | None) -> Iterator[tuple]:
        """Every legal tuple of pairwise-distinct targets, in key order."""
        if not specs:
            yield ()
            return
        lists = [self.candidates(s, ctrl, source, exclude) for s in specs]
        if any(not l for l in lists):
            return
        chosen: list = []

        def walk(i: int):
            if i == len(lists):
                yield tuple(chosen)
                return
            for c in lists[i]:
                if any(c is d for d in chosen):
                    continue
                chosen.append(c)
                yield from walk(i + 1)
                chosen.pop()

        yield from walk(0)

    def auto_targets(self, specs: list, ctrl: Player, source: Obj) -> list | None:
        """13.4: the smallest-key legal, distinct candidate for each spec."""
        chosen: list = []
        for spec in specs:
            for c in self.candidates(spec, ctrl, source, None):
                if not any(c is d for d in chosen):
                    chosen.append(c)
                    break
            else:
                return None
        return chosen

    def has_targets(self, specs: list, ctrl: Player, source: Obj,
                    exclude: Entry | None) -> bool:
        for _ in self.target_tuples(specs, ctrl, source, exclude):
            return True
        return False
