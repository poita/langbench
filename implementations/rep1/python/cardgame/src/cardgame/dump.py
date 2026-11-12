"""Inspection blocks: ``DUMP``, ``LEGAL``, ``VAULT`` and ``CARD`` (SPEC 23)."""

from __future__ import annotations

from .model import Card, render_keyword
from .sexpr import render
from .state import render_target


def _kwlist(kws: tuple) -> str:
    items = set()
    plating = 0
    for name, val in kws:
        if name == "plating":
            plating += val
        else:
            items.add(name)
    if any(n == "plating" for n, _ in kws):
        items.add("plating:%d" % plating)
    return ",".join(sorted(items)) if items else "-"


def _flags(game, o) -> str:
    flags = []
    if o.attacking:
        flags.append("attacking")
    if o.blocked:
        flags.append("blocked")
    if o.blocking:
        flags.append("blocking")
    if o.doomed:
        flags.append("doomed")
    for idx in o.once:
        flags.append("once%d" % idx)
    if o.since >= game.turn:
        flags.append("settling")
    if o.tenacity_used:
        flags.append("tenacity-used")
    if o.ward > 0:
        flags.append("ward%d" % o.ward)
    return ",".join(sorted(flags)) if flags else "-"


def _effect_desc(kind: str, args, ctrl) -> str:
    if kind in ("modify", "setbody"):
        return "%s %d %d" % (kind, args[0], args[1])
    if kind == "grant":
        return "grant " + render_keyword(*args)
    if kind == "control":
        return "control " + ctrl.name
    if kind == "cheaper":
        return "cheaper %d" % args[0]
    return kind


def dump_lines(game) -> list[str]:
    """The ``DUMP`` block for the current state."""
    if game._dirty:
        game.derive()
    out = ["STATE BEGIN"]
    if game.over:
        decision = "- over"
    else:
        decision = "%s %s" % (game.decision[0].name, game.decision[1])
    out.append("turn %d active %s phase %s decision %s"
               % (game.turn, game.active.name, game.phase, decision))
    if game.over:
        out.append("result %s %s" % game.result)
    for p in game.players:
        out.append("player %s spire %d ember %d cap %d vault %d hand %d "
                   "ash %d rift %d" % (p.name, p.spire, p.ember, p.cap,
                                       len(p.vault), len(p.hand), len(p.ash),
                                       len(p.rift)))
    for p in game.players:
        for i, o in enumerate(p.hand, 1):
            out.append("hand %s %d #%d %s" % (p.name, i, o.oid, o.card.id))
    for p in game.players:
        for o in game.field.values():
            if game.ctrl(o) is not p:
                continue
            if o.card.type == "unit":
                body = "%d/%d" % (game.cur_edge(o), game.cur_core(o))
            else:
                body = "-/-"
            out.append("field %s #%d %s %s w%d c%d %s %s kw %s" % (
                p.name, o.oid, o.card.id, body, o.wounds, o.counters,
                "ready" if o.ready else "exhausted", _flags(game, o),
                _kwlist(game.cur_keywords(o))))
    for zone in ("ash", "rift"):
        for p in game.players:
            for i, o in enumerate(p.zone(zone), 1):
                out.append("%s %s %d #%d %s" % (zone, p.name, i, o.oid,
                                                o.card.id))
    for pos, e in enumerate(game.chain, 1):
        parts = ["chain", str(pos), "~%d" % e.cid, e.ctrl.name, e.kind,
                 "#%d" % e.source.oid, str(e.index)]
        for t, removed in zip(e.targets, e.removed):
            parts.append("-" if removed else render_target(t))
        out.append(" ".join(parts))
    for rec in game.records:
        if rec.duration == "aura":
            if rec.leaves:
                kind, args, objs, active = rec.leaves[0]
                desc = _effect_desc(kind, args, rec.ctrl)
            else:
                desc, objs, active = "nothing", [], False
            objs = objs if active else []
            dur = "aura"
        else:
            desc = _effect_desc(rec.kind, rec.args, rec.ctrl)
            objs = [o for o in rec.affected if o.zone == "field"]
            dur = "turn"
        if rec.duration == "aura" and rec.leaves and rec.leaves[0][0] == "cheaper":
            objs = []
        out.append("effect %d ts%d %s %s %s on %s" % (
            rec.eid, rec.ts, rec.ctrl.name, dur, desc,
            ",".join("#%d" % o.oid for o in objs) if objs else "-"))
    for d in sorted(game.delayed, key=lambda d: d.ts):
        parts = ["delayed", str(d.ts), d.ctrl.name, d.when]
        parts.extend(render_target(t) for t in d.targets)
        out.append(" ".join(parts))
    out.append("STATE END")
    return out


def legal_block(game) -> list[str]:
    """The ``LEGAL`` block."""
    if game.over:
        return ["LEGAL BEGIN - over", "LEGAL END"]
    player, kind = game.decision
    return (["LEGAL BEGIN %s %s" % (player.name, kind)] + game.legal_lines()
            + ["LEGAL END"])


def vault_lines(game) -> list[str]:
    out = ["VAULT BEGIN"]
    for p in game.players:
        for i, o in enumerate(p.vault, 1):
            out.append("vault %s %d #%d %s" % (p.name, i, o.oid, o.card.id))
    out.append("VAULT END")
    return out


def _print_targets(raw) -> str:
    return render(raw) if raw is not None else "-"


def card_block(card_id: str, card: Card | None) -> list[str]:
    """The ``CARD`` block for *card_id* (``card`` is None when unknown)."""
    out = ["CARD BEGIN %s" % card_id]
    if card is None:
        out.append("unknown")
        out.append("CARD END")
        return out
    out.append("name %s" % card.name)
    out.append("type %s" % card.type)
    out.append("cost %d" % card.cost)
    if card.type == "unit":
        out.append("body %d/%d" % (card.edge, card.core))
    out.append("tags %s" % (",".join(card.tags) if card.tags else "-"))
    kws = sorted(render_keyword(n, v) for n, v in card.keywords)
    out.append("keywords %s" % (",".join(kws) if kws else "-"))
    for ab in card.abilities:
        effects = " ".join(render(e) for e in ab.raw_effects)
        if ab.kind == "resolve":
            text = "resolve %s %s" % (_print_targets(ab.raw_targets), effects)
        elif ab.kind == "on":
            text = "on %s %s %s" % (ab.event, _print_targets(ab.raw_targets),
                                    effects)
        elif ab.kind == "act":
            text = "act %s %s %s" % (render(ab.raw_cost),
                                     _print_targets(ab.raw_targets), effects)
        else:
            text = "aura %s" % effects
        out.append("ability %d %s" % (ab.number, text))
    out.append("CARD END")
    return out
