"""The resumable game engine: setup, turns, priority, chain, combat.

:class:`Game` is assembled from the mixins that implement the individual
rule areas.  Rules processing is a generator (:meth:`Game._main`) that runs
until it needs a player decision, ``yield``-ing there; :meth:`Game.submit`
validates an action against the waiting decision (SPEC 24) and resumes it.
"""

from __future__ import annotations

from collections import deque
from typing import Generator

from .changes import ChangesMixin
from .config import Config
from .core import GameCore
from .database import Database
from .errors import MatchEnded
from .interp import Ctx, InterpMixin
from .legal import LegalMixin
from .matchfile import Action
from .state import Entry, Obj, Player, render_target, target_key
from .targeting import TargetingMixin
from .triggers import TriggerMixin


class Game(GameCore, ChangesMixin, InterpMixin, TargetingMixin, TriggerMixin,
           LegalMixin):
    """A single Spiremark match."""

    def __init__(self, config: Config, db: Database):
        super().__init__(config, db)
        self.init_interp()
        self._gen: Generator | None = None

    # ==================================================================
    # Driving the engine
    # ==================================================================
    def start(self) -> None:
        """Run setup and rules processing up to the first decision point."""
        self._gen = self._main()
        self._resume(None)

    def _resume(self, value) -> None:
        try:
            self._gen.send(value)
        except StopIteration:
            self.decision = None

    def submit(self, action: Action) -> str | None:
        """Process a parsed action.  Returns an ERR kind, or None if accepted."""
        if self.over:
            return "game-over"
        player = self.players[0 if action.player == "A" else 1]
        if self.decision[0] is not player:
            return "not-your-turn"
        kind = self.decision[1]
        want = {"PASS": "priority", "PLAY": "priority", "ACT": "priority",
                "ATTACK": "attackers", "BLOCK": "blockers"}
        if action.kind != "CONCEDE" and want[action.kind] != kind:
            return "wrong-decision"
        handler = getattr(self, "_check_" + action.kind.lower())
        result = handler(player, action)
        if isinstance(result, str):
            return result
        if action.kind == "CONCEDE":
            self.record_loss(player, "concede")
            self.finish_match()
            self._gen.close()
            self.decision = None
            return None
        self._resume((action.kind, player, result))
        return None

    # ==================================================================
    # Match end
    # ==================================================================
    def finish_match(self, draw_reason: str | None = None) -> None:
        """Emit LOSE / RESULT lines and mark the match over."""
        self.over = True
        self.decision = None
        if draw_reason is not None:
            self.result = ("draw", draw_reason)
        else:
            losers = [p for p in self.players if p.lost is not None]
            for p in losers:
                self.emit("LOSE", p.name, p.lost)
            if len(losers) == 2:
                self.result = ("draw", losers[0].lost)
            else:
                self.result = (losers[0].opp.name, losers[0].lost)
        self.emit("RESULT", *self.result)

    def finish_pending(self) -> None:
        """Called when the script ends while the match is still running."""
        if not self.over:
            self.emit("RESULT", "pending", "none")

    # ==================================================================
    # Setup (SPEC 8)
    # ==================================================================
    def _setup(self) -> None:
        cfg = self.cfg
        to_field: list[Obj] = []
        for p in self.players:
            for zone in ("DECK", "HAND", "FIELD", "ASH", "RIFT"):
                for cid, count in cfg.zones[zone][p.name]:
                    card = self.db.cards[cid]
                    for _ in range(count):
                        if zone == "DECK":
                            o = self.new_object(card, p, "vault")
                            p.vault.append(o)
                        elif zone == "HAND":
                            o = self.new_object(card, p, "hand")
                            p.hand.append(o)
                        elif zone == "FIELD":
                            o = self.new_object(card, p, "limbo")
                            to_field.append(o)
                        elif zone == "ASH":
                            o = self.new_object(card, p, "ash")
                            p.ash.append(o)
                        else:
                            o = self.new_object(card, p, "rift")
                            p.rift.append(o)
        for o in to_field:
            self.place_on_field(o, o.owner, 0)
        self.emit("GAME-START", self.first.name)
        if cfg.shuffle:
            for p in self.players:
                items = list(p.vault)
                self.rng.shuffle(items)
                p.vault = deque(items)
                self.emit("SHUFFLE", p.name)
        self.suppress_triggers = True
        for p in (self.first, self.first.opp):
            for _ in range(cfg.opening):
                if not self.draw_card(p):
                    break
        self.suppress_triggers = False
        self.pending.clear()
        self.settle()

    # ==================================================================
    # Turn structure (SPEC 9)
    # ==================================================================
    def _main(self):
        try:
            self._setup()
            while True:
                yield from self._turn()
                self.turn += 1
                self.active = self.active.opp
                if self.turn > self.cfg.turnlimit:
                    self.finish_match("turn-limit")
                    return
        except MatchEnded:
            return

    def enter_phase(self, name: str) -> None:
        self.phase = name
        self.touch()
        self.emit("PHASE", name)

    def _turn(self):
        a = self.active
        self.emit("TURN", self.turn, a.name)
        # dawn
        self.enter_phase("dawn")
        a.cap = min(a.cap + 1, self.cfg.maxcap)
        for p in self.players:
            p.ember = p.cap
            self.emit("EMBER", p.name, p.ember, p.cap)
        for o in list(self.field.values()):
            if not o.ready and self.ctrl(o) is a:
                self.set_ready(o, True)
        for o in self.field.values():
            o.tenacity_used = False
            o.once.clear()
        self.trig_turn("turn-start", "your-turn-start")
        self.collect_delayed("your-next-turn-start", a)
        self.drain()
        # draw
        self.enter_phase("draw")
        if self.turn != 1:
            self.draw_card(a)
        self.drain()
        # main 1
        self.enter_phase("main1")
        yield from self._priority_round()
        # clash
        yield from self._clash()
        # main 2
        self.enter_phase("main2")
        yield from self._priority_round()
        # dusk
        self.enter_phase("dusk-trigger")
        self.trig_turn("turn-end", "your-turn-end")
        self.collect_delayed("turn-end")
        yield from self._priority_round()
        self.enter_phase("dusk-discard")
        while len(a.hand) > self.cfg.handmax:
            self.discard_card(a)
        self.drain()
        self.enter_phase("dusk-cleanup")
        for o in self.field.values():
            o.wounds = 0
            o.doomed = False
            o.ward = 0
        for p in self.players:
            p.shield = 0
        for rec in self.records:
            if rec.duration == "turn" and rec.kind == "control":
                for o in rec.affected:
                    if o.zone == "field":
                        o.since = self.turn
        self.records = [r for r in self.records if r.duration == "aura"]
        self.delayed = [d for d in self.delayed
                        if d.when == "your-next-turn-start"]
        self._dirty = True
        self._sver += 1
        self.drain()

    # ==================================================================
    # Priority, settling and the Chain (SPEC 10, 11)
    # ==================================================================
    def settle(self) -> bool:
        """10.5: run state checks and push triggers until quiescent."""
        acted = False
        while True:
            a = self._state_checks()
            b = self.push_triggers()
            if a or b:
                acted = True
            else:
                return acted

    def drain(self) -> None:
        """10.6: empty the Chain with no player input."""
        while True:
            self.settle()
            if not self.chain:
                return
            self.resolve_top()

    def _state_checks(self) -> bool:
        """SPEC 18.  Returns True when a check acted."""
        for p in self.players:
            if p.spire <= 0:
                self.record_loss(p, "spire")
        if any(p.lost is not None for p in self.players):
            self.finish_match()
            raise MatchEnded()
        doomed = [o for o in self.field.values()
                  if o.card.type == "unit"
                  and (o.doomed or self.cur_core(o) <= o.wounds)]
        if not doomed:
            return False
        for o in doomed:
            self.destroy(o)
        return True

    def _wait(self, player: Player, kind: str):
        """Settle, then stop at a decision point until an action arrives."""
        if kind != "priority":
            self.settle()
        self.touch()
        self.decision = (player, kind)
        action = yield
        self.decision = None
        return action

    def _priority_round(self):
        """10.4: a priority round."""
        count = 0
        self.settle()
        holder = self.active
        while True:
            kind, actor, payload = yield from self._wait(holder, "priority")
            if kind == "PASS":
                self.emit("PASS", actor.name)
                count += 1
                if count == 1:
                    holder = actor.opp
                elif self.chain:
                    count = 0
                    self.resolve_top()
                    self.settle()
                    holder = self.active
                else:
                    return
            else:
                if kind == "PLAY":
                    self._perform_play(actor, payload)
                else:
                    self._perform_act(actor, payload)
                count = 0
                holder = actor
                if self.settle():
                    count = 0
                    holder = self.active

    # -- playing and activating --------------------------------------------------
    def _resolve_targets(self, tokens: tuple) -> list:
        out = []
        for kind, v in tokens:
            if kind == "P":
                out.append(self.players[0 if v == "A" else 1])
            elif kind == "O":
                out.append(self.objs.get(v))
            else:
                out.append(next((e for e in self.chain if e.cid == v), None))
        return out

    def _check_targets(self, specs: list, tokens: tuple, p: Player,
                       source: Obj) -> list | str:
        """Checks 7 and 8 of SPEC 24; returns resolved targets or an ERR kind."""
        if len(tokens) != len(specs):
            return "bad-target-count"
        targets = self._resolve_targets(tokens)
        for i, t in enumerate(targets):
            if t is None or any(t is u for u in targets[:i]):
                return "illegal-target"
            if not self.target_legal(specs[i], t, p, source, None):
                return "illegal-target"
        return targets

    def _check_pass(self, p: Player, a: Action):
        return ()

    def _check_concede(self, p: Player, a: Action):
        return ()

    def _check_play(self, p: Player, a: Action):
        if a.pos < 1 or a.pos > len(p.hand):
            return "no-such-card"
        obj = p.hand[a.pos - 1]
        card = obj.card
        if not self.play_timing_ok(p, card):
            return "bad-timing"
        specs = self.card_target_specs(card)
        targets = self._check_targets(specs, a.targets, p, obj)
        if isinstance(targets, str):
            return targets
        cost = self.play_cost(p, card)
        if p.ember < cost:
            return "cannot-afford"
        return (obj, targets, specs, cost)

    def _check_act(self, p: Player, a: Action):
        obj = self.objs.get(a.oid)
        if obj is None or obj.zone != "field" or self.ctrl(obj) is not p:
            return "no-such-object"
        ab = obj.card.acts.get(a.index)
        if ab is None or self.is_stripped(obj):
            return "no-such-ability"
        specs = ab.targets or []
        targets = self._check_targets(specs, a.targets, p, obj)
        if isinstance(targets, str):
            return targets
        if not self.costs_payable(p, obj, ab):
            return "cost-unpayable"
        return (obj, ab, targets, specs)

    def _perform_play(self, p: Player, prep) -> None:
        """11.2 steps 2 and 5-7."""
        obj, targets, specs, cost = prep
        p.hand.remove(obj)
        obj.zone = "chain"
        entry = Entry(self.next_cid, obj.card.type, p, obj, 0, targets, specs)
        self.next_cid += 1
        self.chain.append(entry)
        fields = [p.name, "~%d" % entry.cid, "#%d" % obj.oid, obj.card.id]
        fields.extend(render_target(t) for t in targets)
        self.emit("PLAY", *fields)
        if cost > 0:
            p.ember -= cost
            self.emit("PAY", p.name, "ember", cost)
        if obj.card.type == "rite":
            self.trig_play_rite(p, obj)

    def _perform_act(self, p: Player, prep) -> None:
        """11.3 steps 2 and 5-6."""
        obj, ab, targets, specs = prep
        entry = Entry(self.next_cid, "ability", p, obj, ab.number, targets,
                      specs)
        self.next_cid += 1
        self.chain.append(entry)
        fields = [p.name, "~%d" % entry.cid, "#%d" % obj.oid, ab.number]
        fields.extend(render_target(t) for t in targets)
        self.emit("ACTIVATE", *fields)
        for item in ab.cost:
            op = item[0]
            if op == "ember":
                if item[1] > 0:
                    p.ember -= item[1]
                    self.emit("PAY", p.name, "ember", item[1])
            elif op == "spire":
                if item[1] > 0:
                    self.emit("PAY", p.name, "spire", item[1])
                    self.change_spire(p, -item[1])
            elif op == "discard":
                for _ in range(item[1]):
                    self.discard_card(p)
            elif op == "exhaust":
                self.set_ready(obj, False)
            elif op == "sacself":
                self.sacrifice(obj)
            elif op == "counters":
                self.add_counters(obj, -item[1])
            else:
                obj.once.add(ab.number)

    # -- resolving ---------------------------------------------------------------
    def resolve_top(self) -> None:
        """11.6: resolve the entry on top of the Chain."""
        entry = self.chain[-1]
        self.emit("RESOLVE", "~%d" % entry.cid)
        src = entry.source
        tspecs = entry.tspecs
        for i, t in enumerate(entry.targets):
            entry.removed[i] = not self.target_legal(
                tspecs[i], t, entry.ctrl, src, entry)
        if entry.targets and all(entry.removed):
            self.emit("FIZZLE", "~%d" % entry.cid)
        else:
            kind = entry.kind
            if kind in ("unit", "relic"):
                self.chain.pop()
                self.enter_field(src, entry.ctrl)
                return
            if kind == "rite":
                effects = src.card.resolve.effects
            elif entry.effects is not None:
                effects = entry.effects
            else:
                effects = src.card.abilities[entry.index - 1].effects
            self.run_effects(effects, Ctx(entry.ctrl, src, entry,
                                          entry.subject))
        if self.chain and self.chain[-1] is entry:
            self.chain.pop()
        elif entry in self.chain:
            self.chain.remove(entry)
        if entry.kind in ("unit", "relic"):
            src.zone = "ash"
            src.owner.ash.append(src)
        elif entry.kind == "rite":
            src.zone = "ash"
            src.owner.ash.append(src)
            self.emit("SPENT", "#%d" % src.oid, src.card.id)

    # ==================================================================
    # Combat (SPEC 19)
    # ==================================================================
    def _check_attack(self, p: Player, a: Action):
        seen = set()
        for oid in a.objs:
            if oid in seen:
                return "duplicate-attacker"
            seen.add(oid)
        objs = []
        for oid in a.objs:
            o = self.objs.get(oid)
            if o is None or not self.can_attack(o):
                return "illegal-attacker"
            objs.append(o)
        for o in self.field.values():
            if (o.oid not in seen and self.can_attack(o)
                    and self.has_kw(o, "relentless")):
                return "missing-required-attacker"
        return objs

    def _check_block(self, p: Player, a: Action):
        seen = set()
        for b, _ in a.pairs:
            if b in seen:
                return "duplicate-blocker"
            seen.add(b)
        pairs = []
        for b, att in a.pairs:
            bo, ao = self.objs.get(b), self.objs.get(att)
            if bo is None or ao is None or not self.can_block(bo, ao):
                return "illegal-blocker"
            pairs.append((bo, ao))
        covered = {id(ao) for _, ao in pairs}
        free = [o for o in self.field.values() if o.oid not in seen]
        for att in self.attacking_units():
            if (self.has_kw(att, "provoke") and not att.blockers
                    and id(att) not in covered
                    and any(self.can_block(b, att) for b in free)):
                return "missing-required-block"
        return pairs

    def _clash(self):
        self.enter_phase("clash-attack")
        kind, actor, attackers = yield from self._wait(self.active,
                                                       "attackers")
        if not attackers:
            return
        attackers.sort(key=lambda o: o.oid)
        for u in attackers:
            u.attacking = True
            if not self.has_kw(u, "vigil"):
                self.set_ready(u, False)
            self.emit("ATTACK", "#%d" % u.oid)
        for u in attackers:
            self.collect_self("attacks", u, u)
        yield from self._priority_round()

        self.enter_phase("clash-block")
        defender = self.active.opp
        kind, actor, pairs = yield from self._wait(defender, "blockers")
        pairs.sort(key=lambda p: p[0].oid)
        for b, a in pairs:
            b.blocking = True
            b.blocking_of = a
            a.blockers.append(b)
            a.blocked = True
            self.emit("BLOCK", "#%d" % b.oid, "#%d" % a.oid)
        for _, a in pairs:
            a.blockers.sort(key=lambda o: (o.ts, o.oid))
        attacking = sorted(self.attacking_units(), key=lambda o: o.oid)
        unblocked = [u for u in attacking if not u.blockers]
        for u in unblocked:
            self.emit("UNBLOCKED", "#%d" % u.oid)
        for b, a in pairs:
            self.collect_self("blocks", b, a)
        for u in attacking:
            if u.blockers:
                self.collect_self("blocked", u, u.blockers[0])
        for u in unblocked:
            self.collect_self("unblocked", u, u)
        yield from self._priority_round()

        ripostes = [u for u in self.in_combat() if self.has_kw(u, "riposte")]
        if ripostes:
            self.enter_phase("clash-riposte")
            self._combat_damage(ripostes)
            yield from self._priority_round()
        self.enter_phase("clash-damage")
        done = {id(u) for u in ripostes}
        self._combat_damage([u for u in self.in_combat()
                             if id(u) not in done])
        yield from self._priority_round()

        self.enter_phase("clash-end")
        for u in self.in_combat():
            self.collect_self("end-of-combat", u, u)
        self.collect_delayed("end-of-combat")
        yield from self._priority_round()
        for o in self.field.values():
            o.attacking = False
            o.blocking = False
            o.blocked = False
            o.blockers = []
            o.blocking_of = None
        self.touch()

    def _combat_damage(self, units: list[Obj]) -> None:
        """19.6 and 17.2: assign all combat damage, then apply it."""
        defender = self.active.opp
        pairs = []
        for u in units:
            e = self.cur_edge(u)
            if e <= 0:
                continue
            if u.blocking and u.blocking_of is not None:
                pairs.append((u, u.blocking_of, e))
            elif u.attacking:
                if not u.blocked:
                    pairs.append((u, defender, e))
                    continue
                live = [b for b in u.blockers
                        if b.zone == "field" and b.blocking
                        and b.blocking_of is u]
                if not live:
                    continue
                venom = self.has_kw(u, "venom")
                r = e
                amounts = []
                for b in live:
                    need = 1 if venom else max(0, self.cur_core(b) - b.wounds)
                    give = min(r, need)
                    amounts.append(give)
                    r -= give
                if r > 0:
                    if self.has_kw(u, "pierce"):
                        pairs.append((u, defender, r))
                    else:
                        amounts[-1] += r
                for b, give in zip(live, amounts):
                    if give > 0:
                        pairs.append((u, b, give))
        pairs.sort(key=lambda t: (t[0].key, target_key(t[1])))
        for src, tgt, n in pairs:
            self.deal_damage(src, tgt, n)
