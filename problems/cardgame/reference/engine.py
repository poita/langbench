"""The Spiremark rules engine (SPEC.md sections 7-21).

The engine is driven as a generator: `Game.begin()` runs setup and stops at
the first decision point, and `Game.resume()` applies the action stored in
`Game.action` and runs forward to the next decision point.
"""

import itertools

from cards import Sym, head, render_kw

OTHER = {"A": "B", "B": "A"}
PLAYERS = ("A", "B")


class GameOver(Exception):
    """Raised as soon as the match ends; it unwinds everything."""


def canon_key(o):
    return (o.ts, o.oid)


# ------------------------------------------------------------------ objects --

class Obj:
    """A card instance.  `zone` is one of vault/hand/field/ash/rift/chain."""

    __slots__ = ("oid", "card", "owner", "zone", "base_ctrl", "left_ctrl", "ts",
                 "ready", "wounds", "counters", "ward", "doomed", "since",
                 "attacking", "blocking", "blockers", "blocked",
                 "tenacity_used", "once_used", "dealt_combat")

    def __init__(self, oid, card, owner):
        self.oid = oid
        self.card = card
        self.owner = owner
        self.zone = "vault"
        self.base_ctrl = owner
        self.left_ctrl = None
        self.ts = 0
        self.clear_field_state()

    def clear_field_state(self):
        self.ready = True
        self.wounds = 0
        self.counters = 0
        self.ward = 0
        self.doomed = False
        self.since = 0
        self.attacking = False
        self.blocking = None
        self.blockers = []
        self.blocked = False
        self.tenacity_used = False
        self.once_used = set()
        self.dealt_combat = False


class Target:
    """A chosen target: a player, a Field/Ash object, or a Chain entry."""

    __slots__ = ("kind", "player", "obj", "entry", "removed")

    def __init__(self, kind, player=None, obj=None, entry=None):
        self.kind = kind
        self.player = player
        self.obj = obj
        self.entry = entry
        self.removed = False

    @staticmethod
    def of_player(p):
        return Target("player", player=p)

    @staticmethod
    def of_obj(o):
        return Target("obj", obj=o)

    @staticmethod
    def of_entry(e):
        return Target("chain", entry=e)

    def token(self):
        if self.kind == "player":
            return self.player
        if self.kind == "obj":
            return "#%d" % self.obj.oid
        return "~%d" % self.entry.cid

    def render(self):
        return "-" if self.removed else self.token()

    def key(self):
        if self.kind == "player":
            return (0, 0 if self.player == "A" else 1, 0)
        if self.kind == "obj":
            return (1, self.obj.ts, self.obj.oid)
        return (2, self.entry.cid, 0)

    def copy(self):
        return Target(self.kind, self.player, self.obj, self.entry)


class Record:
    """A continuous-effect record (SPEC.md 14.1)."""

    __slots__ = ("eid", "ts", "ctrl0", "source", "kind", "duration", "args",
                 "affected", "static", "cond", "inner")

    def __init__(self, eid, ts, ctrl0, source, kind, duration):
        self.eid = eid
        self.ts = ts
        self.ctrl0 = ctrl0            # fixed controller of a discrete record
        self.source = source
        self.kind = kind
        self.duration = duration
        self.args = None              # discrete arguments
        self.affected = None          # discrete affected list
        self.static = None            # raw static node of an aura record
        self.cond = None              # the (when ...) condition, if any
        self.inner = None             # the static under a (when ...)


class Entry:
    """A Chain entry (SPEC.md 10.1)."""

    __slots__ = ("cid", "kind", "ctrl", "source", "index", "targets", "tspecs",
                 "ability", "effects", "subject")

    def __init__(self, cid, kind, ctrl, source, index):
        self.cid = cid
        self.kind = kind
        self.ctrl = ctrl
        self.source = source
        self.index = index
        self.targets = []
        self.tspecs = []
        self.ability = None
        self.effects = None           # for a delayed trigger
        self.subject = None           # the trigger subject `it`


class Pending:
    """A collected trigger waiting to be pushed (SPEC.md 13.3)."""

    __slots__ = ("ctrl", "source", "ability", "index", "subject", "ts",
                 "effects", "targets", "tspecs", "delayed")

    def __init__(self, ctrl, source, index, ts):
        self.ctrl = ctrl
        self.source = source
        self.ability = None
        self.index = index
        self.subject = None
        self.ts = ts
        self.effects = None
        self.targets = None
        self.tspecs = []
        self.delayed = False

    def key(self, active):
        return (0 if self.ctrl == active else 1, self.ts, self.source.oid,
                self.index)


class Delayed:
    """A delayed trigger record (SPEC.md 13.5)."""

    __slots__ = ("ts", "ctrl", "when", "source", "effects", "targets", "tspecs")

    def __init__(self, ts, ctrl, when, source, effects, targets, tspecs):
        self.ts = ts
        self.ctrl = ctrl
        self.when = when
        self.source = source
        self.effects = effects
        self.targets = targets
        self.tspecs = tspecs


class Ctx:
    """Evaluation context for an ability's effects."""

    __slots__ = ("ctrl", "source", "it", "targets", "tspecs", "that")

    def __init__(self, ctrl, source, it=None, targets=None, tspecs=None):
        self.ctrl = ctrl
        self.source = source
        self.it = it
        self.targets = targets if targets is not None else []
        self.tspecs = tspecs if tspecs is not None else []
        self.that = []


class Derived:
    """One snapshot of derived characteristics (SPEC.md 14.3)."""

    __slots__ = ("ctrl", "inactive", "kw", "edge", "core", "cheaper",
                 "aura_objs", "aura_active", "aura_amt")


class Action:
    """A parsed, accepted script action."""

    __slots__ = ("kind", "player", "pos", "oid", "index", "targets", "objs",
                 "pairs")

    def __init__(self, kind, player):
        self.kind = kind
        self.player = player
        self.pos = 0
        self.oid = 0
        self.index = 0
        self.targets = []
        self.objs = []
        self.pairs = []


class Rng:
    """xorshift64* (SPEC.md 25)."""

    MASK = (1 << 64) - 1
    MULT = 0x2545F4914F6CDD1D

    def __init__(self, seed):
        self.state = seed & Rng.MASK
        if self.state == 0:
            self.state = Rng.MULT

    def next(self):
        s = self.state
        s ^= s >> 12
        s &= Rng.MASK
        s ^= (s << 25) & Rng.MASK
        s ^= s >> 27
        self.state = s
        return (s * Rng.MULT) & Rng.MASK

    def below(self, n):
        return self.next() % n


CMP_FN = {
    "le": lambda a, b: a <= b,
    "lt": lambda a, b: a < b,
    "eq": lambda a, b: a == b,
    "ge": lambda a, b: a >= b,
    "gt": lambda a, b: a > b,
    "ne": lambda a, b: a != b,
}

LAYER_OF = {"control": 1, "grant": 2, "strip": 2, "setbody": 3, "modify": 4,
            "swapstats": 6, "cheaper": 0}


def static_kind(node):
    h = head(node)
    return h


# --------------------------------------------------------------------- game --

