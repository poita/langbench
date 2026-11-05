#!/usr/bin/env python3
"""Spiremark reference implementation: match-file driver and output blocks.

Reads a match file on stdin, runs the engine of `engine.py`, and writes the
numbered event log interleaved with inspection blocks (SPEC.md sections 3, 4,
21, 23, 24).
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cards import BadDatabase, card_block, load_database, render_kw
from engine import PLAYERS, Action, Game, Target


class BadSetup(Exception):
    """Any violation of SPEC.md 4.1."""


U64 = (1 << 64) - 1

SINGLE_USE = ("CARDS", "SEED", "SPIRE", "OPENING", "MAXCAP", "HANDMAX",
              "TURNLIMIT", "FIRST", "SHUFFLE", "TRACE")
ZONE_WORDS = {"DECK": "deck", "HAND": "hand", "FIELD": "field",
              "ASH": "ash", "RIFT": "rift"}


def is_blank_or_comment(line):
    s = line.strip()
    return s == "" or s.startswith("#")


def uint(word, lo, hi):
    """Parse an unsigned decimal in [lo, hi]; raise BadSetup otherwise."""
    if not word or not all("0" <= c <= "9" for c in word):
        raise BadSetup("not a number: " + word)
    v = int(word)
    if v < lo or v > hi:
        raise BadSetup("out of range: " + word)
    return v


def parse_setup(lines):
    conf = {
        "cards": None,
        "seed": None,
        "spire": 25,
        "opening": 5,
        "maxcap": 10,
        "handmax": 7,
        "turnlimit": 200,
        "first": "A",
        "shuffle": True,
        "trace": "none",
        "cap": {"A": 0, "B": 0},
        "zones": {p: {z: [] for z in ("deck", "hand", "field", "ash", "rift")}
                  for p in PLAYERS},
    }
    seen = set()
    idx = 0
    started = False
    while idx < len(lines):
        raw = lines[idx]
        idx += 1
        if is_blank_or_comment(raw):
            continue
        words = raw.split()
        w = words[0]
        if w == "START":
            if len(words) != 1:
                raise BadSetup("START takes no arguments")
            started = True
            break
        if w in SINGLE_USE or (w == "CAP" and len(words) >= 2):
            key = w if w != "CAP" else "CAP " + words[1]
            if key in seen:
                raise BadSetup("duplicate " + key)
            seen.add(key)
        if w == "CARDS":
            if len(words) != 2:
                raise BadSetup("CARDS")
            conf["cards"] = words[1]
        elif w == "SEED":
            if len(words) != 2:
                raise BadSetup("SEED")
            conf["seed"] = uint(words[1], 0, U64)
        elif w == "SPIRE":
            if len(words) != 2:
                raise BadSetup("SPIRE")
            conf["spire"] = uint(words[1], 1, 1000000)
        elif w == "OPENING":
            if len(words) != 2:
                raise BadSetup("OPENING")
            conf["opening"] = uint(words[1], 0, 20)
        elif w == "MAXCAP":
            if len(words) != 2:
                raise BadSetup("MAXCAP")
            conf["maxcap"] = uint(words[1], 1, 100)
        elif w == "HANDMAX":
            if len(words) != 2:
                raise BadSetup("HANDMAX")
            conf["handmax"] = uint(words[1], 0, 100)
        elif w == "TURNLIMIT":
            if len(words) != 2:
                raise BadSetup("TURNLIMIT")
            conf["turnlimit"] = uint(words[1], 1, 100000)
        elif w == "FIRST":
            if len(words) != 2 or words[1] not in PLAYERS:
                raise BadSetup("FIRST")
            conf["first"] = words[1]
        elif w == "SHUFFLE":
            if len(words) != 2 or words[1] not in ("on", "off"):
                raise BadSetup("SHUFFLE")
            conf["shuffle"] = words[1] == "on"
        elif w == "TRACE":
            if len(words) != 2 or words[1] not in ("none", "legal", "state"):
                raise BadSetup("TRACE")
            conf["trace"] = words[1]
        elif w == "CAP":
            if len(words) != 3 or words[1] not in PLAYERS:
                raise BadSetup("CAP")
            conf["cap"][words[1]] = uint(words[2], 0, 100)
        elif w in ZONE_WORDS:
            if len(words) < 3 or words[1] not in PLAYERS:
                raise BadSetup(w)
            dest = conf["zones"][words[1]][ZONE_WORDS[w]]
            for entry in words[2:]:
                dest.extend(parse_entry(entry))
        else:
            raise BadSetup("unknown setup word " + w)
    if not started:
        raise BadSetup("missing START")
    if conf["cards"] is None or conf["seed"] is None:
        raise BadSetup("missing CARDS or SEED")
    return conf, idx


def parse_entry(entry):
    if "*" in entry:
        parts = entry.split("*")
        if len(parts) != 2:
            raise BadSetup("bad entry " + entry)
        cid, count = parts[0], uint(parts[1], 1, 1000)
    else:
        cid, count = entry, 1
    if not cid:
        raise BadSetup("bad entry " + entry)
    return [cid] * count


# -------------------------------------------------------------- script lines --

def parse_uint_word(word):
    """A script integer: digits only, 64-bit.  None when malformed."""
    if not word or not all("0" <= c <= "9" for c in word):
        return None
    v = int(word)
    return v if v <= U64 else None


def parse_objref(word):
    if not word.startswith("#"):
        return None
    return parse_uint_word(word[1:])


def parse_target_token(word):
    if word in PLAYERS:
        return ("player", word)
    if word.startswith("#"):
        v = parse_uint_word(word[1:])
        return None if v is None else ("obj", v)
    if word.startswith("~"):
        v = parse_uint_word(word[1:])
        return None if v is None else ("chain", v)
    return None


class Driver:
    def __init__(self, game, conf, out):
        self.g = game
        self.conf = conf
        self.out = out
        self.trace = conf["trace"]

    # ------------------------------------------------------- inspect blocks --

    def flags_of(self, o):
        g = self.g
        f = []
        if o.attacking:
            f.append("attacking")
        if o.blocked:
            f.append("blocked")
        if o.blocking is not None:
            f.append("blocking")
        if o.doomed:
            f.append("doomed")
        for i in sorted(o.once_used):
            f.append("once%d" % i)
        if g.settling(o):
            f.append("settling")
        if o.tenacity_used:
            f.append("tenacity-used")
        if o.ward > 0:
            f.append("ward%d" % o.ward)
        f.sort()
        return ",".join(f) if f else "-"

    def dump_block(self):
        g = self.g
        o = self.out
        o.append("STATE BEGIN")
        if g.over or g.decision is None:
            dec = "- over"
        else:
            dec = "%s %s" % (g.decision[0], g.decision[1])
        o.append("turn %d active %s phase %s decision %s"
                 % (g.turn, g.active, g.cur_phase, dec))
        if g.result is not None:
            o.append("result %s %s" % (g.result[0], g.result[1]))
        for p in PLAYERS:
            o.append("player %s spire %d ember %d cap %d vault %d hand %d "
                     "ash %d rift %d"
                     % (p, g.spire[p], g.ember[p], g.cap[p],
                        len(g.zones[p]["vault"]), len(g.zones[p]["hand"]),
                        len(g.zones[p]["ash"]), len(g.zones[p]["rift"])))
        for p in PLAYERS:
            for i, c in enumerate(g.zones[p]["hand"], 1):
                o.append("hand %s %d #%d %s" % (p, i, c.oid, c.card.cid))
        for p in PLAYERS:
            for obj in g.field_sorted():
                if g.ctrl(obj) != p:
                    continue
                if obj.card.type == "unit":
                    body = "%d/%d" % (g.cur_edge(obj), g.cur_core(obj))
                else:
                    body = "-/-"
                kws = g.kwlist(obj)
                o.append("field %s #%d %s %s w%d c%d %s %s kw %s"
                         % (p, obj.oid, obj.card.cid, body, obj.wounds,
                            obj.counters, "ready" if obj.ready else "exhausted",
                            self.flags_of(obj),
                            ",".join(kws) if kws else "-"))
        for zone in ("ash", "rift"):
            for p in PLAYERS:
                for i, c in enumerate(g.zones[p][zone], 1):
                    o.append("%s %s %d #%d %s" % (zone, p, i, c.oid, c.card.cid))
        for i, e in enumerate(g.chain, 1):
            line = "chain %d ~%d %s %s #%d %d" % (i, e.cid, e.ctrl, e.kind,
                                                  e.source.oid, e.index)
            if e.targets:
                line += " " + " ".join(t.render() for t in e.targets)
            o.append(line)
        for r in sorted(g.records, key=lambda r: r.eid):
            o.append(self.effect_line(r))
        for d in sorted(g.delayed, key=lambda d: d.ts):
            line = "delayed %d %s %s" % (d.ts, d.ctrl, d.when)
            if d.targets:
                line += " " + " ".join(t.render() for t in d.targets)
            o.append(line)
        o.append("STATE END")

    def effect_line(self, r):
        g = self.g
        D = g.derived()
        if r.duration == "aura":
            who = g.ctrl(r.source)
            objs = D.aura_objs.get(r.eid, [])
            active = D.aura_active.get(r.eid, False)
            amt = D.aura_amt.get(r.eid) if active else g.aura_amounts(r)
            if r.kind == "cheaper":
                desc = "cheaper %d" % amt[0]
                objs = []
            elif r.kind == "grant":
                desc = "grant %s" % render_kw(amt[0], amt[1])
            elif r.kind == "swapstats":
                desc = "swapstats"
            else:
                desc = "%s %d %d" % (r.kind, amt[0], amt[1])
            if not active:
                objs = []
        else:
            who = r.ctrl0
            objs = [o for o in r.affected if o.zone == "field"]
            if r.kind == "grant":
                desc = "grant %s" % render_kw(r.args[0], r.args[1])
            elif r.kind == "strip":
                desc = "strip"
            elif r.kind == "swapstats":
                desc = "swapstats"
            elif r.kind == "control":
                desc = "control %s" % r.ctrl0
            else:
                desc = "%s %d %d" % (r.kind, r.args[0], r.args[1])
        on = ",".join("#%d" % o.oid for o in objs) if objs else "-"
        return "effect %d ts%d %s %s %s on %s" % (r.eid, r.ts, who, r.duration,
                                                  desc, on)

    def legal_block(self):
        g = self.g
        o = self.out
        if g.over or g.decision is None:
            o.append("LEGAL BEGIN - over")
            o.append("LEGAL END")
            return
        who, kind = g.decision
        o.append("LEGAL BEGIN %s %s" % (who, kind))
        if kind == "priority":
            o.append("PASS")
            for pos, c in enumerate(g.zones[who]["hand"], 1):
                card = c.card
                if not g.play_timing_ok(card, who):
                    continue
                if g.ember[who] < g.card_cost(card, who):
                    continue
                tspecs = card.abilities[0].tspecs if card.type == "rite" else []
                if not tspecs:
                    o.append("PLAY %d %s" % (pos, card.cid))
                    continue
                for combo in g.target_tuples(tspecs, who, c, None):
                    o.append("PLAY %d %s %s"
                             % (pos, card.cid,
                                " ".join(t.token() for t in combo)))
            for obj in sorted(g.field, key=lambda x: x.oid):
                if g.ctrl(obj) != who or g.abilities_inactive(obj):
                    continue
                for ab in obj.card.abilities:
                    if ab.kind != "act":
                        continue
                    if not g.cost_payable(obj, ab, who):
                        continue
                    if not ab.tspecs:
                        o.append("ACT #%d %d" % (obj.oid, ab.index))
                        continue
                    for combo in g.target_tuples(ab.tspecs, who, obj, None):
                        o.append("ACT #%d %d %s"
                                 % (obj.oid, ab.index,
                                    " ".join(t.token() for t in combo)))
        elif kind == "attackers":
            cands = [u for u in sorted(g.field, key=lambda x: x.oid)
                     if g.can_attack(u)]
            for u in cands:
                o.append("CANATTACK #%d" % u.oid)
            for u in cands:
                if g.has_kw(u, "relentless"):
                    o.append("MUSTATTACK #%d" % u.oid)
        else:
            attackers = sorted(g.attackers_on_field(), key=lambda x: x.oid)
            for b in sorted(g.field, key=lambda x: x.oid):
                for a in attackers:
                    if g.can_block(b, a):
                        o.append("CANBLOCK #%d #%d" % (b.oid, a.oid))
            for a in attackers:
                if g.has_kw(a, "provoke"):
                    o.append("MUSTBLOCK #%d" % a.oid)
        o.append("LEGAL END")

    def vault_block(self):
        g = self.g
        self.out.append("VAULT BEGIN")
        for p in PLAYERS:
            for i, c in enumerate(g.zones[p]["vault"], 1):
                self.out.append("vault %s %d #%d %s" % (p, i, c.oid, c.card.cid))
        self.out.append("VAULT END")

    def trace_block(self):
        if self.trace == "legal":
            self.legal_block()
        elif self.trace == "state":
            self.dump_block()

    # -------------------------------------------------------- script driving --

    def run(self, lines, start):
        g = self.g
        for i in range(start, len(lines)):
            raw = lines[i]
            lineno = i + 1
            if is_blank_or_comment(raw):
                continue
            words = raw.split()
            w = words[0]
            if w == "DUMP" and len(words) == 1:
                self.dump_block()
            elif w == "LEGAL" and len(words) == 1:
                self.legal_block()
            elif w == "VAULT" and len(words) == 1:
                self.vault_block()
            elif w == "CARD" and len(words) == 2:
                self.out.extend(card_block(g.db, words[1]))
            else:
                self.do_action_line(words, lineno)
        if not g.over:
            g.emit("RESULT pending none")

    def err(self, lineno, kind):
        self.out.append("ERR %d %s" % (lineno, kind))

    def do_action_line(self, words, lineno):
        g = self.g
        act = self.parse_action(words)
        if act is None:
            self.err(lineno, "bad-syntax")
            return
        if g.over:
            self.err(lineno, "game-over")
            return
        if g.decision is None:
            self.err(lineno, "game-over")
            return
        who, kind = g.decision
        if act.player != who:
            self.err(lineno, "not-your-turn")
            return
        if act.kind != "CONCEDE":
            want = {"PASS": "priority", "PLAY": "priority", "ACT": "priority",
                    "ATTACK": "attackers", "BLOCK": "blockers"}[act.kind]
            if want != kind:
                self.err(lineno, "wrong-decision")
                return
        reason = self.validate(act)
        if reason is not None:
            self.err(lineno, reason)
            return
        if act.kind == "CONCEDE":
            try:
                g.concede(act.player)
            except Exception:
                pass
            g.gen = None
            g.decision = None
            self.trace_block()
            return
        g.action = act
        g.resume()
        self.trace_block()

    def parse_action(self, words):
        if words[0] not in PLAYERS or len(words) < 2:
            return None
        p = words[0]
        verb = words[1]
        rest = words[2:]
        if verb in ("PASS", "CONCEDE"):
            if rest:
                return None
            return Action(verb, p)
        if verb == "PLAY":
            if not rest:
                return None
            pos = parse_uint_word(rest[0])
            if pos is None:
                return None
            a = Action("PLAY", p)
            a.pos = pos
            for t in rest[1:]:
                tok = parse_target_token(t)
                if tok is None:
                    return None
                a.targets.append((t, tok))
            return a
        if verb == "ACT":
            if len(rest) < 2:
                return None
            oid = parse_objref(rest[0])
            idx = parse_uint_word(rest[1])
            if oid is None or idx is None:
                return None
            a = Action("ACT", p)
            a.oid = oid
            a.index = idx
            for t in rest[2:]:
                tok = parse_target_token(t)
                if tok is None:
                    return None
                a.targets.append((t, tok))
            return a
        if verb == "ATTACK":
            a = Action("ATTACK", p)
            for t in rest:
                oid = parse_objref(t)
                if oid is None:
                    return None
                a.objs.append(oid)
            return a
        if verb == "BLOCK":
            a = Action("BLOCK", p)
            for t in rest:
                if t.count(":") != 1:
                    return None
                lhs, rhs = t.split(":")
                b = parse_objref(lhs)
                at = parse_objref(rhs)
                if b is None or at is None:
                    return None
                a.pairs.append((b, at))
            return a
        return None

    # -------------------------------------------------------- action checks --

    def resolve_token(self, tok):
        g = self.g
        if tok[0] == "player":
            return Target.of_player(tok[1])
        if tok[0] == "obj":
            o = g.objects.get(tok[1])
            return None if o is None else Target.of_obj(o)
        for e in g.chain:
            if e.cid == tok[1]:
                return Target.of_entry(e)
        return None

    def check_targets(self, act, tspecs, ctrl, source):
        """Returns an error kind, or None and fills act.targets with Targets."""
        if len(act.targets) != len(tspecs):
            return "bad-target-count"
        toks = [t[0] for t in act.targets]
        built = []
        for (tokstr, tok), tspec in zip(act.targets, tspecs):
            t = self.resolve_token(tok)
            if t is None:
                return "illegal-target"
            if not self.g.target_legal(t, tspec, ctrl, source, None):
                return "illegal-target"
            built.append(t)
        if len(set(toks)) != len(toks):
            return "illegal-target"
        act.targets = built
        return None

    def validate(self, act):
        g = self.g
        if act.kind in ("PASS", "CONCEDE"):
            return None
        if act.kind == "PLAY":
            hand = g.zones[act.player]["hand"]
            if act.pos == 0 or act.pos > len(hand):
                return "no-such-card"
            o = hand[act.pos - 1]
            card = o.card
            if not g.play_timing_ok(card, act.player):
                return "bad-timing"
            tspecs = card.abilities[0].tspecs if card.type == "rite" else []
            bad = self.check_targets(act, tspecs, act.player, o)
            if bad:
                return bad
            if g.ember[act.player] < g.card_cost(card, act.player):
                return "cannot-afford"
            return None
        if act.kind == "ACT":
            o = g.objects.get(act.oid)
            if o is None or o.zone != "field" or g.ctrl(o) != act.player:
                return "no-such-object"
            abils = o.card.abilities
            if act.index < 1 or act.index > len(abils):
                return "no-such-ability"
            ab = abils[act.index - 1]
            if ab.kind != "act" or g.abilities_inactive(o):
                return "no-such-ability"
            bad = self.check_targets(act, ab.tspecs, act.player, o)
            if bad:
                return bad
            if not g.cost_payable(o, ab, act.player):
                return "cost-unpayable"
            return None
        if act.kind == "ATTACK":
            if len(set(act.objs)) != len(act.objs):
                return "duplicate-attacker"
            objs = []
            for oid in act.objs:
                o = g.objects.get(oid)
                if o is None or not g.can_attack(o):
                    return "illegal-attacker"
                objs.append(o)
            chosen = set(act.objs)
            for u in g.field:
                if g.can_attack(u) and g.has_kw(u, "relentless") \
                        and u.oid not in chosen:
                    return "missing-required-attacker"
            act.objs = objs
            return None
        if act.kind == "BLOCK":
            bs = [b for b, _ in act.pairs]
            if len(set(bs)) != len(bs):
                return "duplicate-blocker"
            pairs = []
            for boid, aoid in act.pairs:
                b = g.objects.get(boid)
                a = g.objects.get(aoid)
                if b is None or a is None or not g.can_block(b, a):
                    return "illegal-blocker"
                pairs.append((b, a))
            if not g.provoke_satisfied(pairs):
                return "missing-required-block"
            act.pairs = pairs
            return None
        return None


def run_text(data):
    """Run one match file and return its complete output as a string."""
    lines = [ln[:-1] if ln.endswith("\r") else ln for ln in data.split("\n")]
    out = []
    try:
        conf, start = parse_setup(lines)
    except BadSetup:
        return "FATAL bad-setup\n"
    try:
        db = load_database(conf["cards"])
    except (BadDatabase, RecursionError):
        return "FATAL bad-database\n"
    for p in PLAYERS:
        for zone in conf["zones"][p].values():
            for cid in zone:
                if cid not in db:
                    return "FATAL unknown-card\n"
    game = Game(db, conf, out)
    game.begin()
    Driver(game, conf, out).run(lines, start)
    return "".join(ln + "\n" for ln in out)


def main():
    data = sys.stdin.buffer.read().decode("utf-8", "replace")
    sys.stdout.write(run_text(data))
    return 0


if __name__ == "__main__":
    # Deeply nested s-expressions in a malformed database recurse; the limit is
    # raised a little and a RecursionError is reported as `bad-database`.
    sys.setrecursionlimit(4000)
    sys.exit(main())
