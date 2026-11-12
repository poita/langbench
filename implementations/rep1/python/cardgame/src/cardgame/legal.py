"""Legal-action enumeration (SPEC 21) and the action checks it shares with
script validation (SPEC 11.1, 11.3, 19.2, 19.4)."""

from __future__ import annotations

from .state import Obj, Player, render_target


class LegalMixin:
    """Predicates for what a player may do, and the ``LEGAL`` block."""

    # -- playing cards ---------------------------------------------------------
    def play_timing_ok(self, p: Player, card) -> bool:
        """11.1 for a card in hand (the holder check is the caller's)."""
        if card.type == "rite" and card.is_swift:
            return True
        return (p is self.active and self.phase in ("main1", "main2")
                and not self.chain)

    def play_cost(self, p: Player, card) -> int:
        return max(0, card.cost - self.cheaper_total(p, card))

    def card_target_specs(self, card) -> list:
        ab = card.resolve
        return (ab.targets or []) if ab is not None else []

    # -- activated abilities -----------------------------------------------------
    def costs_payable(self, p: Player, o: Obj, ab) -> bool:
        """11.3 step 4."""
        for item in ab.cost:
            op = item[0]
            if op == "ember":
                if p.ember < item[1]:
                    return False
            elif op == "discard":
                if len(p.hand) < item[1]:
                    return False
            elif op == "exhaust":
                if o.zone != "field" or not o.ready or self.settle_blocked(o):
                    return False
            elif op == "sacself":
                if o.zone != "field":
                    return False
            elif op == "counters":
                if o.counters < item[1]:
                    return False
            elif op == "once":
                if ab.number in o.once:
                    return False
        return True

    # -- combat ------------------------------------------------------------------
    def can_attack(self, u: Obj) -> bool:
        """19.2."""
        return (u.zone == "field" and u.card.type == "unit"
                and self.ctrl(u) is self.active and u.ready
                and not self.settle_blocked(u)
                and not self.has_kw(u, "shackled"))

    def can_block(self, b: Obj, a: Obj) -> bool:
        """19.4."""
        if (b.zone != "field" or b.card.type != "unit"
                or self.ctrl(b) is not self.active.opp or not b.ready
                or self.has_kw(b, "siegework")):
            return False
        if a.zone != "field" or not a.attacking:
            return False
        if self.has_kw(a, "ghostwalk"):
            return self.has_kw(b, "ghostwalk") or self.has_kw(b, "skyhook")
        return True

    def attacking_units(self) -> list[Obj]:
        return [o for o in self.field.values() if o.attacking]

    def in_combat(self) -> list[Obj]:
        return [o for o in self.field.values() if o.attacking or o.blocking]

    # -- the LEGAL block -----------------------------------------------------------
    def legal_lines(self) -> list[str]:
        """Action lines for the current decision point."""
        player, kind = self.decision
        lines: list[str] = []
        if kind == "priority":
            lines.append("PASS")
            lines.extend(self._legal_plays(player))
            lines.extend(self._legal_acts(player))
        elif kind == "attackers":
            can = [o for o in self.field.values() if self.can_attack(o)]
            can.sort(key=lambda o: o.oid)
            lines.extend("CANATTACK #%d" % o.oid for o in can)
            lines.extend("MUSTATTACK #%d" % o.oid for o in can
                         if self.has_kw(o, "relentless"))
        else:
            blockers = sorted(self.field.values(), key=lambda o: o.oid)
            attackers = sorted(self.attacking_units(), key=lambda o: o.oid)
            for b in blockers:
                for a in attackers:
                    if self.can_block(b, a):
                        lines.append("CANBLOCK #%d #%d" % (b.oid, a.oid))
            lines.extend("MUSTBLOCK #%d" % a.oid for a in attackers
                         if self.has_kw(a, "provoke"))
        return lines

    def _legal_plays(self, p: Player) -> list[str]:
        lines = []
        for pos, o in enumerate(p.hand, 1):
            card = o.card
            if not self.play_timing_ok(p, card):
                continue
            if self.play_cost(p, card) > p.ember:
                continue
            specs = self.card_target_specs(card)
            for tup in self.target_tuples(specs, p, o, None):
                parts = ["PLAY", str(pos), card.id]
                parts.extend(render_target(t) for t in tup)
                lines.append(" ".join(parts))
        return lines

    def _legal_acts(self, p: Player) -> list[str]:
        lines = []
        mine = [o for o in self.field.values() if self.ctrl(o) is p]
        mine.sort(key=lambda o: o.oid)
        for o in mine:
            if not o.card.acts or self.is_stripped(o):
                continue
            for number in sorted(o.card.acts):
                ab = o.card.acts[number]
                if not self.costs_payable(p, o, ab):
                    continue
                for tup in self.target_tuples(ab.targets or [], p, o, None):
                    parts = ["ACT", "#%d" % o.oid, str(number)]
                    parts.extend(render_target(t) for t in tup)
                    lines.append(" ".join(parts))
        return lines