class Game:
    def __init__(self, db, conf, out):
        self.db = db
        self.conf = conf
        self.out = out
        self.seq = 0
        self.version = 1
        self._dctx = None
        self._deriving = False
        self._d = None
        self._dv = 0
        self._fs = []
        self._fs_ver = 0
        self._fu = []
        self._fr = []

        self.spire = {"A": conf["spire"], "B": conf["spire"]}
        self.ember = {"A": 0, "B": 0}
        self.cap = {"A": conf["cap"]["A"], "B": conf["cap"]["B"]}
        self.shield = {"A": 0, "B": 0}
        self.zones = {p: {"vault": [], "hand": [], "ash": [], "rift": []}
                      for p in PLAYERS}
        self.field = []
        self.chain = []
        self.records = []
        self.delayed = []
        self.pending = []
        self.objects = {}

        self.next_oid = 1
        self.ts_counter = 1
        self.eid_counter = 1
        self.cid_counter = 1

        self.maxcap = conf["maxcap"]
        self.handmax = conf["handmax"]
        self.turnlimit = conf["turnlimit"]
        self.first = conf["first"]
        self.active = conf["first"]
        self.turn = 1
        self.cur_phase = "dawn"
        self.decision = None
        self.holder = conf["first"]
        self.passes = 0
        self.triggers_on = True
        self.lost = {}
        self.result = None
        self.over = False
        self.action = None
        self.gen = None
        self.rng = Rng(conf["seed"])

    # ------------------------------------------------------------- plumbing --

    def touch(self):
        self.version += 1

    def emit(self, line):
        self.seq += 1
        self.out.append("%d %s" % (self.seq, line))

    def new_ts(self):
        v = self.ts_counter
        self.ts_counter += 1
        return v

    def new_eid(self):
        v = self.eid_counter
        self.eid_counter += 1
        return v

    def new_cid(self):
        v = self.cid_counter
        self.cid_counter += 1
        return v

    def new_object(self, cid, owner):
        o = Obj(self.next_oid, self.db[cid], owner)
        self.objects[o.oid] = o
        self.next_oid += 1
        return o

    def field_sorted(self):
        """The Field in canonical order; the returned list is read-only."""
        if self._fs_ver != self.version:
            fs = sorted(self.field, key=canon_key)
            self._fs = fs
            self._fu = [o for o in fs if o.card.type == "unit"]
            self._fr = [o for o in fs if o.card.type == "relic"]
            self._fs_ver = self.version
        return self._fs

    def field_of_type(self, want):
        self.field_sorted()
        return self._fu if want == "unit" else self._fr

    # ---------------------------------------------------------- derivation --

    def derived(self):
        if self._dv == self.version and self._d is not None:
            return self._d
        d = self._compute_derived()
        self._d = d
        self._dv = self.version
        return d

    def _compute_derived(self):
        D = Derived()
        field = self.field_sorted()
        D.ctrl = {o.oid: o.base_ctrl for o in field}
        recs = sorted(self.records, key=lambda r: (r.ts, r.eid))
        for r in recs:
            if r.kind == "control" and r.duration == "turn":
                for o in r.affected:
                    if o.zone == "field":
                        D.ctrl[o.oid] = r.ctrl0
        D.inactive = set()
        for r in recs:
            if r.kind == "strip" and r.duration == "turn":
                for o in r.affected:
                    if o.zone == "field":
                        D.inactive.add(o.oid)
        D.kw = {}
        D.edge = {}
        D.core = {}
        D.cheaper = []
        D.aura_objs = {}
        D.aura_active = {}
        D.aura_amt = {}
        prev_ctx, prev_der = self._dctx, self._deriving
        self._dctx = D
        self._deriving = True
        try:
            for r in recs:
                if r.duration != "aura":
                    continue
                self._eval_aura(r, D)
            # Layer 2: keywords and ability removal.
            for o in field:
                D.kw[o.oid] = list(o.card.keywords)
            for r in recs:
                if r.kind not in ("grant", "strip"):
                    continue
                if r.duration == "aura":
                    if not D.aura_active[r.eid]:
                        continue
                    objs = D.aura_objs[r.eid]
                    kwspec = D.aura_amt[r.eid]
                else:
                    objs = [o for o in r.affected if o.zone == "field"]
                    kwspec = r.args
                if r.kind == "grant":
                    for o in objs:
                        D.kw[o.oid].append(kwspec)
                else:
                    for o in objs:
                        D.kw[o.oid] = []
            # Layers 3 to 6: edge and core.
            for o in field:
                D.edge[o.oid] = o.card.edge
                D.core[o.oid] = o.card.core
            for layer in (3, 4):
                for r in recs:
                    if LAYER_OF.get(r.kind) != layer:
                        continue
                    objs, args = self._record_apply(r, D)
                    if objs is None:
                        continue
                    for o in objs:
                        if layer == 3:
                            D.edge[o.oid] = args[0]
                            D.core[o.oid] = args[1]
                        else:
                            D.edge[o.oid] += args[0]
                            D.core[o.oid] += args[1]
            for o in field:
                D.edge[o.oid] += o.counters
                D.core[o.oid] += o.counters
            for r in recs:
                if r.kind != "swapstats":
                    continue
                objs, _ = self._record_apply(r, D)
                if objs is None:
                    continue
                for o in objs:
                    D.edge[o.oid], D.core[o.oid] = D.core[o.oid], D.edge[o.oid]
            for r in recs:
                if r.kind != "cheaper":
                    continue
                if r.duration == "aura":
                    if not D.aura_active[r.eid]:
                        continue
                    n, filters = D.aura_amt[r.eid]
                    D.cheaper.append((n, filters, self.ctrl(r.source)))
        finally:
            self._dctx = prev_ctx
            self._deriving = prev_der
        return D

    def aura_amounts(self, r):
        """The arguments an aura record would use now, for a `DUMP` line."""
        node = r.inner if r.cond is not None else r.static
        ctx = Ctx(self.ctrl(r.source), r.source)
        prev = self._deriving
        self._deriving = True
        try:
            if head(node) == "cheaper":
                return (node[1], node[2:])
            if head(node) == "grant":
                return kwspec_pair(node[1])
            if head(node) == "swapstats":
                return None
            return (self.eval_amount(node[1], ctx), self.eval_amount(node[2], ctx))
        finally:
            self._deriving = prev

    def _record_apply(self, r, D):
        """The (objects, args) a layer-3/4/6 record contributes right now."""
        if r.duration == "aura":
            if not D.aura_active[r.eid]:
                return None, None
            return D.aura_objs[r.eid], D.aura_amt[r.eid]
        return [o for o in r.affected if o.zone == "field"], r.args

    def _eval_aura(self, r, D):
        """Evaluate one aura record's activity, affected list and arguments."""
        src = r.source
        active = src.zone == "field" and src.oid not in D.inactive
        node = r.inner if r.cond is not None else r.static
        ctx = Ctx(self.ctrl(src), src)
        if active and r.cond is not None:
            active = self.eval_cond(r.cond, ctx)
        h = head(node)
        if h == "cheaper":
            D.aura_amt[r.eid] = (node[1], node[2:])
            D.aura_objs[r.eid] = []
        elif h == "grant":
            D.aura_amt[r.eid] = kwspec_pair(node[1])
            D.aura_objs[r.eid] = (self.sel_field_objects(node[2], ctx)
                                  if active else [])
        elif h == "swapstats":
            D.aura_amt[r.eid] = None
            D.aura_objs[r.eid] = (self.sel_field_objects(node[1], ctx)
                                  if active else [])
        elif active:
            D.aura_amt[r.eid] = (self.eval_amount(node[1], ctx),
                                 self.eval_amount(node[2], ctx))
            D.aura_objs[r.eid] = self.sel_field_objects(node[3], ctx)
        else:
            D.aura_amt[r.eid] = None
            D.aura_objs[r.eid] = []
        D.aura_active[r.eid] = active

    # ------------------------------------------------ characteristic access --

    def ctrl(self, o):
        if o.zone != "field":
            return o.left_ctrl if o.left_ctrl is not None else o.owner
        D = self._dctx if self._dctx is not None else self.derived()
        return D.ctrl.get(o.oid, o.base_ctrl)

    def abilities_inactive(self, o):
        if o.zone != "field":
            return False
        D = self._dctx if self._dctx is not None else self.derived()
        return o.oid in D.inactive

    def cur_kw(self, o):
        if o.zone != "field":
            return list(o.card.keywords)
        return self.derived().kw.get(o.oid, [])

    def has_kw(self, o, name):
        return any(k == name for k, _ in self.cur_kw(o))

    def plating_total(self, o):
        return sum(v for k, v in self.cur_kw(o) if k == "plating")

    def cur_edge(self, o):
        if o.zone != "field":
            return o.card.edge
        return self.derived().edge.get(o.oid, o.card.edge)

    def cur_core(self, o):
        if o.zone != "field":
            return o.card.core
        return self.derived().core.get(o.oid, o.card.core)

    def base_edge(self, o):
        return o.card.edge + o.counters

    def base_core(self, o):
        return o.card.core + o.counters

    def settling(self, o):
        return o.zone == "field" and o.since >= self.turn

    def kwlist(self, o):
        kws = self.cur_kw(o)
        names = sorted({k for k, _ in kws if k != "plating"})
        total = sum(v for k, v in kws if k == "plating")
        out = list(names)
        if any(k == "plating" for k, _ in kws):
            out.append("plating:%d" % total)
        return sorted(out)

    # ------------------------------------------------------------ selectors --

    def side_of(self, o):
        return self.ctrl(o) if o.zone == "field" else o.owner

    def filter_ok(self, o, f, ctx):
        h = f[0].s
        card = o.card
        if h == "kw":
            name = f[1].s
            return any(k == name for k, _ in card.keywords)
        if h == "no-kw":
            name = f[1].s
            return not any(k == name for k, _ in card.keywords)
        if h == "tag":
            return f[1].s in card.tags
        if h == "type":
            return card.type == f[1].s
        if h == "cost":
            return CMP_FN[f[1].s](card.cost, f[2])
        if h == "edge":
            return CMP_FN[f[1].s](self.base_edge(o), f[2])
        if h == "core":
            return CMP_FN[f[1].s](self.base_core(o), f[2])
        if h == "wounded":
            return o.zone == "field" and o.wounds >= 1
        if h == "ready":
            return o.zone == "field" and o.ready
        if h == "exhausted":
            return o.zone == "field" and not o.ready
        if h == "settling":
            return self.settling(o)
        if h == "attacking":
            return o.zone == "field" and o.attacking
        if h == "blocking":
            return o.zone == "field" and o.blocking is not None
        if h == "mine":
            return self.side_of(o) == ctx.ctrl
        if h == "enemy":
            return self.side_of(o) != ctx.ctrl
        if h == "other":
            return o is not ctx.source
        if h == "not":
            return not self.filter_ok(o, f[1], ctx)
        return False

    def filters_ok(self, o, filters, ctx):
        for f in filters:
            if not self.filter_ok(o, f, ctx):
                return False
        return True

    def sel_objects(self, node, ctx):
        """Evaluate an object selector, in canonical order."""
        if isinstance(node, Sym):
            name = node.s
            if name == "self":
                return [ctx.source]
            if name == "it":
                return [ctx.it] if isinstance(ctx.it, Obj) else []
            if name == "that":
                return [ctx.that[-1]] if ctx.that else []
            return []
        h = head(node)
        if h == "t":
            n = node[1]
            if 1 <= n <= len(ctx.targets):
                t = ctx.targets[n - 1]
                if not t.removed and t.kind == "obj":
                    return [t.obj]
            return []
        if h in ("units", "relics", "random-unit"):
            want = "relic" if h == "relics" else "unit"
            scope = node[1].s
            filters = node[2:]
            pool = self.field_of_type(want)
            if scope != "all":
                D = self._dctx if self._dctx is not None else self.derived()
                cmap = D.ctrl
                cc = ctx.ctrl
                mine = scope == "yours"
                pool = [o for o in pool
                        if (cmap.get(o.oid, o.base_ctrl) == cc) == mine]
            if filters:
                pool = [o for o in pool if self.filters_ok(o, filters, ctx)]
            elif pool is self._fu or pool is self._fr:
                pool = list(pool)
            if h == "random-unit":
                if not pool:
                    return []
                return [pool[self.rng.below(len(pool))]]
            return pool
        if h == "cards":
            zone = node[1].s
            scope = node[2].s
            filters = node[3:]
            objs = []
            for p in PLAYERS:
                if scope == "yours" and p != ctx.ctrl:
                    continue
                if scope == "theirs" and p == ctx.ctrl:
                    continue
                objs.extend(self.zones[p][zone])
            objs = [o for o in objs if self.filters_ok(o, filters, ctx)]
            objs.sort(key=canon_key)
            return objs
        return []

    def sel_field_objects(self, node, ctx):
        return [o for o in self.sel_objects(node, ctx) if o.zone == "field"]

    def sel_players(self, node, ctx):
        if isinstance(node, Sym):
            name = node.s
            if name == "you":
                return [ctx.ctrl]
            if name == "foe":
                return [OTHER[ctx.ctrl]]
            if name == "both":
                return ["A", "B"]
            return []
        h = head(node)
        if h == "t":
            n = node[1]
            if 1 <= n <= len(ctx.targets):
                t = ctx.targets[n - 1]
                if not t.removed and t.kind == "player":
                    return [t.player]
            return []
        if h == "owner-of":
            inner = node[1]
            if head(inner) == "t":
                n = inner[1]
                if 1 <= n <= len(ctx.targets):
                    t = ctx.targets[n - 1]
                    if not t.removed and t.kind == "player":
                        return [t.player]
            seen = []
            for o in self.sel_objects(inner, ctx):
                if o.owner not in seen:
                    seen.append(o.owner)
            return [p for p in PLAYERS if p in seen]
        return []

    def sel_damage(self, node, ctx):
        """A damage selector (SPEC.md 6.4.1): a list of players and objects."""
        if isinstance(node, Sym) and node.s in ("you", "foe", "both"):
            return list(self.sel_players(node, ctx))
        if head(node) == "owner-of":
            return list(self.sel_players(node, ctx))
        if head(node) == "t":
            n = node[1]
            if 1 <= n <= len(ctx.targets):
                t = ctx.targets[n - 1]
                if t.removed:
                    return []
                if t.kind == "player":
                    return [t.player]
                if t.kind == "obj":
                    return [t.obj]
            return []
        return list(self.sel_objects(node, ctx))

    # -------------------------------------------------- amounts, conditions --

    def eval_amount(self, node, ctx):
        if isinstance(node, int):
            return node
        h = head(node)
        if h == "count":
            return len(self.sel_objects(node[1], ctx))
        if h == "hand":
            return sum(len(self.zones[p]["hand"])
                       for p in self.sel_players(node[1], ctx))
        if h == "ash":
            return sum(len(self.zones[p]["ash"])
                       for p in self.sel_players(node[1], ctx))
        if h == "vault":
            return sum(len(self.zones[p]["vault"])
                       for p in self.sel_players(node[1], ctx))
        if h == "edge":
            objs = self.sel_objects(node[1], ctx)
            if self._deriving:
                return sum(self.base_edge(o) for o in objs)
            return sum(self.cur_edge(o) for o in objs)
        if h == "core":
            objs = self.sel_objects(node[1], ctx)
            if self._deriving:
                return sum(self.base_core(o) for o in objs)
            return sum(self.cur_core(o) for o in objs)
        if h == "wounds":
            return sum(o.wounds for o in self.sel_objects(node[1], ctx))
        return 0

    def eval_cond(self, node, ctx):
        h = head(node)
        if h == "count":
            return CMP_FN[node[2].s](len(self.sel_objects(node[1], ctx)), node[3])
        if h == "spire":
            v = sum(self.spire[p] for p in self.sel_players(node[1], ctx))
            return CMP_FN[node[2].s](v, node[3])
        if h == "hand":
            v = sum(len(self.zones[p]["hand"]) for p in self.sel_players(node[1], ctx))
            return CMP_FN[node[2].s](v, node[3])
        if h == "ash":
            v = sum(len(self.zones[p]["ash"]) for p in self.sel_players(node[1], ctx))
            return CMP_FN[node[2].s](v, node[3])
        if h == "vault":
            v = sum(len(self.zones[p]["vault"]) for p in self.sel_players(node[1], ctx))
            return CMP_FN[node[2].s](v, node[3])
        if h == "ember":
            v = sum(self.ember[p] for p in self.sel_players(node[1], ctx))
            return CMP_FN[node[2].s](v, node[3])
        if h == "myturn":
            return self.active == ctx.ctrl
        if h == "and":
            return all(self.eval_cond(c, ctx) for c in node[1:])
        if h == "or":
            return any(self.eval_cond(c, ctx) for c in node[1:])
        if h == "not":
            return not self.eval_cond(node[1], ctx)
        return False

    # -------------------------------------------------------- zone movement --

    def remove_from_zone(self, o):
        if o.zone == "field":
            self.field.remove(o)
        elif o.zone == "chain":
            pass
        else:
            self.zones[o.owner][o.zone].remove(o)

    # ----------------------------------------------------------- state ends --

    def record_loss(self, p, reason):
        if p not in self.lost:
            self.lost[p] = reason
            self.touch()

    def end_match(self):
        for p in PLAYERS:
            if p in self.lost:
                self.emit("LOSE %s %s" % (p, self.lost[p]))
        if len(self.lost) == 2:
            winner, reason = "draw", self.lost["A"]
        else:
            p = "A" if "A" in self.lost else "B"
            winner, reason = OTHER[p], self.lost[p]
        self.result = (winner, reason)
        self.emit("RESULT %s %s" % (winner, reason))
        self.over = True
        self.decision = None
        raise GameOver()

    def end_draw(self, reason):
        self.result = ("draw", reason)
        self.emit("RESULT draw %s" % reason)
        self.over = True
        self.decision = None
        raise GameOver()

    def concede(self, p):
        self.record_loss(p, "concede")
        self.end_match()

    # -------------------------------------------------------- state checks --

    def state_checks(self):
        for p in PLAYERS:
            if self.spire[p] <= 0:
                self.record_loss(p, "spire")
        if self.lost:
            self.end_match()
        victims = [o for o in self.field
                   if o.card.type == "unit"
                   and (self.cur_core(o) <= o.wounds or o.doomed)]
        if not victims:
            return False
        for o in sorted(victims, key=canon_key):
            if o.zone == "field":
                self.destroy(o)
        return True

    def settle(self):
        acted = False
        while True:
            a = self.state_checks()
            b = self.push_triggers()
            acted = acted or a or b
            if not a and not b:
                return acted

    def drain(self):
        while True:
            self.settle()
            if not self.chain:
                return
            self.resolve_top()

    # ------------------------------------------------------------- triggers --

    def add_pending(self, o, ability, ctrl, subject):
        if not self.triggers_on:
            return
        p = Pending(ctrl, o, ability.index, o.ts)
        p.ability = ability
        p.subject = subject
        p.tspecs = ability.tspecs
        self.pending.append(p)

    def collect_from(self, o, event, subject, ctrl=None):
        if not self.triggers_on:
            return
        if o.zone == "field" and self.abilities_inactive(o):
            return
        c = ctrl if ctrl is not None else self.ctrl(o)
        for ab in o.card.abilities:
            if ab.kind == "on" and ab.event == event:
                self.add_pending(o, ab, c, subject)

    def collect_all(self, event, subject, only_active_ctrl=False):
        if not self.triggers_on:
            return
        for o in self.field_sorted():
            if self.abilities_inactive(o):
                continue
            c = self.ctrl(o)
            if only_active_ctrl and c != self.active:
                continue
            for ab in o.card.abilities:
                if ab.kind == "on" and ab.event == event:
                    self.add_pending(o, ab, c, subject)

    def collect_spire_loss(self, p):
        if not self.triggers_on:
            return
        for o in self.field_sorted():
            if self.abilities_inactive(o):
                continue
            c = self.ctrl(o)
            event = "spire-loss" if c == p else "enemy-spire-loss"
            for ab in o.card.abilities:
                if ab.kind == "on" and ab.event == event:
                    self.add_pending(o, ab, c, p)

    def fire_delayed(self, when, only_ctrl=None):
        if not self.delayed:
            return
        keep = []
        for d in self.delayed:
            if d.when == when and (only_ctrl is None or d.ctrl == only_ctrl):
                p = Pending(d.ctrl, d.source, 0, d.ts)
                p.delayed = True
                p.effects = d.effects
                p.targets = [t.copy() for t in d.targets]
                p.tspecs = d.tspecs
                self.pending.append(p)
            else:
                keep.append(d)
        self.delayed = keep
        self.touch()

    def push_triggers(self):
        if not self.pending:
            return False
        batch = self.pending
        self.pending = []
        batch.sort(key=lambda p: p.key(self.active))
        entries = []
        for p in batch:
            if p.delayed:
                targets = p.targets
            else:
                targets = self.auto_targets(p)
                if targets is None:
                    self.emit("TRIGGER-NO-TARGET %s #%d %d"
                              % (p.ctrl, p.source.oid, p.index))
                    continue
            e = Entry(self.new_cid(), "trigger", p.ctrl, p.source, p.index)
            e.targets = targets
            e.tspecs = p.tspecs
            e.ability = p.ability
            e.effects = p.effects
            e.subject = p.subject
            entries.append((e, p))
            line = "TRIGGER %s ~%d #%d %d" % (p.ctrl, e.cid, p.source.oid, p.index)
            if targets:
                line += " " + " ".join(t.render() for t in targets)
            self.emit(line)
        for e, _ in reversed(entries):
            self.chain.append(e)
        self.touch()
        return True

    def auto_targets(self, p):
        if not p.tspecs:
            return []
        chosen = []
        used = set()
        for ts in p.tspecs:
            cands = self.candidates(ts, p.ctrl, p.source, None)
            pick = None
            for c in cands:
                if c.token() not in used:
                    pick = c
                    break
            if pick is None:
                return None
            used.add(pick.token())
            chosen.append(pick)
        return chosen

    # ------------------------------------------------------------ targeting --

    def spectral_protected(self, o, ctrl):
        return (o.card.type == "unit" and o.zone == "field"
                and self.has_kw(o, "spectral") and self.ctrl(o) != ctrl)

    def target_legal(self, t, tspec, ctrl, source, exclude_entry):
        h = head(tspec)
        ctx = Ctx(ctrl, source)
        if h == "player":
            return t.kind == "player"
        if h == "chained":
            return (t.kind == "chain" and t.entry in self.chain
                    and t.entry is not exclude_entry)
        if h == "ashcard":
            if t.kind != "obj" or t.obj.zone != "ash":
                return False
            return self.filters_ok(t.obj, tspec[1:], ctx)
        if h == "any" and t.kind == "player":
            return True
        want = "relic" if h == "relic" else "unit"
        if t.kind != "obj":
            return False
        o = t.obj
        if o.zone != "field" or o.card.type != want:
            return False
        if not self.filters_ok(o, tspec[1:], ctx):
            return False
        if self.spectral_protected(o, ctrl):
            return False
        return True

    def candidates(self, tspec, ctrl, source, exclude_entry):
        h = head(tspec)
        ctx = Ctx(ctrl, source)
        out = []
        if h in ("player", "any"):
            out.extend(Target.of_player(p) for p in PLAYERS)
        if h in ("unit", "any", "relic"):
            want = "relic" if h == "relic" else "unit"
            for o in self.field_sorted():
                if o.card.type != want:
                    continue
                if not self.filters_ok(o, tspec[1:], ctx):
                    continue
                if self.spectral_protected(o, ctrl):
                    continue
                out.append(Target.of_obj(o))
        if h == "chained":
            for e in self.chain:
                if e is not exclude_entry:
                    out.append(Target.of_entry(e))
        if h == "ashcard":
            cards = []
            for p in PLAYERS:
                cards.extend(self.zones[p]["ash"])
            cards.sort(key=canon_key)
            for o in cards:
                if self.filters_ok(o, tspec[1:], ctx):
                    out.append(Target.of_obj(o))
        out.sort(key=lambda t: t.key())
        return out

    def target_tuples(self, tspecs, ctrl, source, exclude_entry, limit=None):
        """All legal target tuples in ascending lexicographic key order."""
        lists = [self.candidates(ts, ctrl, source, exclude_entry) for ts in tspecs]
        if any(not l for l in lists):
            return []
        out = []
        for combo in itertools.product(*lists):
            toks = [t.token() for t in combo]
            if len(set(toks)) != len(toks):
                continue
            out.append(combo)
            if limit is not None and len(out) >= limit:
                break
        return out

    # ------------------------------------------------------- damage & state --

    def render_thing(self, x):
        return ("#%d" % x.oid) if isinstance(x, Obj) else x

    def thing_key(self, x):
        if isinstance(x, Obj):
            return (1, x.ts, x.oid)
        return (0, 0 if x == "A" else 1, 0)

    def deal_damage(self, pairs):
        """Deal a batch of (source, target, amount) triples (SPEC.md 17.2)."""
        pairs = [p for p in pairs if p[2] > 0]
        pairs.sort(key=lambda p: (self.thing_key(p[0]), self.thing_key(p[1])))
        for src, tgt, n in pairs:
            self.deal_one(src, tgt, n)

    def deal_one(self, src, tgt, n):
        if n <= 0:
            return
        if isinstance(tgt, Obj):
            if tgt.card.type != "unit" or tgt.zone != "field":
                return
        prevented = 0
        if isinstance(tgt, Obj):
            p = self.plating_total(tgt)
            if p > 0:
                d = min(p, n)
                n -= d
                prevented += d
            if tgt.ward > 0 and n > 0:
                u = min(tgt.ward, n)
                tgt.ward -= u
                n -= u
                prevented += u
                self.touch()
        else:
            if self.shield[tgt] > 0 and n > 0:
                u = min(self.shield[tgt], n)
                self.shield[tgt] -= u
                n -= u
                prevented += u
                self.touch()
        tname = self.render_thing(tgt)
        if prevented > 0:
            self.emit("PREVENT %s %d" % (tname, prevented))
        if n == 0:
            return
        self.emit("DAMAGE %s %s %d" % (self.render_thing(src), tname, n))
        if isinstance(tgt, Obj):
            tgt.wounds += n
            self.touch()
        else:
            self.spire[tgt] -= n
            self.touch()
            self.emit("SPIRE %s -%d %d" % (tgt, n, self.spire[tgt]))
            self.collect_spire_loss(tgt)
        src_unit = (isinstance(src, Obj) and src.zone == "field"
                    and src.card.type == "unit")
        if isinstance(tgt, Obj) and src_unit and self.has_kw(src, "venom"):
            tgt.doomed = True
            self.touch()
            self.emit("DOOM #%d" % tgt.oid)
        if src_unit and self.has_kw(src, "siphon"):
            c = self.ctrl(src)
            self.spire[c] += n
            self.touch()
            self.emit("SPIRE %s +%d %d" % (c, n, self.spire[c]))
        if isinstance(tgt, Obj) and tgt.zone == "field":
            self.collect_from(tgt, "damaged", src)
        if isinstance(src, Obj) and src.zone == "field":
            self.collect_from(src, "deals-damage", tgt)

    def change_spire(self, p, amt):
        if amt == 0:
            return
        self.spire[p] += amt
        self.touch()
        self.emit("SPIRE %s %+d %d" % (p, amt, self.spire[p]))
        if amt < 0:
            self.collect_spire_loss(p)

    def gain_ember(self, p, n):
        if n <= 0:
            return
        self.ember[p] += n
        self.touch()
        self.emit("EMBERGAIN %s %d %d" % (p, n, self.ember[p]))

    def raise_cap(self, p, n):
        if n <= 0:
            return
        self.cap[p] = min(self.cap[p] + n, self.maxcap)
        self.touch()
        self.emit("CAP %s %d %d" % (p, n, self.cap[p]))

    def add_counters(self, o, n):
        old = o.counters
        o.counters = max(0, old + n)
        if o.counters != old:
            self.touch()
            self.emit("COUNTERS #%d %+d %d" % (o.oid, o.counters - old, o.counters))

    def set_ready(self, o, ready):
        if o.ready == ready:
            return
        o.ready = ready
        self.touch()
        self.emit(("READY #%d" if ready else "EXHAUST #%d") % o.oid)

    def do_doom(self, o):
        o.doomed = True
        self.touch()
        self.emit("DOOM #%d" % o.oid)

    def add_ward(self, o, n):
        if n <= 0:
            return
        o.ward += n
        self.touch()
        self.emit("WARD #%d %d %d" % (o.oid, n, o.ward))

    def add_shield(self, p, n):
        if n <= 0:
            return
        self.shield[p] += n
        self.touch()
        self.emit("SHIELD %s %d %d" % (p, n, self.shield[p]))

    # -------------------------------------------------- leaving the Field --

    def remove_auras(self, o):
        self.records = [r for r in self.records
                        if not (r.duration == "aura" and r.source is o)]

    def detach_combat(self, o):
        """Take `o` out of combat, keeping the other objects consistent."""
        if o.blocking is not None:
            a = o.blocking
            if o in a.blockers:
                a.blockers.remove(o)
            o.blocking = None
        if o.attacking:
            for b in list(o.blockers):
                b.blocking = None
            o.blockers = []
            o.attacking = False
        o.blocked = False

    def leave_field(self, o, dest, event_line, died):
        c = self.ctrl(o)
        self.detach_combat(o)
        self.field.remove(o)
        self.zones[o.owner][dest].append(o)
        o.zone = dest
        o.left_ctrl = c
        self.touch()
        self.emit(event_line)
        self.remove_auras(o)
        o.clear_field_state()
        self.touch()
        self.fire_leave(o, c, died)

    def fire_leave(self, o, c, died):
        if not self.triggers_on:
            return
        for ab in o.card.abilities:
            if ab.kind == "on" and ab.event == "leave":
                self.add_pending(o, ab, c, o)
        if died:
            for ab in o.card.abilities:
                if ab.kind == "on" and ab.event == "dies":
                    self.add_pending(o, ab, c, o)
            if o.card.type == "unit":
                for x in self.field_sorted():
                    if self.abilities_inactive(x):
                        continue
                    xc = self.ctrl(x)
                    event = "ally-dies" if xc == c else "enemy-dies"
                    for ab in x.card.abilities:
                        if ab.kind == "on" and ab.event == event:
                            self.add_pending(x, ab, xc, o)

    def destroy(self, o):
        if self.has_kw(o, "tenacity") and not o.tenacity_used:
            o.tenacity_used = True
            o.wounds = 0
            o.doomed = False
            self.touch()
            self.emit("TENACITY #%d" % o.oid)
            return
        self.leave_field(o, "ash", "DESTROY #%d %s" % (o.oid, o.card.cid), True)

    def sacrifice(self, o):
        self.leave_field(o, "ash", "SACRIFICE #%d %s" % (o.oid, o.card.cid), True)

    def exile(self, o):
        zone = o.zone
        if zone == "field":
            self.leave_field(o, "rift",
                             "EXILE #%d %s field" % (o.oid, o.card.cid), False)
        else:
            self.remove_from_zone(o)
            self.zones[o.owner]["rift"].append(o)
            o.zone = "rift"
            self.touch()
            self.emit("EXILE #%d %s %s" % (o.oid, o.card.cid, zone))

    def bounce(self, o):
        self.leave_field(o, "hand", "BOUNCE #%d %s" % (o.oid, o.card.cid), False)

    # ------------------------------------------------------- card movement --

    def draw_one(self, p):
        v = self.zones[p]["vault"]
        if not v:
            self.emit("DRAW-EMPTY %s" % p)
            self.record_loss(p, "vault")
            return False
        o = v.pop(0)
        self.zones[p]["hand"].append(o)
        o.zone = "hand"
        self.touch()
        self.emit("DRAW %s #%d %s" % (p, o.oid, o.card.cid))
        if self.triggers_on:
            for x in self.field_sorted():
                if self.abilities_inactive(x):
                    continue
                if self.ctrl(x) != p:
                    continue
                for ab in x.card.abilities:
                    if ab.kind == "on" and ab.event == "you-draw":
                        self.add_pending(x, ab, p, o)
        return True

    def draw(self, n, p):
        for _ in range(n):
            if not self.draw_one(p):
                return

    def discard_one(self, p):
        h = self.zones[p]["hand"]
        if not h:
            return
        o = h.pop(0)
        self.zones[p]["ash"].append(o)
        o.zone = "ash"
        self.touch()
        self.emit("DISCARD %s #%d %s" % (p, o.oid, o.card.cid))

    def mill_one(self, p):
        v = self.zones[p]["vault"]
        if not v:
            return
        o = v.pop(0)
        self.zones[p]["ash"].append(o)
        o.zone = "ash"
        self.touch()
        self.emit("MILL %s #%d %s" % (p, o.oid, o.card.cid))

    def recall(self, o):
        if o.zone != "ash":
            return
        self.zones[o.owner]["ash"].remove(o)
        self.zones[o.owner]["hand"].append(o)
        o.zone = "hand"
        self.touch()
        self.emit("RECALL #%d %s" % (o.oid, o.card.cid))

    def dig(self, k, filters, p, ctx):
        v = self.zones[p]["vault"]
        take = max(0, min(k, len(v)))
        L = v[:take]
        del v[:take]
        self.touch()
        found = None
        for o in L:
            if self.filters_ok(o, filters, ctx):
                found = o
                break
        if found is not None:
            L.remove(found)
            self.zones[p]["hand"].append(found)
            found.zone = "hand"
            self.touch()
            self.emit("DIG %s #%d %s" % (p, found.oid, found.card.cid))
        else:
            self.emit("DIG-MISS %s" % p)
        for o in L:
            v.append(o)
            o.zone = "vault"
            self.touch()
            self.emit("BOTTOM %s #%d %s" % (p, o.oid, o.card.cid))

    # ------------------------------------------------- entering the Field --

    def create_auras(self, o):
        for ab in o.card.abilities:
            if ab.kind != "aura":
                continue
            static = ab.statics[0]
            cond = None
            inner = None
            if head(static) == "when":
                cond = static[1]
                inner = static[2]
                kind = static_kind(inner)
            else:
                kind = static_kind(static)
            r = Record(self.new_eid(), self.new_ts(), None, o, kind, "aura")
            r.static = static
            r.cond = cond
            r.inner = inner
            self.records.append(r)
        self.touch()

    def enter_field(self, o, ctrl):
        self.remove_from_zone(o)
        o.clear_field_state()
        o.base_ctrl = ctrl
        self.field.append(o)
        o.zone = "field"
        o.ts = self.new_ts()
        o.since = self.turn
        self.touch()
        self.create_auras(o)
        self.emit("ARRIVE #%d %s" % (o.oid, o.card.cid))
        if not self.triggers_on:
            return
        self.collect_from(o, "arrive", o)
        if o.card.type == "unit":
            c = self.ctrl(o)
            for x in self.field_sorted():
                if x is o or self.abilities_inactive(x):
                    continue
                xc = self.ctrl(x)
                event = "ally-arrive" if xc == c else "enemy-arrive"
                for ab in x.card.abilities:
                    if ab.kind == "on" and ab.event == event:
                        self.add_pending(x, ab, xc, o)

    def create_object(self, cid, p, to_field):
        o = self.new_object(cid, p)
        if to_field:
            self.field.append(o)
            o.zone = "field"
            self.touch()
            self.emit("CREATE #%d %s field" % (o.oid, cid))
            self.enter_field(o, p)
        else:
            self.zones[p]["hand"].append(o)
            o.zone = "hand"
            self.touch()
            self.emit("CREATE #%d %s hand" % (o.oid, cid))

    # ----------------------------------------------- continuous-effect recs --

    def add_discrete(self, kind, args, objs, ctx):
        r = Record(self.new_eid(), self.new_ts(), ctx.ctrl, ctx.source, kind, "turn")
        r.args = args
        r.affected = objs
        self.records.append(r)
        self.touch()
        if kind == "control":
            for o in objs:
                o.since = self.turn
                self.detach_combat(o)
            self.touch()
            for o in objs:
                self.emit("CONTROL #%d %s" % (o.oid, ctx.ctrl))
            return
        for o in objs:
            if kind == "modify":
                self.emit("BUFF #%d %d %d" % (o.oid, args[0], args[1]))
            elif kind == "setbody":
                self.emit("SETBODY #%d %d %d" % (o.oid, args[0], args[1]))
            elif kind == "swapstats":
                self.emit("SWAP #%d" % o.oid)
            elif kind == "grant":
                self.emit("GRANT #%d %s" % (o.oid, render_kw(args[0], args[1])))
            elif kind == "strip":
                self.emit("STRIP #%d" % o.oid)

    # ------------------------------------------------------------- effects --

    def exec_effects(self, effects, ctx):
        for e in effects:
            self.exec_effect(e, ctx)

    def exec_effect(self, node, ctx):
        h = head(node)
        if h == "damage":
            n = self.eval_amount(node[1], ctx)
            if n <= 0:
                return
            things = self.sel_damage(node[2], ctx)
            self.deal_damage([(ctx.source, t, n) for t in things])
        elif h == "destroy":
            for o in self.sel_field_objects(node[1], ctx):
                if o.zone == "field":
                    self.destroy(o)
        elif h == "sacrifice":
            for o in self.sel_field_objects(node[1], ctx):
                if o.zone == "field":
                    self.sacrifice(o)
        elif h == "exile":
            for o in self.sel_objects(node[1], ctx):
                self.exile(o)
        elif h == "bounce":
            for o in self.sel_field_objects(node[1], ctx):
                if o.zone == "field":
                    self.bounce(o)
        elif h == "draw":
            n = self.eval_amount(node[1], ctx)
            for p in self.sel_players(node[2], ctx):
                if n > 0:
                    self.draw(n, p)
        elif h == "discard":
            n = self.eval_amount(node[1], ctx)
            for p in self.sel_players(node[2], ctx):
                for _ in range(max(0, n)):
                    self.discard_one(p)
        elif h == "mill":
            n = self.eval_amount(node[1], ctx)
            for p in self.sel_players(node[2], ctx):
                for _ in range(max(0, n)):
                    self.mill_one(p)
        elif h == "spire":
            n = self.eval_amount(node[1], ctx)
            for p in self.sel_players(node[2], ctx):
                self.change_spire(p, n)
        elif h == "ember":
            n = self.eval_amount(node[1], ctx)
            for p in self.sel_players(node[2], ctx):
                self.gain_ember(p, n)
        elif h == "cap":
            n = self.eval_amount(node[1], ctx)
            for p in self.sel_players(node[2], ctx):
                self.raise_cap(p, n)
        elif h in ("modify", "setbody"):
            a = self.eval_amount(node[1], ctx)
            b = self.eval_amount(node[2], ctx)
            objs = self.sel_field_objects(node[3], ctx)
            self.add_discrete(h, (a, b), objs, ctx)
        elif h == "swapstats":
            objs = self.sel_field_objects(node[1], ctx)
            self.add_discrete("swapstats", None, objs, ctx)
        elif h == "grant":
            objs = self.sel_field_objects(node[2], ctx)
            self.add_discrete("grant", kwspec_pair(node[1]), objs, ctx)
        elif h == "strip":
            objs = self.sel_field_objects(node[1], ctx)
            self.add_discrete("strip", None, objs, ctx)
        elif h == "control":
            objs = self.sel_field_objects(node[1], ctx)
            self.add_discrete("control", None, objs, ctx)
        elif h == "counters":
            n = self.eval_amount(node[1], ctx)
            for o in self.sel_field_objects(node[2], ctx):
                if o.zone == "field":
                    self.add_counters(o, n)
        elif h == "ready":
            for o in self.sel_field_objects(node[1], ctx):
                if o.zone == "field":
                    self.set_ready(o, True)
        elif h == "exhaust":
            for o in self.sel_field_objects(node[1], ctx):
                if o.zone == "field":
                    self.set_ready(o, False)
        elif h == "doom":
            for o in self.sel_field_objects(node[1], ctx):
                if o.zone == "field" and o.card.type == "unit":
                    self.do_doom(o)
        elif h == "ward":
            n = self.eval_amount(node[1], ctx)
            for o in self.sel_field_objects(node[2], ctx):
                if o.zone == "field":
                    self.add_ward(o, n)
        elif h == "shield":
            n = self.eval_amount(node[1], ctx)
            for p in self.sel_players(node[2], ctx):
                self.add_shield(p, n)
        elif h in ("summon", "conjure"):
            cid = node[1].s
            n = self.eval_amount(node[2], ctx)
            for p in self.sel_players(node[3], ctx):
                for _ in range(max(0, n)):
                    self.create_object(cid, p, h == "summon")
        elif h == "reanimate":
            for o in self.sel_objects(node[1], ctx):
                if o.zone == "ash" and o.card.type == "unit":
                    self.enter_field(o, ctx.ctrl)
        elif h == "recall":
            for o in self.sel_objects(node[1], ctx):
                self.recall(o)
        elif h == "negate":
            self.eff_negate(node, ctx)
        elif h == "dig":
            k = node[1]
            filters = node[2]
            for p in self.sel_players(node[3], ctx):
                self.dig(k, filters, p, ctx)
        elif h == "delay":
            when = node[1].s
            d = Delayed(self.new_ts(), ctx.ctrl, when, ctx.source, node[2:],
                        [t.copy() for t in ctx.targets], ctx.tspecs)
            self.delayed.append(d)
            self.touch()
            self.emit("DELAY %s %s" % (ctx.ctrl, when))
        elif h == "if":
            if self.eval_cond(node[1], ctx):
                self.exec_effects(node[2], ctx)
            elif len(node) == 4:
                self.exec_effects(node[3], ctx)
        elif h == "each":
            objs = self.sel_objects(node[1], ctx)
            snapshot = [(o, o.zone) for o in objs]
            for o, zone in snapshot:
                if o.zone != zone:
                    continue
                ctx.that.append(o)
                try:
                    self.exec_effects(node[2:], ctx)
                finally:
                    ctx.that.pop()
        elif h == "repeat":
            n = self.eval_amount(node[1], ctx)
            for _ in range(max(0, n)):
                self.exec_effects(node[2:], ctx)
        elif h == "nothing":
            pass

    def eff_negate(self, node, ctx):
        n = node[1][1]
        if not (1 <= n <= len(ctx.targets)):
            return
        t = ctx.targets[n - 1]
        if t.removed or t.kind != "chain":
            return
        e = t.entry
        if e not in self.chain:
            return
        self.chain.remove(e)
        self.touch()
        self.emit("NEGATE ~%d" % e.cid)
        if e.kind in ("rite", "unit", "relic"):
            o = e.source
            o.zone = "ash"
            self.zones[o.owner]["ash"].append(o)
            self.touch()
            self.emit("SPENT #%d %s" % (o.oid, o.card.cid))

    # ------------------------------------------------------------- the Chain --

    def resolve_top(self):
        e = self.chain[-1]
        self.emit("RESOLVE ~%d" % e.cid)
        for t, ts in zip(e.targets, e.tspecs):
            if not self.target_legal(t, ts, e.ctrl, e.source, e):
                t.removed = True
        self.touch()
        fizzled = bool(e.targets) and all(t.removed for t in e.targets)
        if fizzled:
            self.emit("FIZZLE ~%d" % e.cid)
        else:
            self.execute_entry(e)
        if e in self.chain:
            self.chain.remove(e)
            self.touch()
        if e.kind == "rite":
            o = e.source
            if o.zone == "chain":
                o.zone = "ash"
                self.zones[o.owner]["ash"].append(o)
                self.touch()
            self.emit("SPENT #%d %s" % (o.oid, o.card.cid))
        elif e.kind in ("unit", "relic"):
            o = e.source
            if o.zone == "chain":
                o.zone = "ash"
                self.zones[o.owner]["ash"].append(o)
                self.touch()
                self.emit("SPENT #%d %s" % (o.oid, o.card.cid))

    def execute_entry(self, e):
        if e.kind == "rite":
            ab = e.source.card.abilities[0]
            self.exec_effects(ab.effects,
                              Ctx(e.ctrl, e.source, None, e.targets, e.tspecs))
            return
        if e.kind in ("unit", "relic"):
            self.enter_field(e.source, e.ctrl)
            return
        if e.effects is not None:
            self.exec_effects(e.effects,
                              Ctx(e.ctrl, e.source, None, e.targets, e.tspecs))
            return
        self.exec_effects(e.ability.effects,
                          Ctx(e.ctrl, e.source, e.subject, e.targets, e.tspecs))

    # --------------------------------------------------------------- costs --

    def card_cost(self, card, player):
        cost = card.cost
        for n, filters, who in self.derived().cheaper:
            if who != player:
                continue
            if self.cardfilters_ok(card, filters):
                cost -= n
        return max(0, cost)

    def cardfilters_ok(self, card, filters):
        for f in filters:
            h = head(f)
            if h == "type":
                if card.type != f[1].s:
                    return False
            elif h == "tag":
                if f[1].s not in card.tags:
                    return False
            elif h == "cost":
                if not CMP_FN[f[1].s](card.cost, f[2]):
                    return False
        return True

    def cost_payable(self, o, ability, player):
        for ci in ability.costitems:
            h = head(ci)
            if h == "ember":
                if self.ember[player] < ci[1]:
                    return False
            elif h == "spire":
                pass
            elif h == "discard":
                if len(self.zones[player]["hand"]) < ci[1]:
                    return False
            elif h == "exhaust":
                if o.zone != "field" or not o.ready:
                    return False
                if self.settling(o) and not self.has_kw(o, "vanguard"):
                    return False
            elif h == "sacself":
                if o.zone != "field":
                    return False
            elif h == "counters":
                if o.counters < ci[1]:
                    return False
            elif h == "once":
                if ability.index in o.once_used:
                    return False
        return True

    def pay_costs(self, o, ability, player):
        for ci in ability.costitems:
            h = head(ci)
            if h == "ember":
                n = ci[1]
                if n > 0:
                    self.ember[player] -= n
                    self.touch()
                    self.emit("PAY %s ember %d" % (player, n))
            elif h == "spire":
                n = ci[1]
                if n > 0:
                    self.emit("PAY %s spire %d" % (player, n))
                    self.change_spire(player, -n)
            elif h == "discard":
                for _ in range(ci[1]):
                    self.discard_one(player)
            elif h == "exhaust":
                self.set_ready(o, False)
            elif h == "sacself":
                if o.zone == "field":
                    self.sacrifice(o)
            elif h == "counters":
                self.add_counters(o, -ci[1])
            elif h == "once":
                o.once_used.add(ability.index)
                self.touch()

    # ------------------------------------------------------ play / activate --

    def play_timing_ok(self, card, player):
        if card.type == "rite" and card.has_printed_kw("swift"):
            return True
        return (player == self.active and self.cur_phase in ("main1", "main2")
                and not self.chain)

    def do_play(self, action):
        p = action.player
        hand = self.zones[p]["hand"]
        o = hand[action.pos - 1]
        card = o.card
        kind = card.type
        e = Entry(self.new_cid(), kind, p, o, 0)
        ab = card.abilities[0] if (kind == "rite") else None
        tspecs = ab.tspecs if ab is not None else []
        e.tspecs = tspecs
        e.targets = action.targets
        e.ability = ab
        hand.pop(action.pos - 1)
        o.zone = "chain"
        self.chain.append(e)
        self.touch()
        cost = self.card_cost(card, p)
        line = "PLAY %s ~%d #%d %s" % (p, e.cid, o.oid, card.cid)
        if e.targets:
            line += " " + " ".join(t.token() for t in e.targets)
        self.emit(line)
        if cost > 0:
            self.ember[p] -= cost
            self.touch()
            self.emit("PAY %s ember %d" % (p, cost))
        if kind == "rite" and self.triggers_on:
            for x in self.field_sorted():
                if self.abilities_inactive(x):
                    continue
                xc = self.ctrl(x)
                event = "you-play-rite" if xc == p else "enemy-plays-rite"
                for a2 in x.card.abilities:
                    if a2.kind == "on" and a2.event == event:
                        self.add_pending(x, a2, xc, o)

    def do_act(self, action):
        p = action.player
        o = self.objects[action.oid]
        ab = o.card.abilities[action.index - 1]
        e = Entry(self.new_cid(), "ability", p, o, ab.index)
        e.tspecs = ab.tspecs
        e.targets = action.targets
        e.ability = ab
        self.chain.append(e)
        self.touch()
        line = "ACTIVATE %s ~%d #%d %d" % (p, e.cid, o.oid, ab.index)
        if e.targets:
            line += " " + " ".join(t.token() for t in e.targets)
        self.emit(line)
        self.pay_costs(o, ab, p)

    # ------------------------------------------------------------- combat --

    def can_attack(self, o):
        if o.zone != "field" or o.card.type != "unit":
            return False
        if self.ctrl(o) != self.active:
            return False
        if not o.ready:
            return False
        if self.settling(o) and not self.has_kw(o, "vanguard"):
            return False
        if self.has_kw(o, "shackled"):
            return False
        return True

    def can_block(self, b, a):
        if b.zone != "field" or b.card.type != "unit":
            return False
        if self.ctrl(b) != OTHER[self.active]:
            return False
        if not b.ready:
            return False
        if self.has_kw(b, "siegework"):
            return False
        if a is None or a.zone != "field" or a.card.type != "unit" or not a.attacking:
            return False
        if self.has_kw(a, "ghostwalk"):
            if not (self.has_kw(b, "ghostwalk") or self.has_kw(b, "skyhook")):
                return False
        return True

    def attackers_on_field(self):
        return [o for o in self.field if o.attacking]

    def in_combat(self):
        return [o for o in self.field if o.attacking or o.blocking is not None]

    def provoke_satisfied(self, pairs):
        used = {b for b, _ in pairs}
        assigned = {}
        for b, a in pairs:
            assigned.setdefault(a, []).append(b)
        for a in self.attackers_on_field():
            if not self.has_kw(a, "provoke"):
                continue
            if assigned.get(a):
                continue
            for b in self.field:
                if b in used:
                    continue
                if self.can_block(b, a):
                    return False
        return True

    def combat_pairs(self, units):
        defender = OTHER[self.active]
        pairs = []
        for u in sorted(units, key=canon_key):
            if u.zone != "field":
                continue
            e = self.cur_edge(u)
            if e <= 0:
                continue
            if u.blocking is not None:
                a = u.blocking
                if a.zone == "field":
                    pairs.append((u, a, e))
                continue
            if not u.attacking:
                continue
            if not u.blocked:
                pairs.append((u, defender, e))
                continue
            L = [b for b in u.blockers if b.zone == "field" and b.blocking is u]
            L.sort(key=canon_key)
            if not L:
                continue
            venom = self.has_kw(u, "venom")
            assign = {}
            r = e
            for b in L:
                need = 1 if venom else max(0, self.cur_core(b) - b.wounds)
                x = min(r, need)
                assign[b] = x
                r -= x
            if r > 0:
                if self.has_kw(u, "pierce"):
                    pairs.append((u, defender, r))
                else:
                    assign[L[-1]] += r
            for b in L:
                if assign[b] > 0:
                    pairs.append((u, b, assign[b]))
        return pairs

    def deal_combat_damage(self, units):
        for u in units:
            u.dealt_combat = True
        self.touch()
        self.deal_damage(self.combat_pairs(units))

    def clear_combat(self):
        for o in self.field:
            o.attacking = False
            o.blocking = None
            o.blockers = []
            o.blocked = False
            o.dealt_combat = False
        self.touch()

    # --------------------------------------------------------------- phases --

    def phase(self, name):
        self.cur_phase = name
        self.touch()
        self.emit("PHASE %s" % name)

    def dawn_actions(self):
        p = self.active
        self.cap[p] = min(self.cap[p] + 1, self.maxcap)
        self.touch()
        for q in PLAYERS:
            self.ember[q] = self.cap[q]
            self.touch()
            self.emit("EMBER %s %d %d" % (q, self.ember[q], self.cap[q]))
        for o in self.field_sorted():
            if self.ctrl(o) == p and not o.ready:
                self.set_ready(o, True)
        for o in self.field:
            o.tenacity_used = False
            o.once_used = set()
        self.touch()
        self.collect_all("turn-start", self.active)
        self.collect_all("your-turn-start", self.active, only_active_ctrl=True)
        self.fire_delayed("your-next-turn-start", only_ctrl=self.active)

    def draw_actions(self):
        if self.turn == 1 and self.active == self.first:
            return
        self.draw(1, self.active)

    def dusk_trigger_actions(self):
        self.collect_all("turn-end", self.active)
        self.collect_all("your-turn-end", self.active, only_active_ctrl=True)
        self.fire_delayed("turn-end")

    def dusk_discard_actions(self):
        while len(self.zones[self.active]["hand"]) > self.handmax:
            self.discard_one(self.active)

    def cleanup_actions(self):
        for o in self.field:
            o.wounds = 0
            o.doomed = False
            o.ward = 0
        self.shield["A"] = 0
        self.shield["B"] = 0
        controlled = []
        keep = []
        for r in self.records:
            if r.duration == "turn":
                if r.kind == "control":
                    for o in r.affected:
                        if o not in controlled:
                            controlled.append(o)
            else:
                keep.append(r)
        self.records = keep
        for o in sorted(controlled, key=canon_key):
            o.since = self.turn
        # Only `your-next-turn-start` delays outlive the turn that made them.
        self.delayed = [d for d in self.delayed
                        if d.when == "your-next-turn-start"]
        self.touch()

    # ------------------------------------------------------- the main loop --

    def priority_round(self):
        self.passes = 0
        self.settle()
        self.holder = self.active
        while True:
            self.decision = (self.holder, "priority")
            yield
            a = self.action
            if a.kind == "PASS":
                self.emit("PASS %s" % a.player)
                self.passes += 1
                if self.passes == 1:
                    self.holder = OTHER[self.holder]
                else:
                    if self.chain:
                        self.passes = 0
                        self.resolve_top()
                        self.settle()
                        self.holder = self.active
                    else:
                        self.decision = None
                        return
            else:
                if a.kind == "PLAY":
                    self.do_play(a)
                else:
                    self.do_act(a)
                self.passes = 0
                self.holder = a.player
                if self.settle():
                    self.passes = 0
                    self.holder = self.active

    def clash(self):
        self.phase("clash-attack")
        self.settle()
        self.decision = (self.active, "attackers")
        yield
        objs = self.action.objs
        if not objs:
            self.decision = None
            return
        for o in sorted(objs, key=lambda x: x.oid):
            o.attacking = True
            self.touch()
            if not self.has_kw(o, "vigil"):
                self.set_ready(o, False)
            self.emit("ATTACK #%d" % o.oid)
        for o in sorted(objs, key=lambda x: x.oid):
            self.collect_from(o, "attacks", o)
        yield from self.priority_round()

        self.phase("clash-block")
        self.settle()
        self.decision = (OTHER[self.active], "blockers")
        yield
        pairs = self.action.pairs
        for b, a in sorted(pairs, key=lambda x: x[0].oid):
            b.blocking = a
            a.blockers.append(b)
            a.blockers.sort(key=canon_key)
            a.blocked = True
            self.touch()
            self.emit("BLOCK #%d #%d" % (b.oid, a.oid))
        unblocked = [a for a in sorted(self.attackers_on_field(), key=lambda x: x.oid)
                     if not a.blockers]
        for a in unblocked:
            self.emit("UNBLOCKED #%d" % a.oid)
        for b, a in sorted(pairs, key=lambda x: x[0].oid):
            if b.zone == "field":
                self.collect_from(b, "blocks", b.blocking)
        for a in sorted(self.attackers_on_field(), key=lambda x: x.oid):
            if a.blockers:
                self.collect_from(a, "blocked", a.blockers[0])
        for a in unblocked:
            if a.zone == "field":
                self.collect_from(a, "unblocked", a)
        yield from self.priority_round()

        rip = [u for u in self.in_combat() if self.has_kw(u, "riposte")]
        if rip:
            self.phase("clash-riposte")
            self.deal_combat_damage(rip)
            yield from self.priority_round()

        self.phase("clash-damage")
        rest = [u for u in self.in_combat() if not u.dealt_combat]
        self.deal_combat_damage(rest)
        yield from self.priority_round()

        self.phase("clash-end")
        for u in sorted(self.in_combat(), key=canon_key):
            self.collect_from(u, "end-of-combat", u)
        self.fire_delayed("end-of-combat")
        yield from self.priority_round()
        self.clear_combat()

    def _main(self):
        while True:
            self.emit("TURN %d %s" % (self.turn, self.active))
            self.phase("dawn")
            self.dawn_actions()
            self.drain()
            self.phase("draw")
            self.draw_actions()
            self.drain()
            self.phase("main1")
            yield from self.priority_round()
            yield from self.clash()
            self.phase("main2")
            yield from self.priority_round()
            self.phase("dusk-trigger")
            self.dusk_trigger_actions()
            yield from self.priority_round()
            self.phase("dusk-discard")
            self.dusk_discard_actions()
            self.drain()
            self.phase("dusk-cleanup")
            self.cleanup_actions()
            self.drain()
            self.turn += 1
            self.active = OTHER[self.active]
            self.touch()
            if self.turn > self.turnlimit:
                self.end_draw("turn-limit")

    # ---------------------------------------------------------------- setup --

    def do_setup(self):
        conf = self.conf
        for p in PLAYERS:
            for zone in ("deck", "hand", "field", "ash", "rift"):
                for cid in conf["zones"][p][zone]:
                    o = self.new_object(cid, p)
                    target = "vault" if zone == "deck" else zone
                    if target == "field":
                        o.zone = "pending-field"
                    else:
                        self.zones[p][target].append(o)
                        o.zone = target
        self.touch()
        self.emit("GAME-START %s" % self.first)
        pending = [o for o in self.objects.values() if o.zone == "pending-field"]
        pending.sort(key=lambda o: o.oid)
        self.triggers_on = False
        for o in pending:
            o.zone = "limbo"
            self.field.append(o)
            o.zone = "field"
            o.base_ctrl = o.owner
            o.ts = self.new_ts()
            o.since = 0
            self.touch()
            self.create_auras(o)
        if conf["shuffle"]:
            for p in PLAYERS:
                self.shuffle(self.zones[p]["vault"])
                self.emit("SHUFFLE %s" % p)
            self.touch()
        order = [self.first, OTHER[self.first]]
        for p in order:
            self.draw(conf["opening"], p)
        self.triggers_on = True
        self.settle()

    def shuffle(self, lst):
        k = len(lst)
        for i in range(k - 1, 0, -1):
            j = self.rng.below(i + 1)
            lst[i], lst[j] = lst[j], lst[i]

    def begin(self):
        try:
            self.do_setup()
            self.gen = self._main()
            next(self.gen)
        except GameOver:
            self.gen = None
            self.decision = None

    def resume(self):
        try:
            next(self.gen)
        except GameOver:
            self.gen = None
            self.decision = None
        except StopIteration:
            self.gen = None
            self.decision = None


def kwspec_pair(node):
    if isinstance(node, Sym):
        return (node.s, 0)
    return ("plating", node[1])
