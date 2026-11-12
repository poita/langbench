"""Effect interpreter: selectors, filters, amounts, conditions and effects."""

from __future__ import annotations

from .core import compare
from .model import render_keyword
from .state import Delayed, Entry, Obj, Player, target_key


class Ctx:
    """Evaluation context of one ability (SPEC 6)."""

    __slots__ = ("ctrl", "source", "entry", "it", "that")

    def __init__(self, ctrl: Player, source: Obj, entry: Entry | None = None,
                 it=None):
        self.ctrl = ctrl
        self.source = source
        self.entry = entry
        self.it = it
        self.that: list[Obj] = []

    def target(self, n: int):
        """The n-th target, or None when absent or removed."""
        e = self.entry
        if e is None or n < 1 or n > len(e.targets) or e.removed[n - 1]:
            return None
        return e.targets[n - 1]


class InterpMixin:
    """Tree-walking evaluator for the effect language."""

    def init_interp(self) -> None:
        self._fx = {}
        for name in (
            "damage", "destroy", "sacrifice", "exile", "bounce", "draw",
            "discard", "mill", "spire", "ember", "cap", "modify", "setbody",
            "swapstats", "grant", "strip", "control", "counters", "ready",
            "exhaust", "doom", "ward", "shield", "summon", "conjure",
            "reanimate", "recall", "negate", "dig", "delay", "if", "each",
            "repeat", "nothing",
        ):
            self._fx[name] = getattr(self, "fx_" + name)

    def _aura_ctx(self, rec) -> Ctx:
        return Ctx(rec.ctrl, rec.source)

    # ------------------------------------------------------------------
    # Filters
    # ------------------------------------------------------------------
    def match_filters(self, filters: list, o: Obj, ctx: Ctx) -> bool:
        for f in filters:
            if not self.match_filter(f, o, ctx):
                return False
        return True

    def match_filter(self, f: tuple, o: Obj, ctx: Ctx) -> bool:
        op = f[0]
        card = o.card
        if op == "kw":
            return f[1] in card.kw_names
        if op == "no-kw":
            return f[1] not in card.kw_names
        if op == "tag":
            return f[1] in card.tagset
        if op == "type":
            return card.type == f[1]
        if op == "cost":
            return compare(card.cost, f[1], f[2])
        if op == "edge":
            return compare(card.edge + o.counters, f[1], f[2])
        if op == "core":
            return compare(card.core + o.counters, f[1], f[2])
        if op == "wounded":
            return o.zone == "field" and o.wounds > 0
        if op == "ready":
            return o.zone == "field" and o.ready
        if op == "exhausted":
            return o.zone == "field" and not o.ready
        if op == "settling":
            return o.zone == "field" and o.since >= self.turn
        if op == "attacking":
            return o.attacking
        if op == "blocking":
            return o.blocking
        if op == "mine":
            return self._holder(o) is ctx.ctrl
        if op == "enemy":
            return self._holder(o) is not ctx.ctrl
        if op == "other":
            return o is not ctx.source
        return not self.match_filter(f[1], o, ctx)   # not

    def _holder(self, o: Obj) -> Player:
        """Current controller on the Field, owner elsewhere."""
        return self.ctrl(o) if o.zone == "field" else o.owner

    # ------------------------------------------------------------------
    # Selectors
    # ------------------------------------------------------------------
    def sel_objs(self, node: tuple, ctx: Ctx) -> list[Obj]:
        """Evaluate an object selector, in canonical object order."""
        op = node[0]
        if op == "self":
            return [ctx.source]
        if op == "it":
            return [ctx.it] if isinstance(ctx.it, Obj) else []
        if op == "that":
            return [ctx.that[-1]] if ctx.that else []
        if op == "t":
            t = ctx.target(node[1])
            return [t] if isinstance(t, Obj) else []
        if op == "units" or op == "relics":
            return self._field_select(op[:-1], node[1], node[2], ctx)
        if op == "random-unit":
            cands = self._field_select("unit", node[1], node[2], ctx)
            if not cands:
                return []
            return [cands[self.rng.below(len(cands))]]
        # cards
        zone, scope, filters = node[1], node[2], node[3]
        out: list[Obj] = []
        for p in self.players:
            if scope == "yours" and p is not ctx.ctrl:
                continue
            if scope == "theirs" and p is ctx.ctrl:
                continue
            for o in p.zone(zone):
                if self.match_filters(filters, o, ctx):
                    out.append(o)
        out.sort(key=lambda o: (o.ts, o.oid))
        return out

    def _field_select(self, ctype: str, scope: str, filters: list,
                      ctx: Ctx) -> list[Obj]:
        if self._dirty:
            self.derive()
        ctrl_map = self._ctrl
        me = ctx.ctrl
        out = []
        for o in self.field.values():
            if o.card.type != ctype:
                continue
            if scope != "all":
                mine = ctrl_map[o.oid] is me
                if mine != (scope == "yours"):
                    continue
            if filters and not self.match_filters(filters, o, ctx):
                continue
            out.append(o)
        return out

    def psel(self, node: tuple, ctx: Ctx) -> list[Player]:
        """Evaluate a player selector."""
        op = node[0]
        if op == "you":
            return [ctx.ctrl]
        if op == "foe":
            return [ctx.ctrl.opp]
        if op == "both":
            return [self.players[0], self.players[1]]
        if op == "t":
            t = ctx.target(node[1])
            return [t] if isinstance(t, Player) else []
        # owner-of
        inner = node[1]
        if inner[0] == "t":
            t = ctx.target(inner[1])
            if isinstance(t, Player):
                return [t]
        owners = {o.owner.idx for o in self.sel_objs(inner, ctx)}
        return [self.players[i] for i in sorted(owners)]

    def dsel(self, node: tuple, ctx: Ctx) -> list:
        """Evaluate a damage selector: players first, then objects."""
        op = node[0]
        if op in ("you", "foe", "both", "owner-of"):
            return self.psel(node, ctx)
        if op == "t":
            t = ctx.target(node[1])
            return [] if t is None or isinstance(t, Entry) else [t]
        return self.sel_objs(node, ctx)

    # ------------------------------------------------------------------
    # Amounts and conditions
    # ------------------------------------------------------------------
    def eval_amt(self, a, ctx: Ctx) -> int:
        if type(a) is int:
            return a
        op = a[0]
        if op == "count":
            return len(self.sel_objs(a[1], ctx))
        if op == "hand":
            return sum(len(p.hand) for p in self.psel(a[1], ctx))
        if op == "ash":
            return sum(len(p.ash) for p in self.psel(a[1], ctx))
        if op == "vault":
            return sum(len(p.vault) for p in self.psel(a[1], ctx))
        if op == "wounds":
            return sum(o.wounds for o in self.sel_objs(a[1], ctx))
        objs = self.sel_objs(a[1], ctx)
        if op == "edge":
            if self._aura_mode:
                return sum(o.card.edge + o.counters for o in objs)
            return sum(self.cur_edge(o) for o in objs)
        if self._aura_mode:
            return sum(o.card.core + o.counters for o in objs)
        return sum(self.cur_core(o) for o in objs)

    def eval_cond(self, c: tuple, ctx: Ctx) -> bool:
        op = c[0]
        if op == "count":
            return compare(len(self.sel_objs(c[1], ctx)), c[2], c[3])
        if op == "myturn":
            return self.active is ctx.ctrl
        if op == "and":
            return all(self.eval_cond(x, ctx) for x in c[1])
        if op == "or":
            return any(self.eval_cond(x, ctx) for x in c[1])
        if op == "not":
            return not self.eval_cond(c[1], ctx)
        players = self.psel(c[1], ctx)
        if op == "spire":
            total = sum(p.spire for p in players)
        elif op == "hand":
            total = sum(len(p.hand) for p in players)
        elif op == "ash":
            total = sum(len(p.ash) for p in players)
        elif op == "vault":
            total = sum(len(p.vault) for p in players)
        else:
            total = sum(p.ember for p in players)
        return compare(total, c[2], c[3])

    # ------------------------------------------------------------------
    # Effects
    # ------------------------------------------------------------------
    def run_effects(self, effects: list, ctx: Ctx) -> None:
        fx = self._fx
        for e in effects:
            fx[e[0]](e, ctx)

    def fx_nothing(self, e, ctx):
        pass

    def fx_damage(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        if n <= 0:
            return
        targets = self.dsel(e[2], ctx)
        if len(targets) > 1:
            targets.sort(key=target_key)
        for t in targets:
            self.deal_damage(ctx.source, t, n)

    def fx_destroy(self, e, ctx):
        for o in self.sel_objs(e[1], ctx):
            self.destroy(o)

    def fx_sacrifice(self, e, ctx):
        for o in self.sel_objs(e[1], ctx):
            self.sacrifice(o)

    def fx_exile(self, e, ctx):
        for o in self.sel_objs(e[1], ctx):
            self.exile(o)

    def fx_bounce(self, e, ctx):
        for o in self.sel_objs(e[1], ctx):
            self.bounce(o)

    def fx_draw(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        if n <= 0:
            return
        for p in self.psel(e[2], ctx):
            for _ in range(n):
                if not self.draw_card(p):
                    break

    def fx_discard(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        if n <= 0:
            return
        for p in self.psel(e[2], ctx):
            for _ in range(n):
                if not self.discard_card(p):
                    break

    def fx_mill(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        if n <= 0:
            return
        for p in self.psel(e[2], ctx):
            for _ in range(n):
                if not self.mill_card(p):
                    break

    def fx_spire(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        if n == 0:
            return
        for p in self.psel(e[2], ctx):
            self.change_spire(p, n)

    def fx_ember(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        if n <= 0:
            return
        for p in self.psel(e[2], ctx):
            self.gain_ember(p, n)

    def fx_cap(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        if n <= 0:
            return
        for p in self.psel(e[2], ctx):
            self.raise_cap(p, n)

    def _on_field(self, objs):
        return [o for o in objs if o.zone == "field"]

    def fx_modify(self, e, ctx):
        a = self.eval_amt(e[1], ctx)
        b = self.eval_amt(e[2], ctx)
        objs = self._on_field(self.sel_objs(e[3], ctx))
        self.add_record(ctx.ctrl, ctx.source, "modify", (a, b), objs)
        for o in objs:
            self.emit("BUFF", "#%d" % o.oid, a, b)

    def fx_setbody(self, e, ctx):
        a = self.eval_amt(e[1], ctx)
        b = self.eval_amt(e[2], ctx)
        objs = self._on_field(self.sel_objs(e[3], ctx))
        self.add_record(ctx.ctrl, ctx.source, "setbody", (a, b), objs)
        for o in objs:
            self.emit("SETBODY", "#%d" % o.oid, a, b)

    def fx_swapstats(self, e, ctx):
        objs = self._on_field(self.sel_objs(e[1], ctx))
        self.add_record(ctx.ctrl, ctx.source, "swapstats", None, objs)
        for o in objs:
            self.emit("SWAP", "#%d" % o.oid)

    def fx_grant(self, e, ctx):
        objs = self._on_field(self.sel_objs(e[2], ctx))
        self.add_record(ctx.ctrl, ctx.source, "grant", e[1], objs)
        name = render_keyword(*e[1])
        for o in objs:
            self.emit("GRANT", "#%d" % o.oid, name)

    def fx_strip(self, e, ctx):
        objs = self._on_field(self.sel_objs(e[1], ctx))
        self.add_record(ctx.ctrl, ctx.source, "strip", None, objs)
        for o in objs:
            self.emit("STRIP", "#%d" % o.oid)

    def fx_control(self, e, ctx):
        objs = self._on_field(self.sel_objs(e[1], ctx))
        self.add_record(ctx.ctrl, ctx.source, "control", None, objs)
        for o in objs:
            if o.card.type == "unit":
                o.since = self.turn
                self.remove_from_combat(o)
            self.emit("CONTROL", "#%d" % o.oid, ctx.ctrl.name)

    def fx_counters(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        for o in self.sel_objs(e[2], ctx):
            if o.zone == "field":
                self.add_counters(o, n)

    def fx_ready(self, e, ctx):
        for o in self.sel_objs(e[1], ctx):
            self.set_ready(o, True)

    def fx_exhaust(self, e, ctx):
        for o in self.sel_objs(e[1], ctx):
            self.set_ready(o, False)

    def fx_doom(self, e, ctx):
        for o in self.sel_objs(e[1], ctx):
            self.doom(o)

    def fx_ward(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        if n <= 0:
            return
        for o in self.sel_objs(e[2], ctx):
            if o.zone == "field":
                o.ward += n
                self.touch()
                self.emit("WARD", "#%d" % o.oid, n, o.ward)

    def fx_shield(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        if n <= 0:
            return
        for p in self.psel(e[2], ctx):
            p.shield += n
            self.emit("SHIELD", p.name, n, p.shield)

    def fx_summon(self, e, ctx):
        n = self.eval_amt(e[2], ctx)
        if n <= 0:
            return
        for p in self.psel(e[3], ctx):
            for _ in range(n):
                self.create_object(e[1], p, "field")

    def fx_conjure(self, e, ctx):
        n = self.eval_amt(e[2], ctx)
        if n <= 0:
            return
        for p in self.psel(e[3], ctx):
            for _ in range(n):
                self.create_object(e[1], p, "hand")

    def fx_reanimate(self, e, ctx):
        for o in self.sel_objs(e[1], ctx):
            self.reanimate(o, ctx.ctrl)

    def fx_recall(self, e, ctx):
        for o in self.sel_objs(e[1], ctx):
            self.recall(o)

    def fx_negate(self, e, ctx):
        t = ctx.target(e[1][1])
        if isinstance(t, Entry):
            self.negate_entry(t)

    def fx_dig(self, e, ctx):
        k, filters = e[1], e[2]
        for p in self.psel(e[3], ctx):
            taken = []
            for _ in range(min(max(k, 0), len(p.vault))):
                taken.append(p.vault.popleft())
            hit = None
            for o in taken:
                if self.match_filters(filters, o, ctx):
                    hit = o
                    break
            if hit is not None:
                taken.remove(hit)
                hit.zone = "hand"
                p.hand.append(hit)
                self.emit("DIG", p.name, "#%d" % hit.oid, hit.card.id)
            else:
                self.emit("DIG-MISS", p.name)
            for o in taken:
                p.vault.append(o)
                self.emit("BOTTOM", p.name, "#%d" % o.oid, o.card.id)

    def fx_delay(self, e, ctx):
        entry = ctx.entry
        targets = list(entry.targets) if entry else []
        tspecs = list(entry.tspecs) if entry else []
        d = Delayed(self.new_ts(), ctx.ctrl, e[1], ctx.source, targets,
                    tspecs, e[2])
        self.delayed.append(d)
        self.emit("DELAY", ctx.ctrl.name, e[1])

    def fx_if(self, e, ctx):
        if self.eval_cond(e[1], ctx):
            self.run_effects(e[2], ctx)
        elif e[3] is not None:
            self.run_effects(e[3], ctx)

    def fx_each(self, e, ctx):
        objs = self.sel_objs(e[1], ctx)
        zones = [o.zone for o in objs]
        body = e[2]
        for o, z in zip(objs, zones):
            if o.zone != z:
                continue
            ctx.that.append(o)
            try:
                self.run_effects(body, ctx)
            finally:
                ctx.that.pop()

    def fx_repeat(self, e, ctx):
        n = self.eval_amt(e[1], ctx)
        for _ in range(n):
            self.run_effects(e[2], ctx)
