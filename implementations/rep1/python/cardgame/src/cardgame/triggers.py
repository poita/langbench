"""Triggered abilities: collection, ordering and pushing (SPEC 13)."""

from __future__ import annotations

from .state import Delayed, Entry, Obj, Pending, Player, render_target


class TriggerMixin:
    """Event collection into the pending list and the batch push."""

    # -- generic helpers ------------------------------------------------------
    def _queue(self, ev: str, x: Obj, subject, ctrl: Player) -> None:
        for ab in x.card.on[ev]:
            self.pending.append(Pending(ctrl, x, ab, subject, x.ts))

    def _listeners(self, ev: str):
        """Field objects listening for *ev* whose abilities are not stripped."""
        group = self.listen[ev]
        if not group:
            return ()
        if self._dirty:
            self.derive()
        stripped = self._stripped
        return [x for x in group.values() if x.oid not in stripped]

    def collect_self(self, ev: str, x: Obj, subject) -> None:
        """Collect *ev* from *x* itself, if it listens (on the Field)."""
        if self.suppress_triggers or x.zone != "field" or ev not in x.card.on:
            return
        if self.is_stripped(x):
            return
        self._queue(ev, x, subject, self.ctrl(x))

    # -- specific events ----------------------------------------------------------
    def trig_arrive(self, o: Obj) -> None:
        if self.suppress_triggers:
            return
        self.collect_self("arrive", o, o)
        if o.card.type != "unit":
            return
        mine = self.ctrl(o)
        for x in self._listeners("ally-arrive"):
            if x is not o and self.ctrl(x) is mine:
                self._queue("ally-arrive", x, o, mine)
        for x in self._listeners("enemy-arrive"):
            if self.ctrl(x) is not mine:
                self._queue("enemy-arrive", x, o, self.ctrl(x))

    def trig_leave(self, o: Obj, last: Player, died: bool) -> None:
        """Collect leave/dies from *o* (already gone) and, for a death, the
        ally-dies / enemy-dies triggers of the other objects."""
        if self.suppress_triggers:
            return
        if "leave" in o.card.on:
            self._queue("leave", o, o, last)
        if not died:
            return
        if "dies" in o.card.on:
            self._queue("dies", o, o, last)
        if o.card.type != "unit":
            return
        for x in self._listeners("ally-dies"):
            if self.ctrl(x) is last:
                self._queue("ally-dies", x, o, last)
        for x in self._listeners("enemy-dies"):
            c = self.ctrl(x)
            if c is not last:
                self._queue("enemy-dies", x, o, c)

    def trig_draw(self, p: Player, card: Obj) -> None:
        if self.suppress_triggers:
            return
        for x in self._listeners("you-draw"):
            if self.ctrl(x) is p:
                self._queue("you-draw", x, card, p)

    def trig_spire_loss(self, p: Player) -> None:
        if self.suppress_triggers:
            return
        for x in self._listeners("spire-loss"):
            if self.ctrl(x) is p:
                self._queue("spire-loss", x, p, p)
        for x in self._listeners("enemy-spire-loss"):
            c = self.ctrl(x)
            if c is p.opp:
                self._queue("enemy-spire-loss", x, p, c)

    def trig_play_rite(self, p: Player, card: Obj) -> None:
        for x in self._listeners("you-play-rite"):
            if self.ctrl(x) is p:
                self._queue("you-play-rite", x, card, p)
        for x in self._listeners("enemy-plays-rite"):
            c = self.ctrl(x)
            if c is p.opp:
                self._queue("enemy-plays-rite", x, card, c)

    def trig_damage(self, src, tgt) -> None:
        if self.suppress_triggers:
            return
        if isinstance(tgt, Obj) and tgt.zone == "field":
            self.collect_self("damaged", tgt, src)
        if isinstance(src, Obj) and src.zone == "field":
            self.collect_self("deals-damage", src, tgt)

    def trig_turn(self, ev: str, your_ev: str) -> None:
        """turn-start / turn-end style events for the active player."""
        for x in self._listeners(ev):
            self._queue(ev, x, self.active, self.ctrl(x))
        for x in self._listeners(your_ev):
            c = self.ctrl(x)
            if c is self.active:
                self._queue(your_ev, x, self.active, c)

    def collect_delayed(self, when: str, controller: Player | None = None) -> None:
        """Collect delayed triggers registered for *when*."""
        keep = []
        for d in self.delayed:
            if d.when == when and (controller is None or d.ctrl is controller):
                self.pending.append(Pending(d.ctrl, d.source, None, None,
                                            d.ts, d))
            else:
                keep.append(d)
        self.delayed = keep

    # -- pushing -----------------------------------------------------------------
    def push_triggers(self) -> bool:
        """13.3: order the pending batch and put it on the Chain."""
        if not self.pending:
            return False
        batch = self.pending
        self.pending = []
        active = self.active

        def key(p: Pending):
            idx = p.ability.number if p.delayed is None else 0
            return (0 if p.ctrl is active else 1, p.ts, p.source.oid, idx)

        batch.sort(key=key)
        entries: list[Entry] = []
        for p in batch:
            d = p.delayed
            if d is not None:
                targets = list(d.targets)
                entry = Entry(self.next_cid, "trigger", p.ctrl, p.source, 0,
                              targets, d.tspecs, effects=d.effects)
            else:
                ab = p.ability
                specs = ab.targets or []
                targets = []
                if specs:
                    targets = self.auto_targets(specs, p.ctrl, p.source)
                    if targets is None:
                        self.emit("TRIGGER-NO-TARGET", p.ctrl.name,
                                  "#%d" % p.source.oid, ab.number)
                        continue
                entry = Entry(self.next_cid, "trigger", p.ctrl, p.source,
                              ab.number, targets, specs, subject=p.subject)
            self.next_cid += 1
            fields = [p.ctrl.name, "~%d" % entry.cid, "#%d" % p.source.oid,
                      entry.index]
            fields.extend(render_target(t) for t in entry.targets)
            self.emit("TRIGGER", *fields)
            entries.append(entry)
        for entry in reversed(entries):
            self.chain.append(entry)
        return True
