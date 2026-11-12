"""State-changing procedures of SPEC section 17 (plus 15, prevention)."""

from __future__ import annotations

from .state import Obj, Player, render_target


class ChangesMixin:
    """Atomic game-state changes.  None of them runs a state check."""

    # -- losing ----------------------------------------------------------
    def record_loss(self, p: Player, reason: str) -> None:
        """Record *p*'s loss; the first reason recorded is kept."""
        if p.lost is None:
            p.lost = reason

    # -- cards moving between hidden zones -------------------------------
    def draw_card(self, p: Player) -> bool:
        """17.7: draw one card; return False on an empty Vault."""
        if not p.vault:
            self.emit("DRAW-EMPTY", p.name)
            self.record_loss(p, "vault")
            return False
        o = p.vault.popleft()
        o.zone = "hand"
        p.hand.append(o)
        self.emit("DRAW", p.name, "#%d" % o.oid, o.card.id)
        self.trig_draw(p, o)
        return True

    def discard_card(self, p: Player) -> bool:
        """17.8: discard hand position 1."""
        if not p.hand:
            return False
        o = p.hand.pop(0)
        o.zone = "ash"
        o.owner.ash.append(o)
        self.emit("DISCARD", p.name, "#%d" % o.oid, o.card.id)
        return True

    def mill_card(self, p: Player) -> bool:
        """17.9: mill the top of the Vault."""
        if not p.vault:
            return False
        o = p.vault.popleft()
        o.zone = "ash"
        o.owner.ash.append(o)
        self.emit("MILL", p.name, "#%d" % o.oid, o.card.id)
        return True

    # -- numbers -----------------------------------------------------------
    def change_spire(self, p: Player, delta: int) -> None:
        """17.10: change a player's Spire."""
        if delta == 0:
            return
        p.spire += delta
        self.emit("SPIRE", p.name, "%+d" % delta, p.spire)
        if delta < 0:
            self.trig_spire_loss(p)

    def gain_ember(self, p: Player, n: int) -> None:
        if n > 0:
            p.ember += n
            self.emit("EMBERGAIN", p.name, n, p.ember)

    def raise_cap(self, p: Player, n: int) -> None:
        if n > 0:
            p.cap = min(p.cap + n, self.cfg.maxcap)
            self.emit("CAP", p.name, n, p.cap)

    # -- damage ------------------------------------------------------------
    def deal_damage(self, src: Obj, tgt, n: int) -> None:
        """17.1 and 15.2: deal *n* damage from *src* to *tgt*."""
        if n <= 0:
            return
        if isinstance(tgt, Obj):
            if tgt.zone != "field" or tgt.card.type != "unit":
                return
            remaining = max(0, n - self.plating(tgt))
            prevented = n - remaining
            pool = min(tgt.ward, remaining)
            if pool:
                tgt.ward -= pool
                remaining -= pool
                prevented += pool
        else:
            remaining = n
            prevented = 0
            pool = min(tgt.shield, remaining)
            if pool:
                tgt.shield -= pool
                remaining -= pool
                prevented += pool
        if prevented:
            self.emit("PREVENT", render_target(tgt), prevented)
            self.touch()
        if remaining == 0:
            return
        m = remaining
        self.emit("DAMAGE", render_target(src), render_target(tgt), m)
        if isinstance(tgt, Obj):
            tgt.wounds += m
            self.touch()
        else:
            tgt.spire -= m
            self.emit("SPIRE", tgt.name, "-%d" % m, tgt.spire)
            self.trig_spire_loss(tgt)
        on_field_unit = src.zone == "field" and src.card.type == "unit"
        if (isinstance(tgt, Obj) and on_field_unit
                and self.has_kw(src, "venom")):
            tgt.doomed = True
            self.emit("DOOM", "#%d" % tgt.oid)
        if on_field_unit and self.has_kw(src, "siphon"):
            ctl = self.ctrl(src)
            ctl.spire += m
            self.emit("SPIRE", ctl.name, "+%d" % m, ctl.spire)
        self.trig_damage(src, tgt)

    # -- leaving the Field --------------------------------------------------
    def _leave_field_to(self, o: Obj, zone: str, event: str,
                        extra: tuple = ()) -> Player:
        """Common part of destroy / sacrifice / exile / bounce."""
        last = self.remove_from_field(o, zone)
        if zone == "ash":
            o.owner.ash.append(o)
        elif zone == "rift":
            o.owner.rift.append(o)
        elif zone == "hand":
            o.owner.hand.append(o)
        self.emit(event, "#%d" % o.oid, o.card.id, *extra)
        return last

    def destroy(self, o: Obj) -> None:
        """17.3 (with the tenacity replacement of 15.1)."""
        if o.zone != "field":
            return
        if not o.tenacity_used and self.has_kw(o, "tenacity"):
            o.tenacity_used = True
            o.wounds = 0
            o.doomed = False
            self.touch()
            self.emit("TENACITY", "#%d" % o.oid)
            return
        last = self._leave_field_to(o, "ash", "DESTROY")
        self.trig_leave(o, last, True)

    def sacrifice(self, o: Obj) -> None:
        """17.4."""
        if o.zone != "field":
            return
        last = self._leave_field_to(o, "ash", "SACRIFICE")
        self.trig_leave(o, last, True)

    def exile(self, o: Obj) -> None:
        """17.5: exile from any zone."""
        if o.zone == "field":
            last = self._leave_field_to(o, "rift", "EXILE", ("field",))
            self.trig_leave(o, last, False)
        elif o.zone in ("hand", "ash", "rift", "vault"):
            zone = self.remove_from_zone_list(o)
            o.zone = "rift"
            o.owner.rift.append(o)
            self.emit("EXILE", "#%d" % o.oid, o.card.id, zone)

    def bounce(self, o: Obj) -> None:
        """17.6."""
        if o.zone != "field":
            return
        last = self._leave_field_to(o, "hand", "BOUNCE")
        self.trig_leave(o, last, False)

    def recall(self, o: Obj) -> None:
        """17.19: Ash card back to its owner's hand."""
        if o.zone != "ash":
            return
        o.owner.ash.remove(o)
        o.zone = "hand"
        o.owner.hand.append(o)
        self.emit("RECALL", "#%d" % o.oid, o.card.id)

    # -- small state flags --------------------------------------------------
    def add_counters(self, o: Obj, delta: int) -> None:
        """17.14."""
        new = max(0, o.counters + delta)
        change = new - o.counters
        if change:
            o.counters = new
            self._dirty = True
            self._sver += 1
            self.emit("COUNTERS", "#%d" % o.oid, "%+d" % change, new)

    def set_ready(self, o: Obj, ready: bool) -> None:
        """17.15."""
        if o.zone != "field" or o.ready == ready:
            return
        o.ready = ready
        self.emit("READY" if ready else "EXHAUST", "#%d" % o.oid)

    def doom(self, o: Obj) -> None:
        """17.16."""
        if o.zone == "field" and o.card.type == "unit":
            o.doomed = True
            self.emit("DOOM", "#%d" % o.oid)

    # -- creating objects and entering the Field -------------------------------
    def create_object(self, card_id: str, owner: Player, where: str) -> None:
        """17.17: create one object in *owner*'s hand or on the Field."""
        card = self.db.cards[card_id]
        if where == "hand":
            o = self.new_object(card, owner, "hand")
            owner.hand.append(o)
            self.emit("CREATE", "#%d" % o.oid, card_id, "hand")
        else:
            o = self.new_object(card, owner, "limbo")
            self.emit("CREATE", "#%d" % o.oid, card_id, "field")
            self.enter_field(o, owner)

    def enter_field(self, o: Obj, controller: Player) -> None:
        """17.17 'Entering the Field'."""
        self.place_on_field(o, controller, self.turn)
        self.emit("ARRIVE", "#%d" % o.oid, o.card.id)
        self.trig_arrive(o)

    def reanimate(self, o: Obj, controller: Player) -> None:
        """17.18."""
        if o.zone != "ash" or o.card.type != "unit":
            return
        o.owner.ash.remove(o)
        self.enter_field(o, controller)

    def negate_entry(self, entry) -> None:
        """17.20."""
        if entry not in self.chain:
            return
        self.chain.remove(entry)
        self.emit("NEGATE", "~%d" % entry.cid)
        if entry.kind in ("rite", "unit", "relic"):
            o = entry.source
            o.zone = "ash"
            o.owner.ash.append(o)
            self.emit("SPENT", "#%d" % o.oid, o.card.id)
