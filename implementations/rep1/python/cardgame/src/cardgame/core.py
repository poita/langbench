"""Core game state: zones, objects, records, events and the Field."""

from __future__ import annotations

from collections import deque

from .config import Config
from .database import Database
from .layers import LayerMixin
from .model import EVENTS
from .prng import Rng
from .state import Obj, Player, Record


class GameCore(LayerMixin):
    """Holds all mutable match state and the primitive operations on it."""

    def __init__(self, config: Config, db: Database):
        self.cfg = config
        self.db = db
        self.players = (Player(0, config.spire, config.cap["A"]),
                        Player(1, config.spire, config.cap["B"]))
        self.players[0].opp = self.players[1]
        self.players[1].opp = self.players[0]
        self.rng = Rng(config.seed)
        self.objs: dict[int, Obj] = {}
        self.next_oid = 1
        self.next_ts = 1
        self.next_eid = 1
        self.next_cid = 1
        self.field: dict[int, Obj] = {}
        self.listen: dict[str, dict[int, Obj]] = {e: {} for e in EVENTS}
        self.records: list[Record] = []
        self.chain: list = []
        self.delayed: list = []
        self.pending: list = []
        self.first = self.players[0 if config.first == "A" else 1]
        self.turn = 1
        self.active = self.first
        self.phase = "dawn"
        self.decision: tuple | None = None
        self.over = False
        self.result: tuple | None = None
        self.out: list[str] = []
        self.seq = 0
        self.suppress_triggers = False
        # derivation cache
        self._dirty = True
        self._sver = 1       # bumped on every structural change
        self._dsver = 0      # structural version last derived
        self._aura_mode = False
        self._auras = 0
        self._ctrl: dict = {}
        self._stripped: set = set()
        self._edge: dict = {}
        self._core: dict = {}
        self._kw: dict = {}
        self._kwn: dict = {}
        self._plat: dict = {}
        self._cheaper: list = []

    # ------------------------------------------------------------------
    # Output
    # ------------------------------------------------------------------
    def emit(self, name: str, *fields) -> None:
        """Emit one numbered rules-event line."""
        self.seq += 1
        if fields:
            self.out.append("%d %s %s" % (self.seq, name,
                                          " ".join(map(str, fields))))
        else:
            self.out.append("%d %s" % (self.seq, name))
        if self._auras:
            self._dirty = True

    def line(self, text: str) -> None:
        """Append a non-event output line (inspection blocks, ERR)."""
        self.out.append(text)

    def touch(self) -> None:
        """Mark derived values stale if any aura could depend on the change."""
        if self._auras:
            self._dirty = True

    # ------------------------------------------------------------------
    # Counters
    # ------------------------------------------------------------------
    def new_ts(self) -> int:
        ts = self.next_ts
        self.next_ts += 1
        return ts

    def new_object(self, card, owner: Player, zone: str) -> Obj:
        o = Obj(self.next_oid, card, owner, zone)
        self.next_oid += 1
        self.objs[o.oid] = o
        return o

    def opponent(self, p: Player) -> Player:
        return p.opp

    # ------------------------------------------------------------------
    # Derived characteristics (cached)
    # ------------------------------------------------------------------
    def ctrl(self, o: Obj) -> Player:
        """Current controller (Field) or last controller (elsewhere)."""
        if o.zone != "field":
            return o.ctrl
        if self._dirty:
            self.derive()
        return self._ctrl[o.oid]

    def cur_edge(self, o: Obj) -> int:
        if o.zone != "field":
            return o.card.edge
        if self._dirty:
            self.derive()
        return self._edge[o.oid]

    def cur_core(self, o: Obj) -> int:
        if o.zone != "field":
            return o.card.core
        if self._dirty:
            self.derive()
        return self._core[o.oid]

    def kwnames(self, o: Obj) -> frozenset:
        if o.zone != "field":
            return o.card.kw_names
        if self._dirty:
            self.derive()
        return self._kwn[o.oid]

    def has_kw(self, o: Obj, name: str) -> bool:
        return name in self.kwnames(o)

    def cur_keywords(self, o: Obj) -> tuple:
        if o.zone != "field":
            return o.card.keywords
        if self._dirty:
            self.derive()
        return self._kw[o.oid]

    def plating(self, o: Obj) -> int:
        if o.zone != "field":
            return 0
        if self._dirty:
            self.derive()
        return self._plat[o.oid]

    def is_stripped(self, o: Obj) -> bool:
        if o.zone != "field":
            return False
        if self._dirty:
            self.derive()
        return o.oid in self._stripped

    def is_settling(self, o: Obj) -> bool:
        return o.zone == "field" and o.since >= self.turn

    def settle_blocked(self, o: Obj) -> bool:
        """True if *o* may not use Settling-restricted actions."""
        return self.is_settling(o) and not self.has_kw(o, "vanguard")

    def cheaper_total(self, player: Player, card) -> int:
        """Total ``cheaper`` reduction applying to *card* for *player*."""
        if self._dirty:
            self.derive()
        total = 0
        for ctrl, n, filters in self._cheaper:
            if ctrl is not player:
                continue
            ok = True
            for f in filters:
                op = f[0]
                if op == "type":
                    ok = card.type == f[1]
                elif op == "tag":
                    ok = f[1] in card.tagset
                else:
                    ok = compare(card.cost, f[1], f[2])
                if not ok:
                    break
            if ok:
                total += n
        return total

    # ------------------------------------------------------------------
    # Field membership
    # ------------------------------------------------------------------
    def place_on_field(self, o: Obj, controller: Player, since: int) -> None:
        """Put *o* on the Field: timestamp, state reset, aura records."""
        o.zone = "field"
        o.ctrl = controller
        o.ts = self.new_ts()
        o.reset_field_state(since)
        self.field[o.oid] = o
        for ev in o.card.on:
            self.listen[ev][o.oid] = o
        for ab in o.card.auras:
            rec = Record(self.next_eid, self.new_ts(), controller, o,
                         "aura", None, "aura", statics=ab.statics,
                         volatile=ab.volatile)
            self.next_eid += 1
            self.records.append(rec)
            if ab.volatile:
                self._auras += 1
        self._dirty = True
        self._sver += 1

    def remove_from_field(self, o: Obj, zone: str) -> Player:
        """Take *o* off the Field into *zone*'s bookkeeping.

        Returns the controller it had when it left.  The caller places the
        object in the destination zone list.
        """
        last = self.ctrl(o)
        self.remove_from_combat(o)
        del self.field[o.oid]
        for ev in o.card.on:
            self.listen[ev].pop(o.oid, None)
        if o.card.auras:
            kept = []
            for rec in self.records:
                if rec.duration == "aura" and rec.source is o:
                    if rec.volatile:
                        self._auras -= 1
                else:
                    kept.append(rec)
            self.records = kept
        o.zone = zone
        o.ctrl = last
        o.reset_field_state(0)
        self._dirty = True
        self._sver += 1
        return last

    def remove_from_combat(self, u: Obj) -> None:
        """Keep the other objects' combat status consistent (SPEC 7.5)."""
        att = u.blocking_of
        if att is not None:
            if u in att.blockers:
                att.blockers.remove(u)
            u.blocking = False
            u.blocking_of = None
        if u.attacking:
            for b in u.blockers:
                b.blocking = False
                b.blocking_of = None
            u.blockers = []
            u.attacking = False
        u.blocked = False
        u.blocking = False
        if self._auras:
            self._dirty = True

    def remove_from_zone_list(self, o: Obj) -> str:
        """Detach *o* from whatever zone list holds it; return the zone."""
        zone = o.zone
        if zone == "hand":
            o.owner.hand.remove(o)
        elif zone == "ash":
            o.owner.ash.remove(o)
        elif zone == "rift":
            o.owner.rift.remove(o)
        elif zone == "vault":
            o.owner.vault.remove(o)
        return zone

    def add_record(self, ctrl: Player, source: Obj, kind: str, args,
                   affected: list) -> Record:
        rec = Record(self.next_eid, self.new_ts(), ctrl, source, kind, args,
                     "turn", affected=affected)
        self.next_eid += 1
        self.records.append(rec)
        self._dirty = True
        self._sver += 1
        return rec


def compare(left: int, cmp: str, right: int) -> bool:
    """Evaluate a SPEC 6.1 comparator."""
    if cmp == "le":
        return left <= right
    if cmp == "lt":
        return left < right
    if cmp == "eq":
        return left == right
    if cmp == "ge":
        return left >= right
    if cmp == "gt":
        return left > right
    return left != right
