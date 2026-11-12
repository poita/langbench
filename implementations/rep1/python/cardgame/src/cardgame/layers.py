"""The layer engine: whole-board derivation of current characteristics.

Implements SPEC section 14.3.  :class:`LayerMixin` is mixed into the game
class; :meth:`LayerMixin.derive` recomputes, in one pass over the continuous
effect records, every Field object's current controller, keywords, edge and
core, the set of stripped objects and the active ``cheaper`` reductions.
"""

from __future__ import annotations

_EMPTY: frozenset = frozenset()


class LayerMixin:
    """Derivation of current characteristics (cached until dirtied)."""

    # Attributes initialised by the game class:
    #   _dirty, _aura_mode, _ctrl, _stripped, _edge, _core, _kw, _kwn,
    #   _plat, _cheaper, records, field

    def derive(self) -> None:
        """Bring the derived characteristics up to date.

        A *structural* change (``_sver`` moved: Field membership, counters,
        records) recomputes everything.  When only volatile inputs changed,
        just the volatile aura records are re-evaluated, and the layers are
        re-applied only if one of them now says something different.
        """
        self._dirty = False
        full = self._sver != self._dsver
        if full:
            self._dsver = self._sver
            self._derive_structure()
        records = self.records
        changed = full
        self._aura_mode = True
        try:
            for rec in records:
                if rec.duration != "aura" or not (full or rec.volatile):
                    continue
                old = rec.leaves
                rec.leaves = []
                self._eval_statics(rec, rec.statics,
                                   rec.source.oid not in self._stripped)
                if not full and rec.leaves != old:
                    changed = True
        finally:
            self._aura_mode = False
        if changed:
            self._apply_layers()

    def _derive_structure(self) -> None:
        """Layer 1 (control) and the stripped set; also aura controllers."""
        field = self.field
        ctrl = {oid: o.ctrl for oid, o in field.items()}
        for rec in self.records:
            if rec.kind == "control":
                for o in rec.affected:
                    if o.zone == "field":
                        ctrl[o.oid] = rec.ctrl
        self._ctrl = ctrl
        stripped: set[int] = set()
        for rec in self.records:
            if rec.kind == "strip":
                for o in rec.affected:
                    if o.zone == "field":
                        stripped.add(o.oid)
        self._stripped = stripped
        for rec in self.records:
            if rec.duration == "aura":
                rec.ctrl = ctrl[rec.source.oid]

    def _apply_layers(self) -> None:
        """Layers 2-6 over the records' current (cached) leaves."""
        field = self.field
        l2: list = []
        l3: list = []
        l4: list = []
        l6: list = []
        cheaper: list = []
        for rec in self.records:
            if rec.duration == "aura":
                for kind, args, objs, active in rec.leaves:
                    if not active:
                        continue
                    if kind == "cheaper":
                        cheaper.append((rec.ctrl, args[0], args[1]))
                    elif kind == "grant":
                        l2.append((kind, args, objs))
                    elif kind == "setbody":
                        l3.append((args, objs))
                    elif kind == "modify":
                        l4.append((args, objs))
                    else:
                        l6.append(objs)
            else:
                kind = rec.kind
                if kind == "grant" or kind == "strip":
                    l2.append((kind, rec.args, rec.affected))
                elif kind == "setbody":
                    l3.append((rec.args, rec.affected))
                elif kind == "modify":
                    l4.append((rec.args, rec.affected))
                elif kind == "swapstats":
                    l6.append(rec.affected)
        self._cheaper = cheaper

        # Start from printed characteristics.
        edge: dict[int, int] = {}
        core: dict[int, int] = {}
        kw: dict[int, tuple] = {}
        for oid, o in field.items():
            c = o.card
            edge[oid] = c.edge
            core[oid] = c.core
            kw[oid] = c.keywords

        for kind, args, objs in l2:
            if kind == "grant":
                for o in objs:
                    if o.zone == "field":
                        kw[o.oid] = kw[o.oid] + (args,)
            else:
                for o in objs:
                    if o.zone == "field":
                        kw[o.oid] = ()
        for (e, c), objs in l3:
            for o in objs:
                if o.zone == "field":
                    edge[o.oid] = e
                    core[o.oid] = c
        for (e, c), objs in l4:
            for o in objs:
                if o.zone == "field":
                    edge[o.oid] += e
                    core[o.oid] += c
        for oid, o in field.items():
            n = o.counters
            if n:
                edge[oid] += n
                core[oid] += n
        for objs in l6:
            for o in objs:
                if o.zone == "field":
                    oid = o.oid
                    edge[oid], core[oid] = core[oid], edge[oid]

        self._edge = edge
        self._core = core
        self._kw = kw
        kwn: dict[int, frozenset] = {}
        plat: dict[int, int] = {}
        for oid, ks in kw.items():
            if ks:
                kwn[oid] = frozenset(k for k, _ in ks)
                plat[oid] = sum(v for k, v in ks if k == "plating")
            else:
                kwn[oid] = _EMPTY
                plat[oid] = 0
        self._kwn = kwn
        self._plat = plat

    def _eval_statics(self, rec, statics: list, active: bool) -> None:
        """Evaluate an aura record's statics into ``rec.leaves``.

        Each leaf is ``(kind, args, objects, active)``; ``args`` are the
        amounts evaluated *now*, so inactive leaves still describe themselves.
        """
        ctx = self._aura_ctx(rec)
        for st in statics:
            op = st[0]
            if op == "when":
                holds = active and self.eval_cond(st[1], ctx)
                self._eval_statics(rec, st[2], holds)
            elif op == "modify" or op == "setbody":
                args = (self.eval_amt(st[1], ctx), self.eval_amt(st[2], ctx))
                objs = self.sel_objs(st[3], ctx) if active else []
                rec.leaves.append((op, args, objs, active))
            elif op == "swapstats":
                objs = self.sel_objs(st[1], ctx) if active else []
                rec.leaves.append((op, None, objs, active))
            elif op == "grant":
                objs = self.sel_objs(st[2], ctx) if active else []
                rec.leaves.append((op, st[1], objs, active))
            else:  # cheaper
                rec.leaves.append((op, (st[1], st[2]), [], active))
