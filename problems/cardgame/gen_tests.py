#!/usr/bin/env python3
"""Deterministic generator for the Spiremark (`cardgame`) test suite.

Builds every test case, computes its expected output with the reference
implementation in `reference/`, and writes the public cases to
`problems/cardgame/tests/` and the hidden cases to
`$LANGBENCH_HIDDEN (default: langbench-hidden next to this checkout)/cardgame/tests/` using one shared numbering
sequence, so a name never collides between the two directories.

Cases come in two flavours:

* hand-written match files, one per rule, error kind, keyword and interaction
  of SPEC.md;
* self-played match files, where a biased random driver walks the reference
  engine's own `LEGAL` output and records the actions it chose, which produces
  long legal scripts of any requested size.

Every case carries assertions (`no_err`, `want`, `want_err`) that are checked
against the reference output while generating, so a hand-written script that
stops exercising what it was written for fails the generator instead of
silently testing nothing.

Run it from anywhere:  python3 problems/cardgame/gen_tests.py
"""

import os
import random
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "reference")
PUBLIC_DIR = os.path.join(HERE, "tests")
HIDDEN_DIR = os.path.join(os.environ.get("LANGBENCH_HIDDEN") or os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "langbench-hidden")), "cardgame", "tests")

sys.path.insert(0, REF)
os.chdir(HERE)
sys.setrecursionlimit(4000)

import main as ref                      # noqa: E402
from cards import load_database         # noqa: E402
from engine import Game                 # noqa: E402

DB = "data/cards.spire"

# Groups in output order.  Every group holds at least four cases so that the
# public/hidden split gives both sets some of each feature area.
GROUPS = ["fatal", "card", "setup", "prng", "effect", "layer", "trigger",
          "combat", "chain", "error", "ending", "trace", "extra", "random"]

CASES = {g: [] for g in GROUPS}
FAILURES = []


def S(seed=1, cards=DB, spire=None, opening=0, shuffle="off", maxcap=None,
      handmax=None, turnlimit=None, first=None, trace=None, cap_a=None,
      cap_b=None, deck_a=(), deck_b=(), hand_a=(), hand_b=(), field_a=(),
      field_b=(), ash_a=(), ash_b=(), rift_a=(), rift_b=(), head=(), tail=()):
    """Build a setup block.  Zone arguments are lists of `<entries>` words."""
    lines = list(head)
    if cards is not None:
        lines.append("CARDS " + cards)
    if seed is not None:
        lines.append("SEED %s" % seed)
    for word, val in (("SPIRE", spire), ("OPENING", opening),
                      ("MAXCAP", maxcap), ("HANDMAX", handmax),
                      ("TURNLIMIT", turnlimit), ("FIRST", first),
                      ("SHUFFLE", shuffle), ("TRACE", trace)):
        if val is not None:
            lines.append("%s %s" % (word, val))
    for word, val in (("CAP A", cap_a), ("CAP B", cap_b)):
        if val is not None:
            lines.append("%s %s" % (word, val))
    for word, p, val in (("DECK", "A", deck_a), ("DECK", "B", deck_b),
                         ("HAND", "A", hand_a), ("HAND", "B", hand_b),
                         ("FIELD", "A", field_a), ("FIELD", "B", field_b),
                         ("ASH", "A", ash_a), ("ASH", "B", ash_b),
                         ("RIFT", "A", rift_a), ("RIFT", "B", rift_b)):
        if val:
            lines.append("%s %s %s" % (word, p, " ".join(val)))
    lines.extend(tail)
    lines.append("START")
    return lines


def mf(setup, script=()):
    """Join a setup block and a script into a match file."""
    return "\n".join(list(setup) + list(script)) + "\n"


def add(group, name, text, no_err=True, want=(), want_err=(), big=False,
        split=None):
    """Record one case and check the reference output against expectations.

    `split` forces the case into the "public" or "hidden" set; by default
    every fourth case of a group is public.
    """
    out = ref.run_text(text)
    errs = [ln.split()[2] for ln in out.split("\n")
            if ln.startswith("ERR ") and len(ln.split()) >= 3]
    if no_err and errs:
        FAILURES.append("%s/%s: unexpected ERR %s" % (group, name, errs[:4]))
    for kind in want_err:
        if kind not in errs:
            FAILURES.append("%s/%s: missing ERR kind %s (got %s)"
                            % (group, name, kind, errs))
    for frag in want:
        if frag not in out:
            FAILURES.append("%s/%s: output lacks %r" % (group, name, frag))
    if not big and len(out) > 4_000_000:
        FAILURES.append("%s/%s: output too large (%d bytes)"
                        % (group, name, len(out)))
    CASES[group].append((name, text, out, split))
    return out


# ------------------------------------------------------------- self-play ----

BOGUS = [
    "A FOO", "B WAIT", "A PASS now", "A PLAY", "A PLAY x", "A ACT #3",
    "A ACT 3 1", "A BLOCK #1#2", "A ATTACK q", "DUMP all", "CARD",
    "CARD A B", "LEGAL now", "VAULT 2", "PLAY 1", "A CONCEDE 1",
    "a pass", "A PLAY 1 Z", "A PLAY 1 #", "A ATTACK #99999999999999999999",
]
DIRECTIVES = ["DUMP", "LEGAL", "VAULT", "CARD CIN-003", "CARD LOM-039",
              "CARD ZZZ-001"]


class SelfPlay:
    """Drives the reference engine through its own LEGAL output.

    The chosen actions are recorded as script lines, so the result is a match
    file whose actions are all accepted (apart from the bogus lines that are
    deliberately mixed in).
    """

    def __init__(self, setup, seed, focus=(), act_bias=0.75, attack_bias=0.55,
                 block_bias=0.5, directive_rate=0.0, error_rate=0.0,
                 directives=DIRECTIVES):
        self.rng = random.Random(seed)
        self.setup = list(setup)
        self.focus = set(focus)
        self.act_bias = act_bias
        self.attack_bias = attack_bias
        self.block_bias = block_bias
        self.directive_rate = directive_rate
        self.error_rate = error_rate
        self.directives = directives
        self.script = []
        lines = mf(self.setup).split("\n")
        conf, _ = ref.parse_setup(lines)
        self.out = []
        self.g = Game(load_database(conf["cards"]), conf, self.out)
        self.g.begin()
        self.drv = ref.Driver(self.g, conf, self.out)
        self.probe = ref.Driver(self.g, conf, [])

    def legal(self):
        self.probe.out = []
        self.probe.legal_block()
        return self.probe.out[1:-1]

    def priority_line(self, who, legal):
        plays = [ln for ln in legal if ln != "PASS"]
        if plays and self.rng.random() < self.act_bias:
            focused = [ln for ln in plays if self.is_focused(ln)]
            pick = self.rng.choice(focused if focused else plays)
            if pick.startswith("PLAY"):
                w = pick.split()
                return "%s PLAY %s" % (who, " ".join([w[1]] + w[3:]))
            return "%s %s" % (who, pick)
        return "%s PASS" % who

    def is_focused(self, line):
        w = line.split()
        if w[0] == "PLAY":
            return w[2] in self.focus
        obj = self.g.objects.get(int(w[1][1:]))
        return obj is not None and obj.card.cid in self.focus

    def attack_line(self, who, legal):
        can = [w.split()[1] for w in legal if w.startswith("CANATTACK")]
        must = [w.split()[1] for w in legal if w.startswith("MUSTATTACK")]
        chosen = set(must)
        for c in can:
            if self.rng.random() < self.attack_bias:
                chosen.add(c)
        oids = sorted(chosen, key=lambda s: int(s[1:]))
        return ("%s ATTACK " % who + " ".join(oids)).rstrip()

    def block_line(self, who, legal):
        pairs = [ln.split()[1:] for ln in legal if ln.startswith("CANBLOCK")]
        self.rng.shuffle(pairs)
        used = set()
        sel = []
        for b, a in pairs:
            if b in used or self.rng.random() >= self.block_bias:
                continue
            used.add(b)
            sel.append((int(b[1:]), "%s:%s" % (b, a)))
        sel.sort()
        return ("%s BLOCK " % who + " ".join(p for _, p in sel)).rstrip()

    def fallback_line(self, who, kind, legal):
        """A line that is always accepted at this decision point."""
        if kind == "priority":
            return "%s PASS" % who
        if kind == "attackers":
            must = [w.split()[1] for w in legal if w.startswith("MUSTATTACK")]
            oids = sorted(must, key=lambda s: int(s[1:]))
            return ("%s ATTACK " % who + " ".join(oids)).rstrip()
        pairs = [tuple(ln.split()[1:]) for ln in legal
                 if ln.startswith("CANBLOCK")]
        provoke = [ln.split()[1] for ln in legal if ln.startswith("MUSTBLOCK")]
        used = set()
        sel = []
        for a in provoke:
            for b, a2 in pairs:
                if a2 == a and b not in used:
                    used.add(b)
                    sel.append((int(b[1:]), "%s:%s" % (b, a)))
        sel.sort()
        return ("%s BLOCK " % who + " ".join(p for _, p in sel)).rstrip()

    def feed(self, line):
        """Hand one script line to the driver; report whether it was an ERR."""
        lineno = len(self.setup) + len(self.script) + 1
        mark = len(self.out)
        self.drv.do_action_line(line.split(), lineno)
        bad = any(x.startswith("ERR ") for x in self.out[mark:])
        del self.out[mark:]
        self.script.append(line)
        return bad

    def step(self):
        g = self.g
        if g.over or g.decision is None:
            return False
        if self.rng.random() < self.directive_rate:
            self.script.append(self.rng.choice(self.directives))
        if self.rng.random() < self.error_rate:
            self.feed(self.rng.choice(BOGUS))
            if g.over or g.decision is None:
                return False
        who, kind = g.decision
        legal = self.legal()
        for _ in range(6):
            if kind == "priority":
                line = self.priority_line(who, legal)
            elif kind == "attackers":
                line = self.attack_line(who, legal)
            else:
                line = self.block_line(who, legal)
            if not self.feed(line):
                return True
            self.script.pop()
        if not self.feed(self.fallback_line(who, kind, legal)):
            return True
        self.script.pop()
        return False

    def run(self, steps):
        for _ in range(steps):
            if not self.step():
                break
        return self.script


def selfplay(setup, seed, steps, **kw):
    return SelfPlay(setup, seed, **kw).run(steps)


class Runner(SelfPlay):
    """Hand-written scripts, checked against the engine as they are written.

    `do` asserts that a line is accepted, `bad` that it is rejected with a
    given error kind, and `auto`/`to_phase`/`to_turn` fill in the passing and
    the empty combat declarations needed to reach a point in the turn.
    """

    def __init__(self, setup, seed=1):
        SelfPlay.__init__(self, setup, seed, act_bias=0.0, attack_bias=0.0,
                          block_bias=0.0)
        self.problems = []

    def reject_kind(self, line):
        """Run one line; return the ERR kind it produced, or None."""
        lineno = len(self.setup) + len(self.script) + 1
        mark = len(self.out)
        self.drv.do_action_line(line.split(), lineno)
        kinds = [x.split()[2] for x in self.out[mark:] if x.startswith("ERR ")]
        del self.out[mark:]
        self.script.append(line)
        return kinds[0] if kinds else None

    def do(self, *lines):
        for line in lines:
            kind = self.reject_kind(line)
            if kind is not None:
                self.problems.append("%r rejected: %s" % (line, kind))
        return self

    def bad(self, line, kind=None):
        got = self.reject_kind(line)
        if got is None:
            self.problems.append("%r was accepted, expected %s" % (line, kind))
        elif kind is not None and got != kind:
            self.problems.append("%r gave %s, expected %s" % (line, got, kind))
        return self

    def say(self, *lines):
        """Append directive lines, which never change the game state."""
        self.script.extend(lines)
        return self

    def auto(self, n=1):
        """Take the dull action (pass, no attackers, no blockers) n times."""
        for _ in range(n):
            if self.g.over or self.g.decision is None:
                break
            who, kind = self.g.decision
            if kind == "priority":
                self.do("%s PASS" % who)
            elif kind == "attackers":
                self.do("%s ATTACK" % who)
            else:
                self.do(self.fallback_line(who, kind, self.legal()))
        return self

    def to_phase(self, phase, player=None, kind="priority", limit=400):
        """Pass until the engine waits in `phase` for `player`."""
        for _ in range(limit):
            g = self.g
            if g.over or g.decision is None:
                self.problems.append("match ended before phase " + phase)
                return self
            if g.cur_phase == phase and g.decision[1] == kind \
                    and (player is None or g.decision[0] == player):
                return self
            self.auto()
        self.problems.append("never reached phase " + phase)
        return self

    def to_turn(self, turn, phase="main1", player=None, kind="priority"):
        for _ in range(4000):
            g = self.g
            if g.over or g.decision is None:
                self.problems.append("match ended before turn %d" % turn)
                return self
            if g.turn == turn and g.cur_phase == phase \
                    and g.decision[1] == kind \
                    and (player is None or g.decision[0] == player):
                return self
            if g.turn > turn:
                self.problems.append("overshot turn %d" % turn)
                return self
            self.auto()
        self.problems.append("never reached turn %d" % turn)
        return self

    def resolve_top(self):
        """Both players pass once, which resolves the top Chain entry."""
        who = self.g.decision[0]
        self.do("%s PASS" % who, "%s PASS" % OTHER_OF[who])
        return self

    # ------------------------------------------------- state lookups ------

    def find(self, cid, n=0, zone=None, owner=None):
        objs = sorted((o for o in self.g.objects.values()
                       if o.card.cid == cid
                       and (zone is None or o.zone == zone)
                       and (owner is None or o.owner == owner)),
                      key=lambda o: o.oid)
        if len(objs) <= n:
            self.problems.append("no %s #%d in zone %s" % (cid, n, zone))
            return None
        return objs[n]

    def oid(self, cid, n=0, zone=None, owner=None):
        """The `#oid` token of the n-th instance of a card."""
        o = self.find(cid, n, zone, owner)
        return "#%d" % o.oid if o is not None else "#0"

    def pos(self, cid, player="A", n=0):
        """The 1-based hand position of the n-th copy of a card."""
        hits = [i for i, c in enumerate(self.g.zones[player]["hand"], 1)
                if c.card.cid == cid]
        if len(hits) <= n:
            self.problems.append("%s not in %s's hand" % (cid, player))
            return 0
        return hits[n]

    def play(self, cid, *targets, player="A"):
        """Play a card named by id, with the given target tokens."""
        words = ["%s PLAY %d" % (player, self.pos(cid, player))]
        words.extend(targets)
        return self.do(" ".join(words))

    def clear(self, limit=60):
        """Pass until the Chain is empty, resolving everything on it."""
        for _ in range(limit):
            g = self.g
            if g.over or g.decision is None or not g.chain:
                break
            if g.decision[1] != "priority":
                break
            self.auto()
        return self

    def cast(self, cid, *targets, player="A"):
        """Play a card and let it and everything it triggers resolve."""
        self.play(cid, *targets, player=player)
        return self.clear()

    def act(self, cid, index, *targets, player="A", n=0):
        line = "%s ACT %s %d" % (player, self.oid(cid, n, zone="field"), index)
        if targets:
            line += " " + " ".join(targets)
        return self.do(line)

    def use(self, cid, index, *targets, player="A", n=0):
        """Activate an ability and let it and its triggers resolve."""
        self.act(cid, index, *targets, player=player, n=n)
        return self.clear()

    def text(self):
        return mf(self.setup, self.script)


OTHER_OF = {"A": "B", "B": "A"}


def addr(group, name, runner, **checks):
    """Record a Runner's script, reporting any problem it noticed."""
    for p in runner.problems:
        FAILURES.append("%s/%s: %s" % (group, name, p))
    return add(group, name, runner.text(), **checks)


def R(seed=1, **setup_kw):
    return Runner(S(seed=seed, **setup_kw), seed=seed)


# ============================================================== layers =====

def build_layers():
    def lr(seed=1, **kw):
        kw.setdefault("spire", 40)
        kw.setdefault("cap_a", 10)
        kw.setdefault("cap_b", 10)
        kw.setdefault("deck_a", ["CIN-001*20"])
        kw.setdefault("deck_b", ["TID-001*20"])
        return R(seed=seed, **kw)

    # The worked layer example of SPEC.md 14.3: a printed 0/3 with two
    # counters, a setbody 0 1 and a modify 2 0 ends at 4/3.
    r = lr(2, hand_a=["LOM-003", "TID-022", "CIN-011"], field_a=["TOK-003"])
    t = r.oid("TOK-003", zone="field")
    r.cast("LOM-003", t).say("DUMP").cast("TID-022", t).say("DUMP")
    r.cast("CIN-011", t).say("DUMP")
    addr("layer", "order_spec_example", r,
         want=("SETBODY", "BUFF", "COUNTERS"))

    r = lr(3, hand_a=["CIN-011", "LOM-026"], field_a=["TOK-001"])
    t = r.oid("TOK-001", zone="field")
    r.cast("CIN-011", t).say("DUMP").cast("LOM-026", t).say("DUMP")
    addr("layer", "modify_before_setbody", r, want=("SETBODY", "BUFF"))

    r = lr(4, hand_a=["LOM-026", "DSK-025"], field_a=["TOK-001"])
    t = r.oid("TOK-001", zone="field")
    r.cast("LOM-026", t).say("DUMP").cast("DSK-025", t).say("DUMP")
    addr("layer", "two_setbody_records", r, want=("SETBODY",))

    r = lr(5, hand_a=["DSK-039", "CIN-011"], field_b=["CIN-023"])
    t = r.oid("CIN-023", zone="field")
    r.cast("DSK-039", t).say("DUMP")
    addr("layer", "swapstats_then_damage", r, want=("SWAP", "DAMAGE"))

    r = lr(6, hand_a=["DSK-039*2"], field_b=["LOM-028"])
    t = r.oid("LOM-028", zone="field")
    r.cast("DSK-039", t).say("DUMP").cast("DSK-039", t).say("DUMP")
    addr("layer", "swapstats_twice", r, want=("SWAP",))

    r = lr(7, field_a=["TID-038*3"], field_b=["LOM-024"])
    t = r.oid("LOM-024", zone="field")
    for n in range(3):
        r.use("TID-038", 1, t, n=n)
        r.say("DUMP")
    addr("layer", "negative_body_in_dump", r, want=("BUFF",))

    r = lr(8, hand_a=["CIN-011", "DSK-031"], field_a=["TOK-001"])
    t = r.oid("TOK-001", zone="field")
    r.cast("CIN-011", t).say("DUMP").cast("DSK-031", t).say("DUMP")
    addr("layer", "grant_then_strip", r, want=("GRANT", "STRIP"))

    r = lr(9, hand_a=["DSK-031", "CIN-011"], field_a=["TOK-001"])
    t = r.oid("TOK-001", zone="field")
    r.cast("DSK-031", t).say("DUMP").cast("CIN-011", t).say("DUMP")
    addr("layer", "strip_then_grant", r, want=("GRANT", "STRIP"))

    r = lr(10, hand_a=["DSK-031"], field_a=["TOK-001"],
           field_b=["LOM-005", "TOK-003"])
    r.say("DUMP").cast("DSK-031", r.oid("LOM-005", zone="field")).say("DUMP")
    addr("layer", "strip_aura_source", r, want=("STRIP",))

    r = lr(11, hand_a=["DSK-031"], field_b=["DSK-013", "DSK-003"])
    r.say("DUMP").cast("DSK-031", r.oid("DSK-013", zone="field")).say("DUMP")
    addr("layer", "strip_removes_granting_aura", r, want=("STRIP",))

    r = lr(12, field_a=["LOM-039", "CIN-010", "NEU-002", "TOK-001", "TOK-006"],
           field_b=["TOK-001"])
    r.say("DUMP").to_turn(2).say("DUMP")
    addr("layer", "aura_stack", r, want=("effect 1",))

    r = lr(13, field_a=["NEU-026*2", "TOK-001"], field_b=["NEU-026"])
    r.say("DUMP")
    addr("layer", "aura_other_filter", r, want=("field A",))

    r = lr(14, field_a=["LOM-006", "TOK-001"], field_b=["TOK-003"])
    r.say("DUMP").to_turn(2).say("DUMP").to_turn(3).say("DUMP")
    addr("layer", "aura_when_myturn", r)

    r = lr(15, opening=5, deck_a=["CIN-001*20"], field_a=["TID-031"],
           hand_a=["CIN-003*2"])
    r.say("DUMP").cast("CIN-003", "B").say("DUMP").cast("CIN-003", "B")
    r.say("DUMP")
    addr("layer", "aura_when_hand_size", r, want=("DAMAGE",))

    r = lr(16, hand_a=["CIN-016"], field_a=["TID-035", "TOK-001"])
    r.say("DUMP").cast("CIN-016").say("DUMP")
    addr("layer", "aura_when_unit_count", r, want=("CREATE",))

    r = lr(17, field_a=["DSK-022", "TOK-001"],
           ash_a=["CIN-001*7"], hand_a=["DSK-023"])
    r.say("DUMP").cast("DSK-023").say("DUMP")
    addr("layer", "aura_when_ash_size", r, want=("MILL",))

    r = lr(18, field_a=["NEU-023", "TOK-001"], ash_a=["CIN-001*6"])
    r.say("DUMP")
    addr("layer", "aura_when_ash_vanguard", r, want=("kw vanguard",))

    r = lr(19, field_a=["LOM-031", "TOK-006", "LOM-001"], hand_a=["LOM-012"])
    r.say("DUMP").cast("LOM-012").say("DUMP")
    addr("layer", "aura_when_two_plants", r, want=("CREATE",))

    r = lr(20, field_a=["LOM-015", "TOK-006*2"], hand_a=["LOM-012"])
    r.say("DUMP").cast("LOM-012").say("DUMP")
    addr("layer", "aura_counts_self", r, want=("CREATE",))

    r = lr(21, field_a=["TID-024"], field_b=["CIN-039", "TOK-001", "LOM-028"],
           hand_a=["LOM-003", "CIN-011"])
    t = r.oid("TOK-001", zone="field")
    r.say("DUMP").cast("CIN-011", t).say("DUMP").cast("LOM-003", t).say("DUMP")
    addr("layer", "aura_filter_uses_base", r, want=("GRANT", "BUFF"))

    r = lr(22, hand_a=["NEU-028"], field_a=["TOK-001"],
           field_b=["NEU-026", "TOK-003"])
    r.say("DUMP").cast("NEU-028", r.oid("NEU-026", zone="field")).say("DUMP")
    addr("layer", "aura_control_flips", r, want=("CONTROL",))

    r = lr(23, hand_a=["NEU-028", "CIN-011", "LOM-014"],
           field_b=["CIN-007", "TOK-001"])
    r.cast("NEU-028", r.oid("CIN-007", zone="field")).say("DUMP")
    r.to_phase("dusk-trigger", "A").say("DUMP").to_turn(2).say("DUMP")
    addr("layer", "turn_records_end_at_cleanup", r, want=("CONTROL",))

    r = lr(24, hand_a=["CIN-003", "CIN-011", "TID-003"],
           field_a=["CIN-031", "TID-013", "NEU-013"])
    r.say("LEGAL").cast("CIN-003", "B").say("DUMP")
    addr("layer", "cheaper_floors_at_zero", r, want=("PLAY A",))

    r = lr(25, hand_a=["CIN-011", "LOM-014", "TID-022", "NEU-008", "CIN-022"],
           field_a=["TOK-001", "LOM-039"], field_b=["TOK-003"])
    t = r.oid("TOK-001", zone="field")
    for cid in ("CIN-011", "LOM-014", "TID-022", "NEU-008", "CIN-022"):
        r.cast(cid, t)
    r.say("DUMP")
    addr("layer", "many_records_in_dump", r, want=("effect 6",))

    r = lr(26, hand_a=["LOM-003*2", "TID-022", "CIN-011", "DSK-039"],
           field_a=["TOK-003"])
    t = r.oid("TOK-003", zone="field")
    for cid in ("LOM-003", "LOM-003", "TID-022", "CIN-011", "DSK-039"):
        r.cast(cid, t)
        r.say("DUMP")
    addr("layer", "all_six_layers_at_once", r, want=("SWAP", "SETBODY"))


# ============================================================ triggers =====

def build_triggers():
    def tr(seed=1, **kw):
        kw.setdefault("spire", 40)
        kw.setdefault("cap_a", 10)
        kw.setdefault("cap_b", 10)
        kw.setdefault("deck_a", ["CIN-001*20"])
        kw.setdefault("deck_b", ["TID-001*20"])
        return R(seed=seed, **kw)

    r = tr(31, hand_a=["CIN-004"], field_b=["TOK-003", "LOM-007"])
    r.play("CIN-004").say("DUMP").resolve_top().say("DUMP").clear()
    r.say("DUMP")
    addr("trigger", "arrive_auto_target", r, want=("TRIGGER A",))

    r = tr(32, hand_a=["CIN-004"])
    r.play("CIN-004").say("DUMP").clear().say("DUMP")
    addr("trigger", "arrive_no_target", r, want=("TRIGGER-NO-TARGET",))

    r = tr(33, hand_a=["TID-003", "DSK-016", "DSK-002"],
           field_a=["NEU-011*3"])
    r.cast("TID-003", r.oid("NEU-011", 0, zone="field")).say("DUMP")
    r.cast("DSK-016", r.oid("NEU-011", 0, zone="field")).say("DUMP")
    r.cast("DSK-002", r.oid("NEU-011", 0, zone="field")).say("DUMP")
    addr("trigger", "leave_every_way", r, want=("BOUNCE", "EXILE", "DESTROY"))

    r = tr(34, hand_a=["DSK-002", "NEU-032"], field_a=["TID-012", "LOM-016"],
           field_b=["DSK-001", "DSK-015"])
    r.play("DSK-002", r.oid("DSK-015", zone="field")).resolve_top()
    r.say("DUMP").clear().say("DUMP").play("NEU-032").resolve_top()
    r.say("DUMP").clear().say("DUMP")
    addr("trigger", "dies_listeners", r, want=("DESTROY", "TRIGGER"))

    r = tr(35, hand_a=["CIN-016"], field_a=["LOM-002*2"])
    r.play("CIN-016").say("DUMP").resolve_top().say("DUMP").clear()
    r.say("DUMP")
    addr("trigger", "ally_arrive_counters_it", r, want=("COUNTERS",))

    r = tr(36, hand_a=["CIN-016"], field_b=["TID-023"], deck_b=["TID-001*20"])
    r.play("CIN-016").say("DUMP").clear().say("DUMP")
    addr("trigger", "enemy_arrive_mill", r, want=("MILL",))

    r = tr(37, hand_a=["NEU-032"], field_a=["CIN-018", "DSK-007", "DSK-036",
                                            "TOK-001*2"],
           field_b=["TOK-003"])
    r.play("NEU-032").say("DUMP").clear().say("DUMP")
    addr("trigger", "ally_dies_three_listeners", r, want=("TRIGGER",))

    r = tr(38, hand_a=["DSK-002*2"], field_a=["DSK-005"],
           field_b=["TOK-001", "TOK-003"])
    r.play("DSK-002", r.oid("TOK-001", zone="field")).resolve_top()
    r.say("DUMP").clear().say("DUMP")
    addr("trigger", "enemy_dies_counters", r, want=("COUNTERS",))

    r = tr(39, field_a=["LOM-029"], field_b=["LOM-029"])
    r.say("DUMP").to_turn(2).say("DUMP").to_turn(3).say("DUMP")
    addr("trigger", "turn_start_both_sides", r, want=("EMBERGAIN",))

    r = tr(40, field_a=["LOM-001", "TID-033"], field_b=["LOM-001"])
    r.to_turn(2).say("DUMP").to_turn(3).say("DUMP")
    addr("trigger", "your_turn_start", r, want=("COUNTERS",))

    r = tr(41, field_a=["NEU-004"], field_b=["NEU-004"])
    r.to_turn(2).say("DUMP")
    addr("trigger", "turn_end_both_sides", r, want=("SPIRE",))

    r = tr(42, field_a=["TID-021", "DSK-033"], deck_a=["CIN-003*4", "CIN-001*6"])
    r.to_turn(2).say("DUMP").to_turn(3).say("DUMP")
    addr("trigger", "your_turn_end", r, want=("MILL",))

    r = tr(43, field_a=["CIN-020", "CIN-033"], field_b=["TOK-003"])
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK %s %s" % (r.oid("CIN-020", zone="field"),
                             r.oid("CIN-033", zone="field")))
    r.say("DUMP").auto(2).say("DUMP").auto(2).say("DUMP").auto(6).say("DUMP")
    addr("trigger", "attacks_trigger", r, want=("ATTACK #",))

    r = tr(44, field_a=["CIN-007"], field_b=["TID-029", "TOK-003"])
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK " + r.oid("CIN-007", zone="field")).auto(2)
    r.do("B BLOCK %s:%s" % (r.oid("TID-029", zone="field"),
                            r.oid("CIN-007", zone="field")))
    r.say("DUMP").auto(2).say("DUMP").auto(4).say("DUMP")
    addr("trigger", "blocks_and_blocked", r, want=("BLOCK #", "BUFF"))

    r = tr(45, field_a=["CIN-021", "NEU-030"], field_b=["TOK-003"],
           hand_b=["CIN-001*3"], deck_b=["TID-001*10"])
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK %s %s" % (r.oid("CIN-021", zone="field"),
                             r.oid("NEU-030", zone="field")))
    r.auto(2).do("B BLOCK").say("DUMP").auto(2).say("DUMP").auto(4)
    r.say("DUMP")
    addr("trigger", "unblocked_triggers", r, want=("UNBLOCKED", "DISCARD"))

    r = tr(46, hand_a=["CIN-005*2", "CIN-003"], field_b=["LOM-024"])
    t = r.oid("LOM-024", zone="field")
    r.cast("CIN-005", t).say("DUMP").cast("CIN-005", t).say("DUMP")
    r.cast("CIN-003", t).say("DUMP")
    addr("trigger", "damaged_counters", r, want=("COUNTERS", "PREVENT"))

    r = tr(47, field_a=["DSK-036"], field_b=["TOK-003"])
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK " + r.oid("DSK-036", zone="field")).clear().auto(2)
    r.do("B BLOCK").clear().say("DUMP")
    r.to_phase("clash-damage", "A").say("DUMP").clear().say("DUMP")
    addr("trigger", "deals_damage_trigger", r, want=("TRIGGER",))

    r = tr(48, hand_a=["CIN-003*2", "TID-007"], field_a=["CIN-002*2"])
    r.play("CIN-003", "B").say("DUMP").clear().say("DUMP")
    r.cast("TID-007").say("DUMP").cast("CIN-003", "B").say("DUMP")
    addr("trigger", "you_play_rite", r, want=("BUFF",))

    r = tr(49, hand_b=["CIN-003*2"], field_a=["CIN-037", "NEU-014"],
           cap_b=10)
    r.auto(2).to_phase("main1", "B")
    r.cast("CIN-003", "A", player="B").say("DUMP")
    addr("trigger", "enemy_plays_rite", r, want=("TRIGGER A",))

    r = tr(50, hand_a=["TID-007", "TID-016"],
           field_a=["CIN-025", "TID-005", "CIN-025"])
    r.play("TID-007").say("DUMP").clear().say("DUMP")
    addr("trigger", "you_draw_three_listeners", r, want=("TRIGGER",))

    r = tr(51, hand_a=["DSK-004", "DSK-037"], field_a=["DSK-020"],
           field_b=["DSK-020", "NEU-014"])
    r.play("DSK-004").say("DUMP").clear().say("DUMP").cast("DSK-037")
    r.say("DUMP")
    addr("trigger", "spire_loss_both_sides", r, want=("COUNTERS", "SPIRE"))

    r = tr(52, field_a=["NEU-021", "CIN-006"], field_b=["TOK-001"],
           hand_a=["TID-008"])
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK %s %s" % (r.oid("NEU-021", zone="field"),
                             r.oid("CIN-006", zone="field")))
    r.clear().cast("TID-008", r.oid("NEU-021", zone="field")).say("DUMP")
    r.auto(2).do("B BLOCK").clear().to_phase("clash-end", "A").say("DUMP")
    r.clear().auto(2).say("DUMP")
    addr("trigger", "end_of_combat", r, want=("READY",))

    r = tr(53, hand_a=["CIN-016"], field_a=["LOM-002", "NEU-011"],
           field_b=["TID-023", "LOM-002"], deck_b=["TID-001*20"])
    r.play("CIN-016").say("DUMP").clear().say("DUMP")
    addr("trigger", "order_active_player_first", r,
         want=("TRIGGER A", "TRIGGER B"))

    r = tr(54, hand_a=["TID-016", "TID-007"],
           field_a=["CIN-025*2", "TID-005", "CIN-025"])
    r.play("TID-007").say("DUMP").clear().say("DUMP")
    r.cast("TID-016").say("DUMP")
    addr("trigger", "order_by_timestamp", r, want=("TRIGGER",))

    r = tr(55, hand_a=["CIN-028"], field_a=["CIN-006"])
    r.cast("CIN-028", r.oid("CIN-006", zone="field")).say("DUMP")
    r.to_phase("dusk-trigger", "A").say("DUMP").clear().say("DUMP")
    addr("trigger", "delayed_turn_end", r, want=("DELAY A turn-end",))

    r = tr(56, hand_a=["CIN-028", "TID-003"], field_a=["CIN-006"])
    r.cast("CIN-028", r.oid("CIN-006", zone="field"))
    r.cast("TID-003", r.oid("CIN-006", zone="field")).say("DUMP")
    r.to_phase("dusk-trigger", "A").say("DUMP").clear().say("DUMP")
    addr("trigger", "delayed_fizzles", r, want=("FIZZLE",))

    r = tr(57, hand_a=["CIN-005"], field_b=["LOM-024"])
    r.play("CIN-005", r.oid("LOM-024", zone="field")).say("DUMP")
    r.clear().say("DUMP")
    addr("trigger", "trigger_from_object_that_left", r, want=("DAMAGE",))

    r = tr(58, hand_a=["CIN-016", "DSK-002"], field_a=["LOM-002", "DSK-007"],
           field_b=["TOK-003"])
    r.cast("CIN-016").say("DUMP")
    r.cast("DSK-002", r.oid("TOK-001", zone="field")).say("DUMP")
    addr("trigger", "cascade_of_triggers", r, want=("TRIGGER",))



# ================================================================ fatal =====

def build_fatal():
    bad = sorted(f for f in os.listdir(os.path.join(HERE, "data", "bad"))
                 if f.endswith(".spire"))
    for f in bad:
        add("fatal", "baddb_" + f[:-6].split("_", 1)[1],
            "CARDS data/bad/%s\nSEED 1\nOPENING 0\nSTART\nDUMP\n" % f,
            want=("FATAL bad-database",))
    add("fatal", "baddb_missing_file",
        "CARDS data/nope.spire\nSEED 1\nSTART\n", want=("FATAL bad-database",))
    add("fatal", "baddb_directory",
        "CARDS data/bad\nSEED 1\nSTART\n", want=("FATAL bad-database",))
    add("fatal", "baddb_beats_unknown_card",
        "CARDS data/bad/07_duplicate_id.spire\nSEED 1\nDECK A ZZZ-001\nSTART\n",
        want=("FATAL bad-database",))
    add("fatal", "unknown_card_deck",
        "CARDS data/cards.spire\nSEED 1\nDECK A ZZZ-999\nSTART\n",
        want=("FATAL unknown-card",))
    add("fatal", "unknown_card_lowercase",
        "CARDS data/cards.spire\nSEED 1\nOPENING 0\nHAND B cin-001\nSTART\n",
        want=("FATAL unknown-card",))
    add("fatal", "unknown_card_rift_b",
        "CARDS data/cards.spire\nSEED 1\nDECK A CIN-001*3\nRIFT B CIN-001 "
        "TID-041\nSTART\nDUMP\n", want=("FATAL unknown-card",))
    add("fatal", "unknown_card_other_db",
        "CARDS data/extra.spire\nSEED 1\nFIELD A CIN-001\nSTART\n",
        want=("FATAL unknown-card",))
    add("fatal", "unknown_card_empty_db",
        "CARDS data/empty.spire\nSEED 1\nASH A EXT-001\nSTART\n",
        want=("FATAL unknown-card",))
    base = ["CARDS data/cards.spire", "SEED 1", "OPENING 0"]
    setups = [
        ("missing_cards", ["SEED 1", "START"]),
        ("missing_seed", ["CARDS data/cards.spire", "START"]),
        ("missing_start", base + ["DECK A CIN-001"]),
        ("duplicate_spire", base + ["SPIRE 5", "SPIRE 5", "START"]),
        ("duplicate_seed", base + ["SEED 2", "START"]),
        ("duplicate_first", base + ["FIRST A", "FIRST B", "START"]),
        ("duplicate_cap_a", base + ["CAP A 1", "CAP A 1", "START"]),
        ("duplicate_trace", base + ["TRACE none", "TRACE state", "START"]),
        ("unknown_word", base + ["LIFE 20", "START"]),
        ("action_before_start", base + ["A PASS", "START"]),
        ("lowercase_word", ["cards data/cards.spire", "SEED 1", "START"]),
        ("spire_zero", base + ["SPIRE 0", "START"]),
        ("spire_too_big", base + ["SPIRE 1000001", "START"]),
        ("opening_21", ["CARDS data/cards.spire", "SEED 1", "OPENING 21",
                        "START"]),
        ("maxcap_zero", base + ["MAXCAP 0", "START"]),
        ("maxcap_101", base + ["MAXCAP 101", "START"]),
        ("handmax_101", base + ["HANDMAX 101", "START"]),
        ("turnlimit_zero", base + ["TURNLIMIT 0", "START"]),
        ("turnlimit_big", base + ["TURNLIMIT 100001", "START"]),
        ("seed_2_64", ["CARDS data/cards.spire", "SEED 18446744073709551616",
                       "START"]),
        ("seed_negative", ["CARDS data/cards.spire", "SEED -1", "START"]),
        ("seed_plus", ["CARDS data/cards.spire", "SEED +1", "START"]),
        ("seed_hex", ["CARDS data/cards.spire", "SEED 0x10", "START"]),
        ("spire_two_args", base + ["SPIRE 5 6", "START"]),
        ("cap_b_101", base + ["CAP B 101", "START"]),
        ("cap_player_c", base + ["CAP C 1", "START"]),
        ("first_c", base + ["FIRST C", "START"]),
        ("shuffle_yes", base + ["SHUFFLE yes", "START"]),
        ("trace_all", base + ["TRACE all", "START"]),
        ("deck_no_entries", base + ["DECK A", "START"]),
        ("deck_player_c", base + ["DECK C CIN-001", "START"]),
        ("entry_count_zero", base + ["DECK A CIN-001*0", "START"]),
        ("entry_count_1001", base + ["DECK A CIN-001*1001", "START"]),
        ("entry_empty_count", base + ["HAND A CIN-001*", "START"]),
        ("entry_no_id", base + ["FIELD A *3", "START"]),
        ("entry_two_stars", base + ["ASH A CIN-001*2*2", "START"]),
        ("start_with_arg", base + ["START now"]),
        ("cards_no_path", ["CARDS", "SEED 1", "START"]),
        ("bad_setup_beats_bad_db", ["CARDS data/bad/01_unbalanced.spire",
                                    "SEED x", "START"]),
    ]
    for name, lines in setups:
        add("fatal", "setup_" + name, "\n".join(lines) + "\n",
            want=("FATAL bad-setup",))


# ================================================================= card =====

def build_card():
    db = load_database(DB)
    ids = sorted(db)
    houses = {}
    for cid in ids:
        houses.setdefault(cid[:3], []).append(cid)
    for house in ("TOK", "CIN", "TID", "LOM", "DSK", "NEU"):
        cids = houses[house]
        half = (len(cids) + 1) // 2
        for part, chunk in enumerate((cids[:half], cids[half:]), 1):
            if not chunk:
                continue
            setup = S(deck_a=["CIN-001"], deck_b=["CIN-001"])
            add("card", "all_%s_%d" % (house.lower(), part),
                mf(setup, ["CARD " + c for c in chunk]),
                want=("CARD BEGIN " + chunk[0],))
    setup = S(deck_a=["CIN-001"], deck_b=["CIN-001"])
    add("card", "unknown_ids", mf(setup, [
        "CARD ZZZ-999", "CARD cin-001", "CARD CIN-1", "CARD TOK-009",
        "CARD CIN-003", "CARD EXT-001", "CARD #3"]), want=("unknown",))
    add("card", "lexer_database", mf(
        S(cards="data/lexer.spire", field_a=["LEX-001"], field_b=["LEX-002"]),
        ["CARD LEX-001", "CARD LEX-002", "CARD LEX-003", "DUMP"]),
        want=("Odd (Name); with ;punctuation",))
    add("card", "extra_database", mf(
        S(cards="data/extra.spire", deck_a=["EXT-001"], deck_b=["EXT-001"]),
        ["CARD EXT-%03d" % i for i in range(1, 34)]),
        want=("CARD BEGIN EXT-018",))
    add("card", "empty_database", mf(
        S(cards="data/empty.spire"),
        ["CARD CIN-001", "DUMP", "LEGAL", "VAULT", "A PASS", "B PASS",
         "DUMP"]), want=("unknown",))
    r = R(spire=2, hand_a=["CIN-003"], deck_a=["CIN-001"], deck_b=["CIN-001"])
    r.cast("CIN-003", "B").say("CARD DSK-020", "CARD NEU-006", "DUMP")
    addr("card", "card_after_game_over", r, want=("RESULT A spire",))


# ================================================================ setup =====

def build_setup():
    add("setup", "minimal_defaults",
        "CARDS data/cards.spire\nSEED 1\nDECK A CIN-001*10\n"
        "DECK B TID-001*10\nSTART\nDUMP\nVAULT\nLEGAL\n", want=("SHUFFLE B",))
    add("setup", "first_b", mf(S(first="B", opening=3,
                                 deck_a=["CIN-001*5"], deck_b=["TID-001*5"]),
                               ["DUMP", "B PASS", "A PASS", "DUMP"]),
        want=("TURN 1 B",))
    add("setup", "opening_empty_a",
        mf(S(opening=2, deck_a=["CIN-001"], deck_b=["TID-001*4"]),
           ["DUMP", "A PASS", "LEGAL"]), want=("DRAW-EMPTY A", "RESULT B vault"),
        no_err=False)
    add("setup", "opening_empty_both",
        "CARDS data/cards.spire\nSEED 3\nSTART\nDUMP\nLEGAL\nA PASS\n",
        want=("RESULT draw vault",), no_err=False)
    add("setup", "opening_empty_b_first_b",
        mf(S(opening=3, first="B", deck_a=["CIN-001*3"], deck_b=["TID-001*2"]),
           ["DUMP"]), want=("DRAW-EMPTY B",))
    add("setup", "all_zones_placed", mf(S(
        cap_a=3, cap_b=7, deck_a=["CIN-001*2", "TID-002"], deck_b=["DSK-001"],
        hand_a=["CIN-003", "TOK-001*2"], hand_b=["NEU-002"],
        field_a=["LOM-039", "TOK-003", "CIN-001"], field_b=["LOM-005*2"],
        ash_a=["DSK-001*3"], ash_b=["TID-003"], rift_a=["NEU-032"],
        rift_b=["TOK-008*2"]), ["DUMP", "VAULT"]), want=("effect 1",))
    add("setup", "repeated_zone_lines", mf(S(
        head=["# leading comment", ""],
        deck_a=["CIN-001"], deck_b=["CIN-002"],
        tail=["DECK A CIN-003*2", "HAND A TID-001", "HAND A TID-002",
              "FIELD B TOK-001", "FIELD B TOK-002", "DECK B CIN-004"]),
        ["VAULT", "DUMP"]), want=("vault A 3",))
    add("setup", "comments_blank_crlf",
        "# a match file with comments\r\n\r\nCARDS data/cards.spire\r\n"
        "  # indented comment\r\nSEED   5\r\n\tOPENING\t1\r\nSHUFFLE off\r\n"
        "DECK A CIN-001*3\r\nDECK B TID-001*3\r\n\r\nSTART\r\n# script\r\n"
        "DUMP   \r\n  A   PASS  \r\n\r\nB PASS\r\nA ZAP\r\nDUMP\r\n",
        want=("ERR 17 bad-syntax",), no_err=False)
    add("setup", "leading_zeros", mf(S(
        seed="0007", spire="0030", opening="02", maxcap="05", handmax="003",
        turnlimit="09", deck_a=["CIN-001*004"], deck_b=["TID-001*0003"]),
        ["DUMP", "A PASS", "B PASS", "DUMP"]), want=("spire 30",))
    add("setup", "maxcap_progression", mf(
        S(maxcap=3, deck_a=["CIN-001*10"], deck_b=["CIN-001*10"]),
        ["A PASS", "B PASS", "A ATTACK", "A PASS", "B PASS", "A PASS",
         "B PASS"] + ["DUMP"]) + "", want=("EMBER A 1 1",))
    r = R(maxcap=2, deck_a=["CIN-001*10"], deck_b=["CIN-001*10"])
    for t in range(2, 7):
        r.to_turn(t).say("DUMP")
    addr("setup", "maxcap_cap_reached", r, want=("EMBER A 2 2",))
    r = R(handmax=2, opening=5, deck_a=["CIN-001*10"], deck_b=["TID-001*10"])
    r.to_turn(2).say("DUMP").to_turn(3).say("DUMP")
    addr("setup", "handmax_discard", r, want=("DISCARD A",))
    r = R(handmax=0, opening=3, deck_a=["CIN-001*10"], deck_b=["TID-001*10"])
    r.to_turn(3).say("DUMP")
    addr("setup", "handmax_zero", r, want=("DISCARD B",))
    r = R(cap_a=100, cap_b=100, maxcap=100, spire=1000000,
          deck_a=["CIN-001*3"], deck_b=["CIN-001*3"])
    r.say("DUMP").to_turn(2).say("DUMP")
    addr("setup", "extreme_values", r, want=("EMBER A 100 100",))
    r = R(seed="18446744073709551615", shuffle="on", opening=3,
          deck_a=["CIN-001", "CIN-002", "CIN-003", "CIN-004", "CIN-005"],
          deck_b=["TID-001"])
    r.say("VAULT", "DUMP")
    addr("setup", "seed_max", r, want=("SHUFFLE A",))
    r = R(field_a=["CIN-001", "LOM-006", "TOK-004"], field_b=["DSK-013",
                                                               "DSK-003"],
          deck_a=["CIN-001*5"], deck_b=["CIN-001*5"])
    r.say("DUMP", "LEGAL")
    r.to_phase("clash-attack", "A", "attackers").say("LEGAL")
    addr("setup", "field_not_settling_turn1", r, want=("CANATTACK",))


# ================================================================= prng =====

def build_prng():
    for seed in (0, 1, 7, 12345, 9876543210123):
        add("prng", "shuffle_seed_%d" % seed, mf(S(
            seed=seed, shuffle="on", deck_a=["CIN-%03d" % i
                                             for i in range(1, 13)],
            deck_b=["TID-%03d" % i for i in range(1, 9)]), ["VAULT"]),
            want=("VAULT BEGIN",))
    add("prng", "shuffle_sizes_zero_one", mf(
        S(seed=99, shuffle="on", deck_b=["LOM-001"]),
        ["VAULT", "DUMP"]), want=("SHUFFLE A",))
    add("prng", "shuffle_big_decks", mf(S(
        seed=424242, shuffle="on", opening=7,
        deck_a=["CIN-001*100", "TID-001*100", "LOM-001*100"],
        deck_b=["DSK-001*150", "NEU-002*150"]), ["VAULT", "DUMP"]),
        want=("vault B 293",))
    for seed in (3, 8, 77):
        r = R(seed=seed, hand_a=["TID-020*5"],
              field_b=["TOK-003", "LOM-024", "CIN-023", "TOK-007", "LOM-007"],
              field_a=["TOK-001"], cap_a=10)
        for _ in range(5):
            r.cast("TID-020").say("DUMP")
        addr("prng", "random_unit_seed_%d" % seed, r, want=("DAMAGE",))
    r = R(seed=5, shuffle="on", deck_a=["CIN-001*3", "CIN-002*3"],
          deck_b=["CIN-001*2"], hand_a=["TID-020*2"], cap_a=5)
    r.cast("TID-020").say("DUMP")
    r.to_turn(3).say("VAULT")
    addr("prng", "random_unit_no_candidates", r, want=("SPENT",))
    r = R(seed=31, shuffle="on", deck_a=["CIN-%03d" % i for i in range(1, 9)],
          deck_b=["TID-%03d" % i for i in range(1, 9)],
          hand_a=["TID-020*3"], field_b=["TOK-001*4"], cap_a=5)
    r.say("VAULT")
    for _ in range(3):
        r.cast("TID-020")
    r.say("DUMP")
    addr("prng", "random_unit_after_shuffle", r, want=("SHUFFLE B",))


# =============================================================== effects ====

def er(seed=1, **kw):
    """A standard sandbox: both players at 40 Spire with 10 Ember."""
    kw.setdefault("spire", 40)
    kw.setdefault("maxcap", 60)
    kw.setdefault("cap_a", 50)
    kw.setdefault("cap_b", 50)
    kw.setdefault("deck_a", ["CIN-001*20"])
    kw.setdefault("deck_b", ["TID-001*20"])
    return R(seed=seed, **kw)


def build_effects():
    r = er(101, hand_a=["CIN-003*3", "CIN-008", "CIN-035"],
           field_a=["TOK-003", "CIN-012"], field_b=["TOK-001", "LOM-007",
                                                    "TOK-003"])
    r.cast("CIN-003", "B").cast("CIN-003", "A")
    r.cast("CIN-003", r.oid("TOK-001", zone="field")).say("DUMP")
    r.cast("CIN-008").say("DUMP").cast("CIN-035").say("DUMP")
    addr("effect", "damage_players_and_units", r, want=("PREVENT", "DESTROY"))

    r = er(102, hand_a=["CIN-024", "CIN-029", "CIN-038", "DSK-035", "NEU-027"],
           field_a=["TOK-001*3", "LOM-028"], field_b=["TID-019", "LOM-007"],
           ash_a=["CIN-001*5"])
    big = r.oid("TID-019", zone="field")
    r.cast("CIN-024", big).say("DUMP").cast("CIN-038", big).say("DUMP")
    r.cast("CIN-029", r.oid("LOM-007", zone="field")).say("DUMP")
    r.cast("NEU-027", r.oid("LOM-028", zone="field"),
           r.oid("LOM-007", zone="field")).say("DUMP")
    r.cast("DSK-035", big).say("DUMP")
    addr("effect", "damage_computed_amounts", r, want=("DAMAGE",))

    r = er(103, field_a=["LOM-020"], field_b=["TOK-003", "CIN-023"],
           hand_a=["CIN-011"])
    t = r.oid("CIN-023", zone="field")
    r.cast("CIN-011", r.oid("LOM-020", zone="field"))
    r.use("LOM-020", 1, t).say("DUMP")
    addr("effect", "damage_edge_self", r, want=("DAMAGE",))

    r = er(104, hand_a=["DSK-002", "DSK-006", "NEU-032"],
           field_a=["DSK-024", "TOK-001"], field_b=["TOK-003", "DSK-024",
                                                    "TID-012"])
    r.cast("DSK-002", r.oid("TOK-003", zone="field")).say("DUMP")
    r.cast("DSK-006", r.oid("DSK-024", owner="B", zone="field")).say("DUMP")
    r.cast("NEU-032").say("DUMP")
    addr("effect", "destroy_and_tenacity", r, want=("TENACITY", "DESTROY"))

    r = er(105, hand_a=["DSK-014", "LOM-036", "DSK-032"],
           field_a=["TOK-001", "TID-012", "LOM-016", "TOK-003"])
    r.cast("DSK-014", r.oid("TID-012", zone="field")).say("DUMP")
    r.cast("LOM-036").say("DUMP").cast("DSK-032").say("DUMP")
    addr("effect", "sacrifice_effects", r, want=("SACRIFICE",))

    r = er(106, hand_a=["DSK-016", "TID-040"], field_a=["NEU-011"],
           field_b=["TOK-001", "NEU-011", "LOM-039", "DSK-024"])
    r.cast("DSK-016", r.oid("NEU-011", zone="field", owner="A")).say("DUMP")
    r.cast("TID-040").say("DUMP")
    addr("effect", "exile_effects", r, want=("EXILE",))

    r = er(107, hand_a=["TID-003", "TID-011", "TID-034", "TID-015"],
           field_a=["TOK-001", "NEU-011"],
           field_b=["CIN-023", "TOK-002", "LOM-028", "CIN-001", "TID-019"])
    r.cast("TID-015", r.oid("CIN-001", zone="field")).say("DUMP")
    r.cast("TID-003", r.oid("TOK-002", zone="field")).say("DUMP")
    r.cast("TID-034").say("DUMP").cast("TID-011").say("DUMP")
    addr("effect", "bounce_effects", r, want=("BOUNCE",))

    r = er(108, hand_a=["TID-007", "TID-016", "LOM-027", "DSK-037"],
           field_a=["TOK-001*2"], deck_a=["CIN-001*12"])
    r.cast("TID-007").cast("TID-016").cast("LOM-027", r.oid("TOK-001",
                                                            zone="field"))
    r.say("DUMP").cast("DSK-037").say("DUMP")
    addr("effect", "draw_effects", r, want=("DRAW A",))

    r = er(109, hand_a=["DSK-037"], deck_a=["CIN-001*2"])
    r.cast("DSK-037").say("DUMP")
    addr("effect", "draw_empty_vault_mid_effect", r,
         want=("DRAW-EMPTY A", "RESULT B vault"))

    r = er(110, hand_a=["DSK-027*2", "NEU-006*2", "TID-026"],
           hand_b=["CIN-001*3"], deck_a=["CIN-002*10"])
    r.cast("DSK-027").say("DUMP").cast("DSK-027").say("DUMP")
    r.cast("NEU-006").say("DUMP").cast("TID-026").say("DUMP")
    addr("effect", "discard_effects", r, want=("DISCARD B", "DISCARD A"))

    r = er(111, hand_a=["NEU-006"])
    r.cast("NEU-006").say("DUMP")
    addr("effect", "if_else_nothing", r, want=("SPENT",))

    r = er(112, hand_a=["DSK-023*3"], deck_a=["CIN-001*4"])
    r.cast("DSK-023").say("DUMP").cast("DSK-023").say("DUMP")
    r.cast("DSK-023").say("DUMP")
    addr("effect", "mill_empty_not_loss", r, want=("MILL A",))

    r = er(113, hand_a=["DSK-004", "DSK-019"], field_b=["TOK-001"],
           field_a=["NEU-014", "DSK-020"])
    r.cast("DSK-004").say("DUMP")
    r.cast("DSK-019", r.oid("TOK-001", zone="field")).say("DUMP")
    addr("effect", "spire_changes", r, want=("SPIRE B -2",))

    r = er(114, hand_a=["LOM-011", "CIN-009", "LOM-008*3"], maxcap=11,
           cap_a=9)
    r.cast("LOM-011").cast("CIN-009").say("DUMP").cast("LOM-008")
    r.say("DUMP").cast("LOM-008").say("DUMP")
    addr("effect", "ember_and_cap", r, want=("EMBERGAIN", "CAP A 1 11"))

    r = er(115, hand_a=["LOM-003", "LOM-017", "LOM-018", "LOM-034"],
           field_a=["LOM-001", "TOK-006", "LOM-016"], field_b=["TOK-001"])
    r.cast("LOM-003", r.oid("LOM-001", zone="field")).cast("LOM-017")
    r.say("DUMP").cast("LOM-018").say("DUMP").cast("LOM-034").say("DUMP")
    addr("effect", "counters_effects", r, want=("COUNTERS",))

    r = er(116, hand_a=["TID-008", "NEU-003", "NEU-019", "LOM-019"],
           field_a=["CIN-001*2"], field_b=["TOK-001"])
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK %s %s" % (r.oid("CIN-001", 0, zone="field"),
                             r.oid("CIN-001", 1, zone="field")))
    r.cast("NEU-019").say("DUMP").to_phase("main2", "A")
    r.cast("TID-008", r.oid("TOK-001", zone="field"))
    r.cast("LOM-019", r.oid("CIN-001", 0, zone="field"))
    r.say("DUMP").cast("NEU-003").say("DUMP")
    addr("effect", "ready_and_exhaust", r, want=("READY", "EXHAUST"))

    r = er(117, hand_a=["CIN-019", "DSK-019"], field_b=["TOK-003", "DSK-024"])
    r.play("CIN-019", r.oid("DSK-024", zone="field")).resolve_top()
    r.say("DUMP").clear().say("DUMP")
    r.cast("DSK-019", r.oid("TOK-003", zone="field")).say("DUMP")
    addr("effect", "doom_effects", r, want=("DOOM",))

    r = er(118, hand_a=["CIN-022", "LOM-014", "TID-028", "CIN-003*3"],
           field_a=["NEU-012", "NEU-020", "TOK-001"])
    t = r.oid("TOK-001", zone="field")
    r.cast("CIN-022", t).cast("LOM-014", t).say("DUMP")
    r.use("NEU-012", 1, t).use("NEU-020", 1, t).say("DUMP")
    r.cast("CIN-003", t).cast("TID-028").cast("CIN-003", "A")
    r.cast("CIN-003", "A").say("DUMP")
    addr("effect", "ward_and_shield", r, want=("WARD", "SHIELD", "PREVENT"))

    r = er(119, hand_a=["CIN-016", "NEU-005", "TID-017", "NEU-001",
                        "NEU-017", "DSK-034"],
           field_b=["TOK-003"])
    r.cast("CIN-016").cast("NEU-005").say("DUMP").cast("TID-017")
    r.cast("NEU-001").say("DUMP").cast("NEU-017")
    r.cast("DSK-034", r.oid("TOK-003", zone="field")).say("DUMP")
    addr("effect", "summon_and_conjure", r, want=("CREATE",))

    r = er(120, hand_a=["DSK-008", "DSK-018", "DSK-028", "CIN-017"],
           ash_a=["DSK-001", "CIN-005", "TID-012", "CIN-004", "LOM-028"],
           ash_b=["DSK-003", "TID-003"])
    r.cast("DSK-008", r.oid("LOM-028", zone="ash")).say("DUMP")
    r.cast("DSK-018").say("DUMP").cast("DSK-028").say("DUMP")
    r.cast("CIN-017").say("DUMP")
    addr("effect", "reanimate_and_recall", r, want=("RECALL", "ARRIVE"))

    r = er(121, hand_a=["CIN-034"], deck_a=["CIN-001*3", "CIN-003",
                                            "CIN-002*6"],
           hand_b=["NEU-022", "NEU-022"], deck_b=["CIN-003*3", "TID-007*5"],
           field_a=["TID-021"])
    r.cast("CIN-034").say("VAULT").to_turn(2).say("VAULT")
    r.to_phase("main1", "B")
    r.cast("NEU-022", player="B").say("VAULT", "DUMP")
    r.to_turn(3).say("VAULT", "DUMP")
    addr("effect", "dig_hit_and_miss", r, want=("DIG", "BOTTOM", "DIG-MISS"))

    r = er(122, hand_a=["NEU-022"], deck_a=["CIN-003", "CIN-001"])
    r.cast("NEU-022").say("VAULT").to_turn(2).to_phase("main1", "B")
    r.say("DUMP")
    addr("effect", "dig_short_vault", r, want=("DIG A", "BOTTOM A"))

    r = er(123, hand_a=["CIN-040*2"], field_b=["TOK-001"])
    r.cast("CIN-040").say("DUMP").cast("CIN-040").say("DUMP")
    addr("effect", "if_both_branches", r, want=("SPIRE B -2",))

    r = er(124, hand_a=["TID-027", "LOM-023", "DSK-011"],
           field_a=["TOK-001", "TOK-006"], field_b=["TOK-001", "TOK-003",
                                                    "TOK-006"])
    r.cast("TID-027").say("DUMP").cast("LOM-023").say("DUMP")
    r.cast("DSK-011").say("DUMP")
    addr("effect", "each_effects", r, want=("GRANT", "BUFF"))

    r = er(125, hand_a=["NEU-032"], field_a=["DSK-024", "TID-012", "LOM-016"],
           field_b=["DSK-024", "DSK-001", "DSK-007"])
    r.cast("NEU-032").say("DUMP")
    addr("effect", "each_destroy_with_tenacity", r, want=("TENACITY",))

    r = er(126, hand_a=["TID-036"], field_b=["LOM-028"], field_a=["TOK-001"])
    r.play("TID-036").clear().say("DUMP")
    addr("effect", "setbody_from_self", r, want=("SETBODY",))

    r = er(127, hand_a=["DSK-017", "CIN-008"],
           ash_a=["CIN-001*3", "CIN-003*2"], field_b=["TOK-001*2"])
    r.cast("DSK-017").say("DUMP")
    addr("effect", "cards_ash_count", r, want=("SPIRE A",))

    r = er(128, field_a=["DSK-020", "TID-018", "TID-037", "NEU-010",
                         "NEU-031", "DSK-030", "DSK-012"],
           hand_a=["CIN-001*3"], field_b=["TOK-003*2"])
    r.use("DSK-020", 2, r.oid("TOK-003", 0, zone="field")).say("DUMP")
    r.use("TID-018", 1).use("TID-037", 1).use("NEU-010", 1).say("DUMP")
    r.use("NEU-031", 1).use("DSK-030", 1).say("DUMP")
    r.use("DSK-012", 1, r.oid("TOK-003", 1, zone="field")).say("DUMP", "LEGAL")
    addr("effect", "activated_cost_kinds", r,
         want=("PAY A spire 2", "PAY A ember", "SACRIFICE"))

    r = er(129, field_a=["TID-018", "NEU-031"], hand_a=["NEU-019"])
    r.use("TID-018", 1).say("DUMP").cast("NEU-019").say("LEGAL")
    r.to_turn(3).say("DUMP", "LEGAL").use("TID-018", 1).say("DUMP")
    addr("effect", "once_resets_at_dawn", r, want=("once",))

    r = er(130, hand_a=["CIN-015", "TID-038"], field_a=["TID-038"],
           field_b=["TOK-001", "TOK-006", "LOM-024"])
    r.cast("CIN-015", r.oid("TOK-001", zone="field"),
           r.oid("TOK-006", zone="field")).say("DUMP")
    r.use("TID-038", 1, r.oid("LOM-024", zone="field")).say("DUMP")
    addr("effect", "two_targets_and_modify_neg", r, want=("BUFF",))

    r = er(131, hand_a=["TID-010", "NEU-028", "CIN-005"],
           field_b=["CIN-023", "LOM-005", "TOK-001"])
    r.cast("TID-010").say("DUMP")
    r.cast("NEU-028", r.oid("LOM-005", zone="field")).say("DUMP")
    r.to_phase("clash-attack", "A", "attackers").say("LEGAL")
    r.do("A ATTACK").to_turn(2).say("DUMP")
    addr("effect", "control_effects", r, want=("CONTROL", "settling"))

    r = er(132, hand_a=["TID-030", "LOM-019", "NEU-009", "TID-032", "DSK-010",
                        "NEU-008"],
           field_a=["TOK-001*3"], field_b=["TOK-001"])
    for i, cid in enumerate(["TID-030", "LOM-019"]):
        r.cast(cid, r.oid("TOK-001", i, zone="field", owner="A"))
    t = r.oid("TOK-001", 2, zone="field", owner="A")
    for cid in ["NEU-009", "TID-032", "DSK-010", "NEU-008"]:
        r.cast(cid, t)
    r.say("DUMP")
    addr("effect", "grant_many_keywords", r, want=("GRANT",))


# ================================================================ combat =====

def cr(seed=1, **kw):
    kw.setdefault("spire", 30)
    kw.setdefault("deck_a", ["CIN-001*20"])
    kw.setdefault("deck_b", ["TID-001*20"])
    return R(seed=seed, **kw)


def fight(r, attackers, blocks=(), who="A", mid_dump=True, end="main2"):
    """Declare attackers and blocks by card id and play the combat out."""
    d = OTHER_OF[who]
    r.to_phase("clash-attack", who, "attackers")
    if mid_dump:
        r.say("LEGAL")
    r.do(("%s ATTACK " % who + " ".join(attackers)).rstrip())
    if blocks or mid_dump:
        r.to_phase("clash-block", d, "blockers")
        if mid_dump:
            r.say("LEGAL")
        r.do(("%s BLOCK " % d + " ".join("%s:%s" % p for p in blocks))
             .rstrip())
        if mid_dump:
            r.say("DUMP")
    if end:
        r.to_phase(end, who)
        r.say("DUMP")
    return r


def build_combat():
    r = cr(201, field_a=["CIN-001", "TID-025", "CIN-036"], field_b=["TOK-003"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("CIN-001"), o("TID-025"), o("CIN-036")])
    addr("combat", "unblocked_vigil_siphon", r, want=("UNBLOCKED", "SPIRE A +"))

    r = cr(202, field_a=["CIN-006", "CIN-001"], field_b=["TOK-001", "CIN-006"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("CIN-006", owner="A"), o("CIN-001")],
          [(o("TOK-001"), o("CIN-006", owner="A")),
           (o("CIN-006", owner="B"), o("CIN-001"))])
    addr("combat", "riposte_step", r, want=("PHASE clash-riposte",))

    r = cr(203, field_a=["CIN-007"], field_b=["TOK-001", "TOK-006"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("CIN-007")], [(o("TOK-001"), o("CIN-007")),
                              (o("TOK-006"), o("CIN-007"))])
    addr("combat", "pierce_excess_to_player", r, want=("DAMAGE",))

    r = cr(204, field_a=["LOM-010"], field_b=["TOK-003", "TOK-006", "TOK-001"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("LOM-010")], [(o("TOK-003"), o("LOM-010")),
                              (o("TOK-006"), o("LOM-010")),
                              (o("TOK-001"), o("LOM-010"))])
    addr("combat", "three_blockers_pierce", r, want=("PREVENT",))

    r = cr(205, field_a=["LOM-028", "CIN-023"], field_b=["TOK-001",
                                                         "TID-009"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("CIN-023")], [(o("TOK-001"), o("CIN-023")),
                              (o("TID-009"), o("CIN-023"))])
    addr("combat", "excess_to_last_blocker", r, want=("BLOCK",))

    r = cr(206, field_a=["DSK-026"], field_b=["LOM-004", "TID-019", "TOK-001"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("DSK-026")], [(o("LOM-004"), o("DSK-026")),
                              (o("TID-019"), o("DSK-026")),
                              (o("TOK-001"), o("DSK-026"))])
    addr("combat", "venom_needs_one", r, want=("DOOM",))

    r = cr(207, field_a=["TID-002", "CIN-013", "TID-039"],
           field_b=["TOK-001", "TID-009", "LOM-033", "TOK-002"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("TID-002"), o("CIN-013"), o("TID-039")],
          [(o("TID-009"), o("TID-002")), (o("LOM-033"), o("CIN-013")),
           (o("TOK-002"), o("TID-039"))])
    addr("combat", "ghostwalk_and_skyhook", r, want=("BLOCK",))

    r = cr(208, field_a=["CIN-033", "NEU-015", "TOK-008", "CIN-001"],
           field_b=["CIN-023", "LOM-007", "TOK-001"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("CIN-033"), o("NEU-015")], [(o("TOK-001"), o("CIN-033"))])
    addr("combat", "relentless_shackled_siegework", r, want=("MUSTATTACK",))

    r = cr(209, field_a=["LOM-025", "NEU-018", "CIN-001"],
           field_b=["TOK-001", "TOK-003", "TOK-006"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("LOM-025"), o("NEU-018"), o("CIN-001")],
          [(o("TOK-001"), o("LOM-025")), (o("TOK-003"), o("NEU-018")),
           (o("TOK-006"), o("NEU-018"))])
    addr("combat", "provoke_satisfied", r, want=("MUSTBLOCK",))

    r = cr(210, field_a=["LOM-004", "LOM-009"], field_b=["CIN-012",
                                                         "DSK-024"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("LOM-004"), o("LOM-009")], [(o("CIN-012"), o("LOM-004")),
                                            (o("DSK-024"), o("LOM-009"))])
    addr("combat", "plating_siphon_venom_tenacity", r, want=("TENACITY",))

    r = cr(211, field_a=["TOK-001"], field_b=["TOK-003"],
           hand_a=["CIN-006", "CIN-001"], cap_a=5)
    r.cast("CIN-006").cast("CIN-001")
    r.to_phase("clash-attack", "A", "attackers").say("LEGAL", "DUMP")
    r.bad("A ATTACK " + r.oid("CIN-006", zone="field"), "illegal-attacker")
    fight(r, [r.oid("CIN-001", zone="field"), r.oid("TOK-001", zone="field")],
          mid_dump=False)
    addr("combat", "settling_and_vanguard", r, no_err=False,
         want=("ATTACK #",))

    r = cr(212, field_a=["CIN-004", "CIN-001"], field_b=["TOK-001", "TOK-003"],
           hand_a=["TID-003"], hand_b=["TID-003"], cap_a=5, cap_b=5)
    o = lambda c, **k: r.oid(c, zone="field", **k)
    a1, a2 = o("CIN-004"), o("CIN-001")
    b1, b2 = o("TOK-001"), o("TOK-003")
    fight(r, [a1, a2], [(b1, a1), (b2, a2)], end=None)
    r.cast("TID-003", b1).do("A PASS").cast("TID-003", a2, player="B")
    r.to_phase("main2", "A").say("DUMP")
    addr("combat", "removed_from_combat_by_bounce", r, want=("BOUNCE",))

    r = cr(213, field_b=["CIN-001", "TOK-001"], field_a=["TOK-003"],
           hand_a=["NEU-028"], cap_a=5)
    o = lambda c, **k: r.oid(c, zone="field", **k)
    r.cast("NEU-028", o("CIN-001")).say("DUMP")
    fight(r, [o("CIN-001")])
    r.to_turn(2, "clash-attack", "B", "attackers").say("LEGAL", "DUMP")
    addr("combat", "stolen_vanguard_attacks", r, want=("CONTROL",))

    r = cr(214, field_a=["TOK-003", "TOK-006", "CIN-001"],
           field_b=["TOK-001"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("TOK-003"), o("TOK-006"), o("CIN-001")],
          [(o("TOK-001"), o("TOK-003"))])
    addr("combat", "zero_edge_assigns_nothing", r, want=("UNBLOCKED",))

    r = cr(215, field_a=["LOM-030", "CIN-006"], field_b=["CIN-036",
                                                         "CIN-039"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    fight(r, [o("LOM-030"), o("CIN-006")], [(o("CIN-036"), o("LOM-030")),
                                            (o("CIN-039"), o("CIN-006"))])
    addr("combat", "riposte_both_sides", r, want=("PHASE clash-riposte",))

    r = cr(216, field_a=["CIN-020", "NEU-021", "DSK-036", "CIN-007"],
           field_b=["TID-029", "TOK-003"], hand_a=["CIN-028"], cap_a=5)
    o = lambda c, **k: r.oid(c, zone="field", **k)
    r.cast("CIN-028", o("DSK-036"))
    fight(r, [o("CIN-020"), o("NEU-021"), o("DSK-036"), o("CIN-007")],
          [(o("TID-029"), o("CIN-007")), (o("TOK-003"), o("DSK-036"))])
    r.to_turn(2).say("DUMP")
    addr("combat", "combat_trigger_mix", r, want=("UNBLOCKED", "RESOLVE"))

    r = cr(217, field_a=["CIN-001*2"], field_b=["TOK-001"],
           spire=3)
    o = lambda c, n=0: r.oid(c, n, zone="field")
    fight(r, [o("CIN-001", 0), o("CIN-001", 1)], end=None)
    for _ in range(10):
        if r.g.over:
            break
        r.auto()
    r.say("DUMP")
    addr("combat", "lethal_combat", r, want=("RESULT A spire",))

    r = cr(218, field_b=["CIN-001", "TID-006"], field_a=["TOK-007",
                                                         "NEU-018"])
    r.to_turn(2, "main1", "B")
    o = lambda c: r.oid(c, zone="field")
    fight(r, [o("CIN-001"), o("TID-006")],
          [(o("TOK-007"), o("TID-006")), (o("NEU-018"), o("CIN-001"))],
          who="B")
    addr("combat", "player_b_attacks", r, want=("BLOCK",))

    r = cr(219, field_a=["CIN-036", "LOM-028"], field_b=["TOK-001"])
    o = lambda c: r.oid(c, zone="field")
    fight(r, [o("CIN-036"), o("LOM-028")])
    r.to_turn(3).say("DUMP")
    fight(r, [o("CIN-036")])
    addr("combat", "vigil_stays_ready", r)

    r = cr(220, field_a=["TOK-005", "CIN-001"], field_b=["TID-019",
                                                         "LOM-004"],
           hand_b=["CIN-022"], cap_b=3)
    o = lambda c: r.oid(c, zone="field")
    fight(r, [o("TOK-005"), o("CIN-001")],
          [(o("TID-019"), o("TOK-005")), (o("LOM-004"), o("CIN-001"))],
          end=None)
    r.to_phase("clash-block", "B")
    r.cast("CIN-022", o("TID-019"), player="B")
    r.to_phase("main2", "A").say("DUMP")
    addr("combat", "venom_prevented_by_ward", r, want=("PREVENT",))

    r = cr(221, field_a=["CIN-039"], field_b=["TOK-003", "LOM-039"])
    o = lambda c: r.oid(c, zone="field")
    fight(r, [o("CIN-039")], [(o("TOK-003"), o("CIN-039"))])
    addr("combat", "pierce_through_plating", r)

    r = cr(222, field_a=["CIN-001", "TID-025"], field_b=["TOK-003"],
           hand_a=["TID-008"], cap_a=3)
    o = lambda c: r.oid(c, zone="field")
    r.cast("TID-008", o("TOK-003"))
    fight(r, [o("CIN-001"), o("TID-025")])
    addr("combat", "exhausted_cannot_block", r, want=("EXHAUST",))


# ================================================================= chain =====

def build_chain():
    r = er(301, hand_a=["CIN-005"], hand_b=["TID-003"], field_b=["LOM-028"])
    t = r.oid("LOM-028", zone="field")
    r.play("CIN-005", t).say("DUMP", "LEGAL").do("A PASS").say("LEGAL")
    r.play("TID-003", t, player="B").say("DUMP").do("B PASS", "A PASS")
    r.say("DUMP").clear().say("DUMP")
    addr("chain", "respond_and_fizzle", r, want=("FIZZLE",))

    r = er(302, hand_a=["CIN-005", "CIN-001", "CIN-003", "TID-007"],
           field_b=["TOK-001"])
    t = r.oid("TOK-001", zone="field")
    r.play("CIN-005", t).bad("A PLAY %d" % r.pos("CIN-001"), "bad-timing")
    r.bad("A PLAY %d" % r.pos("TID-007"), "bad-timing")
    r.play("CIN-003", t).say("DUMP").clear().say("DUMP")
    addr("chain", "swift_on_own_chain", r, no_err=False, want=("FIZZLE",))

    r = er(303, hand_a=["DSK-002", "TID-004"], hand_b=["TID-004"],
           field_b=["LOM-028"])
    r.play("DSK-002", r.oid("LOM-028", zone="field")).do("A PASS")
    r.play("TID-004", "~1", player="B").do("B PASS")
    r.play("TID-004", "~2").say("DUMP", "LEGAL").clear().say("DUMP")
    addr("chain", "negate_the_negate", r, want=("NEGATE ~2", "DESTROY"))

    r = er(304, field_a=["CIN-014"], hand_a=["CIN-004"],
           hand_b=["TID-004*3"], field_b=["TOK-003", "TOK-001"])
    r.act("CIN-014", 1, r.oid("TOK-003", zone="field")).do("A PASS")
    r.play("TID-004", "~1", player="B").clear().say("DUMP")
    r.play("CIN-004").do("A PASS")
    r.play("TID-004", "~3", player="B").clear().say("DUMP")
    addr("chain", "negate_ability_and_unit", r, want=("NEGATE ~1", "SPENT"))

    r = er(305, hand_a=["CIN-004"], hand_b=["TID-004"],
           field_b=["TOK-003", "TOK-001"])
    r.play("CIN-004").do("A PASS", "B PASS").say("DUMP").do("A PASS")
    top = "~%d" % r.g.chain[-1].cid
    r.play("TID-004", top, player="B").say("DUMP").clear().say("DUMP")
    addr("chain", "negate_trigger", r, want=("NEGATE",))

    r = er(306, hand_a=["CIN-003*3", "CIN-011", "LOM-014"],
           hand_b=["CIN-003*3", "TID-028", "CIN-022"],
           field_a=["TOK-001"], field_b=["TOK-003"])
    ta, tb = r.oid("TOK-001", zone="field"), r.oid("TOK-003", zone="field")
    r.play("CIN-003", tb).do("A PASS").play("CIN-003", ta, player="B")
    r.do("B PASS").play("CIN-011", ta).do("A PASS")
    r.play("CIN-022", tb, player="B").do("B PASS").play("LOM-014", ta)
    r.do("A PASS").play("TID-028", player="B").do("B PASS")
    r.play("CIN-003", "B").do("A PASS").play("CIN-003", "A", player="B")
    r.say("DUMP", "LEGAL").clear().say("DUMP")
    addr("chain", "deep_chain_both_players", r, want=("RESOLVE",))

    r = er(307, hand_b=["CIN-003"], field_a=["CIN-037", "NEU-014"])
    r.do("A PASS").play("CIN-003", "A", player="B").say("DUMP", "LEGAL")
    r.clear().say("DUMP")
    addr("chain", "trigger_returns_priority_to_active", r,
         want=("TRIGGER A",))

    r = er(308, hand_a=["CIN-003"], field_b=["TOK-001", "CIN-014"])
    r.to_turn(2, "main1", "B")
    r.act("CIN-014", 1, r.oid("TOK-001", zone="field"), player="B")
    r.do("B PASS").play("CIN-003", r.oid("CIN-014", zone="field"))
    r.say("DUMP").clear().say("DUMP")
    addr("chain", "respond_in_opponents_turn", r, want=("ACTIVATE B",))

    r = er(309, field_a=["CIN-027", "NEU-020"], field_b=["CIN-001", "TOK-001"])
    o = lambda c: r.oid(c, zone="field")
    r.to_phase("clash-attack", "A", "attackers").do("A ATTACK")
    r.to_turn(2, "clash-attack", "B", "attackers")
    r.do("B ATTACK %s %s" % (o("CIN-001"), o("TOK-001")))
    r.say("LEGAL").do("B PASS")
    r.say("LEGAL").act("CIN-027", 1, o("CIN-001"))
    r.clear().to_phase("clash-block", "A", "blockers")
    r.do("A BLOCK", "B PASS").act("NEU-020", 1, o("NEU-020"), player="A")
    r.clear().say("DUMP")
    r.to_phase("main2", "B").say("DUMP")
    addr("chain", "abilities_during_combat", r, want=("ACTIVATE A",))

    r = er(310, hand_a=["TID-004", "CIN-003"], field_b=["TOK-001"])
    r.play("CIN-003", "B").say("LEGAL")
    r.bad("A PLAY %d ~2" % r.pos("TID-004"), "illegal-target")
    r.play("TID-004", "~1").say("DUMP").clear().say("DUMP")
    addr("chain", "chained_target_rules", r, no_err=False,
         want=("NEGATE ~1",))

    r = er(311, hand_a=["CIN-003", "TID-004"], hand_b=["TID-004"])
    r.play("CIN-003", "B").play("TID-004", "~1").do("A PASS")
    r.play("TID-004", "~1", player="B").say("DUMP").clear().say("DUMP")
    addr("chain", "negate_target_already_gone", r, want=("FIZZLE",))

    r = er(312, hand_a=["CIN-015", "TID-003"], field_b=["TOK-001", "TOK-006"])
    a, b = r.oid("TOK-001", zone="field"), r.oid("TOK-006", zone="field")
    r.play("CIN-015", a, b).play("TID-003", a).clear().say("DUMP")
    addr("chain", "partial_target_loss", r, want=("DAMAGE",))

    r = er(313, hand_a=["CIN-005", "TID-032"], hand_b=["DSK-010"],
           field_b=["TOK-003"])
    t = r.oid("TOK-003", zone="field")
    r.play("CIN-005", t).do("A PASS").play("DSK-010", t, player="B")
    r.clear().say("DUMP")
    addr("chain", "spectral_fizzle", r, want=("FIZZLE",))

    r = er(314, hand_a=["CIN-003", "LOM-003"], field_b=["TOK-001"],
           field_a=["TOK-006"])
    r.play("LOM-003", r.oid("TOK-006", zone="field"))
    r.play("CIN-003", r.oid("TOK-001", zone="field"))
    r.do("A PASS").do("B PASS").say("DUMP").do("A PASS", "B PASS")
    r.say("DUMP").do("A PASS", "B PASS").say("DUMP")
    addr("chain", "pass_counter_progression", r, want=("PASS B",))

    r = er(315, hand_a=["CIN-001", "TID-001"], hand_b=["CIN-003"],
           deck_a=["CIN-002*20"])
    r.play("CIN-001").say("LEGAL").do("A PASS").say("LEGAL")
    r.play("CIN-003", "A", player="B").clear().say("DUMP")
    r.to_phase("main2", "A").play("TID-001").clear().say("DUMP")
    addr("chain", "units_on_chain", r, want=("ARRIVE",))


# ================================================================= errors ====

def build_errors():
    r = er(401, hand_a=["CIN-003", "CIN-016", "CIN-001"])
    for line in ["X PASS", "a PASS", "A pass", "A PASS now", "A PLAY",
                 "A PLAY x", "A PLAY -1", "A PLAY +1", "A PLAY 1 C",
                 "A PLAY 1 #", "A PLAY 1 #x", "A PLAY 1 ~", "A PLAY 1 b",
                 "A ACT 3 1", "A ACT #3", "A ACT #3 x", "A ACT #-3 1",
                 "A ATTACK 3", "A ATTACK #3#4", "A BLOCK #1", "A BLOCK #1:",
                 "A BLOCK #1:#2:#3", "A BLOCK :#2",
                 "A PLAY 18446744073709551616",
                 "A PLAY 1 #18446744073709551616", "DUMP x", "LEGAL 1",
                 "VAULT x", "CARD", "CARD A B", "A CONCEDE now", "A",
                 "START", "SEED 1", "PASS", "A DRAW", "A PLAY 1.0",
                 "A PLAY 0x1"]:
        r.bad(line, "bad-syntax")
    r.say("# a comment line", "", "   ", "\t# tabbed comment")
    r.bad("A PLAY 18446744073709551615", "no-such-card")
    r.bad("A PLAY 0", "no-such-card")
    r.bad("A PLAY 4", "no-such-card")
    r.do("A PLAY 001 A").say("DUMP")
    addr("error", "bad_syntax_catalogue", r, no_err=False)

    r = er(402, hand_a=["CIN-003"], hand_b=["CIN-003"])
    r.bad("B PASS", "not-your-turn").bad("B PLAY 1 A", "not-your-turn")
    r.bad("B CONCEDE", "not-your-turn").bad("A ATTACK", "wrong-decision")
    r.bad("A BLOCK", "wrong-decision").bad("B ATTACK", "not-your-turn")
    r.do("A PASS").bad("A PASS", "not-your-turn").do("B PASS")
    r.bad("A PASS", "wrong-decision").bad("A PLAY 1 B", "wrong-decision")
    r.bad("A ACT #1 1", "wrong-decision").bad("B BLOCK", "not-your-turn")
    r.bad("A BLOCK", "wrong-decision").do("A ATTACK")
    r.say("LEGAL")
    addr("error", "turn_and_decision_errors", r, no_err=False)

    r = er(403, field_a=["CIN-001"], field_b=["TOK-001"])
    o = lambda c: r.oid(c, zone="field")
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK " + o("CIN-001")).auto(2)
    r.bad("B PASS", "wrong-decision").bad("A BLOCK", "not-your-turn")
    r.bad("B ATTACK", "wrong-decision").bad("B PLAY 1", "wrong-decision")
    r.do("B BLOCK").say("DUMP")
    addr("error", "decision_errors_in_combat", r, no_err=False)

    r = er(404, hand_a=["CIN-003", "CIN-005", "CIN-015", "LOM-028", "DSK-014",
                        "DSK-008", "TID-004", "CIN-016", "CIN-001"],
           field_a=["TOK-001", "NEU-002"], field_b=["DSK-021", "TOK-003"],
           ash_b=["CIN-001"], ash_a=["CIN-005"], cap_a=6)
    my, sp = r.oid("TOK-001", zone="field"), r.oid("DSK-021", zone="field")
    relic, en = r.oid("NEU-002", zone="field"), r.oid("TOK-003", zone="field")
    hand_obj = r.oid("CIN-001", zone="hand")
    p = r.pos
    r.bad("A PLAY %d" % p("CIN-003"), "bad-target-count")
    r.bad("A PLAY %d A B" % p("CIN-003"), "bad-target-count")
    r.bad("A PLAY %d A" % p("CIN-001"), "bad-target-count")
    r.bad("A PLAY %d #999" % p("CIN-003"), "illegal-target")
    r.bad("A PLAY %d ~1" % p("CIN-003"), "illegal-target")
    r.bad("A PLAY %d %s" % (p("CIN-003"), sp), "illegal-target")
    r.bad("A PLAY %d %s" % (p("CIN-003"), relic), "illegal-target")
    r.bad("A PLAY %d %s" % (p("CIN-003"), hand_obj), "illegal-target")
    r.bad("A PLAY %d A" % p("CIN-005"), "illegal-target")
    r.bad("A PLAY %d %s %s" % (p("CIN-015"), my, my), "illegal-target")
    r.bad("A PLAY %d %s" % (p("DSK-014"), en), "illegal-target")
    r.bad("A PLAY %d %s" % (p("DSK-008"),
                            r.oid("CIN-001", zone="ash")), "illegal-target")
    r.bad("A PLAY %d %s" % (p("DSK-008"),
                            r.oid("CIN-005", zone="ash")), "illegal-target")
    r.bad("A PLAY %d ~1" % p("TID-004"), "illegal-target")
    r.bad("A PLAY %d" % p("LOM-028"), "cannot-afford")
    r.bad("A PLAY %d #999" % p("CIN-016"), "bad-target-count")
    r.say("LEGAL").do("A PLAY %d %s" % (p("CIN-005"), en)).say("DUMP")
    addr("error", "play_errors", r, no_err=False)

    r = er(405, hand_a=["CIN-001", "CIN-005", "TID-007"], hand_b=["CIN-001",
                                                                  "CIN-003"],
           field_b=["TOK-001"])
    r.do("A PASS")
    r.bad("B PLAY 1", "bad-timing").bad("B PLAY 1 A", "bad-timing")
    r.do("B PASS").to_phase("clash-attack", "A", "attackers").do("A ATTACK")
    r.to_phase("main2", "A")
    r.do("A PLAY %d" % r.pos("CIN-001")).bad(
        "A PLAY %d" % r.pos("TID-007"), "bad-timing")
    r.bad("A PLAY %d %s" % (r.pos("CIN-005"), "#999"), "bad-timing")
    r.clear().to_phase("dusk-trigger", "A")
    r.bad("A PLAY %d" % r.pos("TID-007"), "bad-timing").say("DUMP")
    addr("error", "bad_timing_cases", r, no_err=False)

    r = er(406, field_a=["CIN-014", "TID-018", "DSK-030", "LOM-020", "NEU-002",
                         "TID-037"],
           hand_a=["DSK-031", "CIN-027", "TID-008"], field_b=["TID-038",
                                                              "TOK-001"],
           cap_a=6)
    o = lambda c: r.oid(c, zone="field")
    r.bad("A ACT #999 1", "no-such-object")
    r.bad("A ACT %s 1" % o("TID-038"), "no-such-object")
    r.bad("A ACT %s 1" % r.oid("CIN-027", zone="hand"), "no-such-object")
    r.bad("A ACT %s 0" % o("CIN-014"), "no-such-ability")
    r.bad("A ACT %s 2" % o("CIN-014"), "no-such-ability")
    r.bad("A ACT %s 1" % o("NEU-002"), "no-such-ability")
    r.bad("A ACT %s 1" % o("CIN-014"), "bad-target-count")
    r.bad("A ACT %s 1 A" % o("CIN-014"), "illegal-target")
    r.bad("A ACT %s 1 %s %s" % (o("CIN-014"), o("TOK-001"), o("TOK-001")),
          "bad-target-count")
    r.do("A ACT %s 1" % o("TID-018")).clear()
    r.bad("A ACT %s 1" % o("TID-018"), "cost-unpayable")
    r.do("A ACT %s 1" % o("TID-037")).clear()
    r.bad("A ACT %s 1" % o("TID-037"), "cost-unpayable")
    r.cast("CIN-027")
    r.bad("A ACT %s 1 %s" % (o("CIN-027"), o("TOK-001")), "cost-unpayable")
    r.cast("DSK-031", o("LOM-020"))
    r.bad("A ACT %s 1 %s" % (o("LOM-020"), o("TOK-001")), "no-such-ability")
    r.bad("A ACT %s 1 %s" % (o("CIN-014"), o("TOK-001")), "cost-unpayable")
    r.bad("A ACT %s 1" % o("DSK-030"), "cost-unpayable")
    r.say("DUMP", "LEGAL")
    addr("error", "act_errors", r, no_err=False)

    r = er(413, field_a=["DSK-030"], cap_a=6)
    o = lambda c: r.oid(c, zone="field")
    r.bad("A ACT %s 1" % o("DSK-030"), "cost-unpayable").say("LEGAL")
    r.to_turn(3).say("LEGAL").use("DSK-030", 1).say("DUMP")
    addr("error", "discard_cost_needs_cards", r, no_err=False,
         want=("DISCARD A",))

    r = er(407, field_a=["CIN-001", "CIN-033", "TOK-008", "NEU-002"],
           field_b=["TOK-001"], hand_a=["CIN-006", "LOM-019"])
    o = lambda c: r.oid(c, zone="field")
    r.cast("CIN-006").cast("LOM-019", o("CIN-001"))
    r.to_phase("clash-attack", "A", "attackers").say("LEGAL")
    for line, kind in [
            ("A ATTACK %s %s" % (o("CIN-033"), o("CIN-033")),
             "duplicate-attacker"),
            ("A ATTACK %s %s %s" % (o("CIN-033"), o("TOK-008"), o("TOK-008")),
             "duplicate-attacker"),
            ("A ATTACK %s" % o("TOK-008"), "illegal-attacker"),
            ("A ATTACK %s %s" % (o("CIN-033"), o("CIN-006")),
             "illegal-attacker"),
            ("A ATTACK %s %s" % (o("CIN-033"), o("CIN-001")),
             "illegal-attacker"),
            ("A ATTACK %s %s" % (o("CIN-033"), o("NEU-002")),
             "illegal-attacker"),
            ("A ATTACK %s %s" % (o("CIN-033"), o("TOK-001")),
             "illegal-attacker"),
            ("A ATTACK #999", "illegal-attacker"),
            ("A ATTACK #1", "illegal-attacker"),
            ("A ATTACK", "missing-required-attacker")]:
        r.bad(line, kind)
    r.do("A ATTACK " + o("CIN-033")).say("DUMP")
    addr("error", "attack_errors", r, no_err=False)

    r = er(408, field_a=["LOM-025", "TID-002", "CIN-001"],
           field_b=["TOK-001", "CIN-023", "LOM-033", "TOK-003", "NEU-002"],
           hand_b=["TID-008"])
    o = lambda c: r.oid(c, zone="field")
    r.do("A PASS").play("TID-008", o("TOK-003"), player="B").clear()
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK %s %s" % (o("LOM-025"), o("TID-002")))
    r.to_phase("clash-block", "B", "blockers").say("LEGAL")
    lp, gw = o("LOM-025"), o("TID-002")
    for line, kind in [
            ("B BLOCK %s:%s %s:%s" % (o("TOK-001"), lp, o("TOK-001"), gw),
             "duplicate-blocker"),
            ("B BLOCK %s:%s" % (o("CIN-023"), lp), "illegal-blocker"),
            ("B BLOCK %s:%s" % (o("TOK-003"), lp), "illegal-blocker"),
            ("B BLOCK %s:%s" % (o("TOK-001"), gw), "illegal-blocker"),
            ("B BLOCK %s:%s" % (o("NEU-002"), lp), "illegal-blocker"),
            ("B BLOCK %s:%s" % (o("TOK-001"), o("CIN-001")),
             "illegal-blocker"),
            ("B BLOCK %s:%s" % (o("CIN-001"), lp), "illegal-blocker"),
            ("B BLOCK #999:%s" % lp, "illegal-blocker"),
            ("B BLOCK", "missing-required-block"),
            ("B BLOCK %s:%s" % (o("LOM-033"), gw), "missing-required-block")]:
        r.bad(line, kind)
    r.do("B BLOCK %s:%s %s:%s" % (o("TOK-001"), lp, o("LOM-033"), gw))
    r.say("DUMP")
    addr("error", "block_errors", r, no_err=False)

    r = er(409, field_a=["LOM-025"], field_b=["TOK-001", "TOK-006"])
    o = lambda c: r.oid(c, zone="field")
    r.to_phase("clash-attack", "A", "attackers").do("A ATTACK " +
                                                    o("LOM-025"))
    r.to_phase("clash-block", "B", "blockers")
    r.do("B BLOCK %s:%s" % (o("TOK-006"), o("LOM-025"))).say("DUMP")
    addr("error", "provoke_one_blocker_enough", r)

    r = er(410, spire=2, hand_a=["CIN-003*2"], hand_b=["CIN-003"])
    r.cast("CIN-003", "B")
    r.bad("A PASS", "game-over").bad("B PASS", "game-over")
    r.bad("A CONCEDE", "game-over").bad("Z PASS", "bad-syntax")
    r.bad("A PLAY", "bad-syntax").bad("A ATTACK #1", "game-over")
    r.say("DUMP", "LEGAL", "VAULT", "CARD CIN-003")
    addr("error", "after_game_over", r, no_err=False)

    r = er(411, field_a=["TID-018"], hand_a=["CIN-001*3"],
           field_b=["TOK-001"], hand_b=["CIN-003"])
    r.do("A PASS").play("CIN-003", r.oid("TID-018", zone="field"),
                        player="B")
    r.bad("A ACT %s 1" % r.oid("TID-018", zone="field"), "not-your-turn")
    r.do("B PASS").act("TID-018", 1).say("DUMP").clear().say("DUMP")
    addr("error", "act_in_response", r, no_err=False)

    r = er(412, field_a=["DSK-012"], field_b=["TOK-001"],
           hand_a=["CIN-001", "NEU-012"])
    o = lambda c: r.oid(c, zone="field")
    r.cast("CIN-001").cast("NEU-012")
    r.bad("A ACT %s 1 %s" % (o("NEU-012"), o("TOK-001")), "cost-unpayable")
    r.do("A ACT %s 1 %s" % (o("DSK-012"), o("TOK-001")))
    r.say("DUMP").bad("A ACT %s 1 %s" % (r.oid("DSK-012"), o("CIN-001")),
                      "no-such-object")
    r.clear().say("DUMP").to_turn(3)
    r.use("NEU-012", 1, o("CIN-001")).say("DUMP")
    addr("error", "relic_settling_and_sacself", r, no_err=False)


# ================================================================ ending =====

def build_ending():
    add("ending", "spire_win_spec_example", mf(
        S(spire=2, deck_a=["CIN-001"], deck_b=["CIN-001"], hand_a=["CIN-003"]),
        ["A PLAY 1 B", "A PASS", "B PASS", "A PASS"]),
        want=("RESULT A spire",), no_err=False)

    r = er(501, turnlimit=3, field_a=["NEU-004"], field_b=["LOM-029"])
    r.to_turn(3).say("DUMP")
    for _ in range(40):
        if r.g.over:
            break
        r.auto()
    r.say("DUMP", "LEGAL").bad("A PASS", "game-over").bad("B PASS",
                                                          "game-over")
    addr("ending", "turn_limit_draw", r, no_err=False,
         want=("RESULT draw turn-limit",))

    r = er(502, turnlimit=1, first="B")
    for _ in range(20):
        if r.g.over:
            break
        r.auto()
    r.say("DUMP")
    addr("ending", "turn_limit_one_first_b", r,
         want=("RESULT draw turn-limit",))

    r = er(503, hand_a=["CIN-003"])
    r.bad("B CONCEDE", "not-your-turn").do("A CONCEDE").say("DUMP", "LEGAL")
    r.bad("B CONCEDE", "game-over")
    addr("ending", "concede_at_priority", r, no_err=False,
         want=("RESULT B concede",))

    r = er(504, field_a=["CIN-001"], field_b=["TOK-001"])
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK " + r.oid("CIN-001", zone="field"))
    r.to_phase("clash-block", "B", "blockers").do("B CONCEDE").say("DUMP")
    addr("ending", "concede_at_blockers", r, want=("LOSE B concede",))

    r = er(505, field_a=["CIN-001"])
    r.to_phase("clash-attack", "A", "attackers").say("LEGAL")
    r.do("A CONCEDE").say("DUMP")
    addr("ending", "concede_at_attackers", r, want=("LOSE A concede",))

    r = er(506, deck_b=[])
    for _ in range(20):
        if r.g.over:
            break
        r.auto()
    r.say("DUMP")
    addr("ending", "vault_loss_on_draw_step", r,
         want=("RESULT A vault",))

    r = er(507, spire=2, field_a=["DSK-020"], field_b=["TOK-001"])
    r.say("LEGAL").act("DSK-020", 2, r.oid("TOK-001", zone="field"))
    r.say("DUMP")
    addr("ending", "lose_by_paying_spire", r, want=("RESULT B spire",))

    r = er(508, spire=3, hand_a=["DSK-037"], deck_a=["CIN-001"])
    r.cast("DSK-037").say("DUMP")
    addr("ending", "vault_reason_beats_spire", r, want=("LOSE A vault",))

    r = er(509, spire=3, hand_a=["NEU-032"],
           field_a=["DSK-001", "DSK-015"], field_b=["DSK-015", "DSK-001"])
    r.cast("NEU-032").say("DUMP")
    addr("ending", "dies_triggers_kill", r, want=("RESULT",))

    r = er(510, spire=2, hand_b=["TID-028"], hand_a=["CIN-003*2"])
    r.play("CIN-003", "B").do("A PASS").play("TID-028", player="B")
    r.clear().say("DUMP").cast("CIN-003", "B").say("DUMP")
    addr("ending", "shield_saves_then_dies", r, want=("PREVENT B",))

    add("ending", "empty_script_pending", mf(S(deck_a=["CIN-001"],
                                               deck_b=["CIN-001"])),
        want=("RESULT pending none",))

    r = er(511, spire=4, field_a=["CIN-018", "TOK-001*2"],
           field_b=["CIN-018", "TOK-001*2"], hand_a=["CIN-035"])
    r.cast("CIN-035").say("DUMP")
    addr("ending", "simultaneous_deaths_both_hit", r, want=("RESULT",))

    r = er(512, spire=1, field_a=["TID-025"], field_b=["DSK-003"],
           hand_b=["CIN-003"])
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK " + r.oid("TID-025", zone="field")).do("A PASS")
    r.play("CIN-003", "A", player="B").say("DUMP").clear().say("DUMP")
    addr("ending", "lose_during_combat_step", r, want=("RESULT B spire",))


# ================================================================= trace =====

def build_trace():
    r = er(601, trace="legal", hand_a=["CIN-003", "CIN-001"],
           field_a=["CIN-001"], field_b=["TOK-001"], hand_b=["TID-003"])
    r.play("CIN-003", r.oid("TOK-001", zone="field")).bad("B PASS")
    r.do("A PASS").play("TID-003", r.oid("TOK-001", zone="field"), player="B")
    r.clear().say("DUMP")
    fight(r, [r.oid("CIN-001", zone="field")], mid_dump=False)
    addr("trace", "trace_legal_combat", r, no_err=False, want=("LEGAL BEGIN",))

    r = er(602, trace="state", hand_a=["CIN-005", "LOM-003"],
           field_b=["TOK-003"], field_a=["TOK-006"])
    r.cast("LOM-003", r.oid("TOK-006", zone="field")).bad("A PLAY 9")
    r.cast("CIN-005", r.oid("TOK-003", zone="field")).say("LEGAL")
    r.to_turn(2).do("B CONCEDE").say("CARD CIN-005").bad("A PASS")
    addr("trace", "trace_state_concede", r, no_err=False,
         want=("STATE BEGIN",))

    r = er(603, trace="none", hand_a=["CIN-003"])
    r.cast("CIN-003", "B").to_turn(2)
    addr("trace", "trace_none_explicit", r)

    r = er(604, trace="state", spire=2, hand_a=["CIN-003"])
    r.cast("CIN-003", "B").bad("A PASS", "game-over").say("DUMP")
    addr("trace", "trace_state_game_end", r, no_err=False,
         want=("RESULT A spire",))

    setup = S(seed=605, trace="legal", spire=12, opening=4, shuffle="on",
              deck_a=["CIN-%03d" % i for i in range(1, 25)],
              deck_b=["DSK-%03d" % i for i in range(1, 25)])
    add("trace", "trace_legal_selfplay",
        mf(setup, selfplay(setup, 605, 150)), want=("LEGAL BEGIN",))
    setup = S(seed=606, trace="state", spire=10, opening=4, shuffle="on",
              deck_a=["LOM-%03d" % i for i in range(1, 25)],
              deck_b=["TID-%03d" % i for i in range(1, 25)])
    add("trace", "trace_state_selfplay",
        mf(setup, selfplay(setup, 606, 120, error_rate=0.05)),
        want=("STATE BEGIN",), no_err=False)


# ================================================================= extra =====

def xr(seed=1, **kw):
    kw.setdefault("cards", "data/extra.spire")
    kw.setdefault("spire", 30)
    kw.setdefault("cap_a", 10)
    kw.setdefault("cap_b", 10)
    kw.setdefault("deck_a", ["EXT-001*10"])
    kw.setdefault("deck_b", ["EXT-001*10"])
    return R(seed=seed, **kw)


def build_extra():
    r = xr(701, hand_a=["EXT-003", "EXT-004"],
           field_a=["EXT-007", "EXT-010", "EXT-001"],
           field_b=["EXT-015", "EXT-011"])
    r.say("DUMP").cast("EXT-003").say("DUMP").cast("EXT-004").say("DUMP")
    addr("extra", "relics_selector", r, want=("WARD",))

    r = xr(702, hand_a=["EXT-005", "EXT-006", "EXT-009"],
           deck_a=["EXT-001*3", "EXT-002*2", "EXT-008"],
           hand_b=["EXT-001*4"], ash_b=["EXT-001", "EXT-003", "EXT-011"],
           field_a=["EXT-007"])
    r.cast("EXT-005").say("DUMP", "VAULT").cast("EXT-006").say("DUMP")
    r.cast("EXT-009").say("DUMP")
    addr("extra", "cards_zone_selectors", r, want=("EXILE", "RECALL"))

    r = xr(703, hand_a=["EXT-002", "EXT-012"], hand_b=["EXT-012"],
           field_a=["EXT-010", "EXT-007"],
           field_b=["EXT-015", "EXT-010", "EXT-007"])
    r.say("LEGAL").cast("EXT-002", r.oid("EXT-015", zone="field")).say("DUMP")
    r.cast("EXT-012", r.oid("EXT-010", zone="field", owner="B"))
    r.say("DUMP").do("A PASS")
    r.cast("EXT-012", r.oid("EXT-007", zone="field", owner="A"), player="B")
    r.say("DUMP")
    addr("extra", "relic_targets", r, want=("BOUNCE", "DESTROY"))

    r = xr(704, field_a=["EXT-008", "EXT-011", "EXT-007"],
           hand_a=["EXT-008", "EXT-013"], field_b=["EXT-001"])
    o = lambda c, n=0: r.oid(c, n, zone="field")
    r.use("EXT-008", 2, o("EXT-007")).say("DUMP")
    r.use("EXT-011", 2, o("EXT-007")).say("DUMP")
    r.bad("A ACT %s 2 %s" % (o("EXT-011"), o("EXT-007")), "cost-unpayable")
    r.cast("EXT-013").say("DUMP", "LEGAL").to_turn(3).say("DUMP")
    r.use("EXT-011", 2, o("EXT-007")).say("DUMP")
    r.to_phase("clash-attack", "A", "attackers").say("LEGAL")
    addr("extra", "relic_act_and_counter_cost", r, no_err=False,
         want=("COUNTERS",))

    r = xr(705, hand_a=["EXT-014", "EXT-016", "EXT-017", "EXT-005"],
           deck_a=["EXT-001", "EXT-003", "EXT-008", "EXT-002"],
           deck_b=["EXT-001*2", "EXT-002"], field_a=["EXT-015"])
    r.say("LEGAL").cast("EXT-014").cast("EXT-016").say("DUMP", "VAULT")
    r.cast("EXT-017").say("DUMP")
    addr("extra", "both_selectors_and_cheaper", r,
         want=("DIG", "CREATE", "PAY A ember 1"))

    r = xr(706, field_a=["EXT-018", "EXT-001"], hand_a=["EXT-001*2"],
           rift_a=["EXT-001"], hand_b=["EXT-003*8"])
    r.say("DUMP")
    for k in range(8):
        r.do("A PASS").cast("EXT-003", player="B")
        if k in (3, 4, 7):
            r.say("DUMP")
    addr("extra", "tenacity_and_dies_exile", r, want=("TENACITY", "EXILE"))

    r = xr(707, field_a=["EXT-018", "EXT-001"], rift_a=["EXT-001*2"],
           field_b=["EXT-001", "EXT-011"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    r.say("DUMP")
    fight(r, [o("EXT-018"), o("EXT-001", owner="A")],
          [(o("EXT-011"), o("EXT-018")), (o("EXT-001", owner="B"),
                                          o("EXT-001", owner="A"))])
    addr("extra", "provoke_and_aura_venom", r, want=("DOOM",))

    r = R(seed=708, cards="data/lexer.spire", cap_a=7, cap_b=7,
          hand_a=["LEX-001", "LEX-002"], hand_b=["LEX-002"],
          field_b=["LEX-001", "LEX-002"], deck_a=["LEX-001*4"],
          deck_b=["LEX-001*4"])
    r.say("DUMP", "LEGAL").play("LEX-001").say("DUMP").clear().say("DUMP")
    r.cast("LEX-002").say("DUMP").to_turn(2, "main1", "B").say("DUMP")
    r.cast("LEX-002", player="B").say("DUMP", "LEGAL")
    addr("extra", "lexer_cards_in_play", r, want=("ARRIVE", "DESTROY"))

    for i, seed in enumerate((711, 712, 713, 714)):
        pool = ["EXT-%03d" % k for k in range(1, 33)]
        rng = random.Random(seed)
        setup = S(seed=seed, cards="data/extra.spire", spire=15 + 5 * i,
                  opening=4, shuffle="on",
                  deck_a=[rng.choice(pool) for _ in range(30)],
                  deck_b=[rng.choice(pool) for _ in range(30)],
                  ash_a=[rng.choice(pool) for _ in range(3)],
                  rift_b=[rng.choice(pool) for _ in range(2)])
        add("extra", "extra_selfplay_%d" % (i + 1),
            mf(setup, selfplay(setup, seed, 150 + 150 * i,
                               directive_rate=0.03,
                               directives=["DUMP", "LEGAL", "VAULT"])))
    build_extra_language()
    setup = S(seed=715, cards="data/lexer.spire", spire=6, opening=3,
              shuffle="on", deck_a=["LEX-001*12", "LEX-002*4"],
              deck_b=["LEX-002*6", "LEX-001*10"])
    add("extra", "lexer_selfplay", mf(setup, selfplay(
        setup, 715, 200, directive_rate=0.05,
        directives=["DUMP", "LEGAL"])))


def build_extra_language():
    """Cases for the effect-language forms only data/extra.spire uses."""
    r = xr(721, field_a=["EXT-025", "EXT-001"], field_b=["EXT-011"],
           hand_a=["EXT-019*2"], hand_b=["EXT-019"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    r.cast("EXT-019", o("EXT-025")).say("DUMP")
    fight(r, [o("EXT-025"), o("EXT-001", owner="A")],
          [(o("EXT-011"), o("EXT-025"))], end=None)
    r.to_phase("clash-end", "A").say("DUMP").to_phase("main2", "A")
    r.cast("EXT-019", o("EXT-025")).do("A PASS")
    r.cast("EXT-019", o("EXT-011"), player="B").say("DUMP")
    r.to_turn(2).say("DUMP").to_turn(3).say("DUMP")
    addr("extra", "delay_kinds", r,
         want=("DELAY A end-of-combat", "DELAY B your-next-turn-start",
               " #25 0 #26", " #12 0 #13"))

    r = xr(722, field_a=["EXT-001*2", "EXT-032"], field_b=["EXT-001*2",
                                                           "EXT-011"],
           hand_a=["EXT-003", "EXT-020", "EXT-021", "EXT-013"])
    o = lambda c, n=0, **k: r.oid(c, n, zone="field", **k)
    r.cast("EXT-013").cast("EXT-003").say("DUMP")
    r.to_phase("clash-attack", "A", "attackers")
    r.do("A ATTACK %s" % o("EXT-032")).do("A PASS")
    r.to_phase("clash-block", "B", "blockers")
    r.do("B BLOCK %s:%s" % (o("EXT-011"), o("EXT-032")))
    r.cast("EXT-021").say("DUMP").to_phase("main2", "A")
    r.cast("EXT-020").say("DUMP")
    addr("extra", "state_filters", r, want=("BUFF",))

    r = xr(723, field_a=["EXT-008", "EXT-001", "EXT-032", "EXT-011"],
           field_b=["EXT-032", "EXT-011", "EXT-001"],
           hand_a=["EXT-022", "EXT-026"], hand_b=["EXT-026"])
    r.say("DUMP").cast("EXT-026").say("DUMP").cast("EXT-022").say("DUMP")
    addr("extra", "keyword_filters_use_base", r, want=("BOUNCE", "EXILE"))

    r = xr(724, field_a=["EXT-027", "EXT-025", "EXT-011"],
           field_b=["EXT-018", "EXT-025", "EXT-001"],
           hand_a=["EXT-026", "EXT-023*2"],
           hand_b=["EXT-028"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    r.say("DUMP").cast("EXT-026").say("DUMP")
    r.cast("EXT-023", "B").say("DUMP")
    r.say("LEGAL").cast("EXT-023", o("EXT-001")).say("DUMP", "LEGAL")
    addr("extra", "aura_setbody_swapstats_base_amounts", r,
         want=("effect",))

    r = xr(725, hand_a=["EXT-024*3", "EXT-003"], cap_a=2, spire=12,
           deck_a=["EXT-001*8"], deck_b=["EXT-001*4"])
    r.cast("EXT-024").say("DUMP").cast("EXT-024").say("DUMP")
    r.to_turn(3).say("DUMP").cast("EXT-024").say("DUMP")
    addr("extra", "conditions_ember_spire_vault", r, want=("CAP", "MILL"))

    r = xr(726, field_a=["EXT-025*2"], field_b=["EXT-001", "EXT-011"],
           hand_b=["EXT-003*2"])
    o = lambda c, n=0, **k: r.oid(c, n, zone="field", **k)
    r.do("A PASS").cast("EXT-003", player="B").say("DUMP")
    r.do("A PASS").cast("EXT-003", player="B").say("DUMP")
    fight(r, [o("EXT-025", 0)], [(o("EXT-011"), o("EXT-025", 0))])
    r.to_turn(3)
    fight(r, [o("EXT-025", 0), o("EXT-025", 1)])
    addr("extra", "damaged_and_deals_damage_it", r, want=("WARD", "COUNTERS"))

    r = xr(727, field_a=["EXT-011", "EXT-001"], field_b=["EXT-025"],
           hand_a=["EXT-028*3", "EXT-003"], deck_b=["EXT-001*3"])
    o = lambda c, **k: r.oid(c, zone="field", **k)
    r.cast("EXT-003").cast("EXT-028", o("EXT-011")).say("DUMP")
    r.cast("EXT-028", o("EXT-011")).cast("EXT-028", o("EXT-025")).say("DUMP")
    addr("extra", "negative_counters_and_shield", r, want=("SHIELD",))

    r = xr(728, hand_a=["EXT-029*2"],
           deck_a=["EXT-001*3"], deck_b=["EXT-011", "EXT-001", "EXT-032",
                                         "EXT-008"])
    r.say("VAULT").cast("EXT-029").say("VAULT").cast("EXT-029").say("VAULT")
    addr("extra", "dig_zero_and_foe", r, want=("DIG-MISS A", "DIG B"))

    for seed in (729, 730):
        r = xr(seed, hand_a=["EXT-030*4"], field_a=["EXT-018"],
               field_b=["EXT-011", "EXT-001", "EXT-025", "EXT-018"])
        for _ in range(4):
            r.cast("EXT-030").say("DUMP")
        addr("extra", "random_unit_filters_%d" % seed, r, want=("DAMAGE",))

    r = xr(731, hand_a=["EXT-001*2", "EXT-031*3"], hand_b=["EXT-001*2"],
           field_a=["EXT-018"], field_b=["EXT-018"])
    r.cast("EXT-031", "B").say("DUMP").cast("EXT-031", "A").say("DUMP")
    r.bad("A PLAY %d %s" % (r.pos("EXT-031"),
                            r.oid("EXT-018", zone="field", owner="A")),
          "illegal-target")
    addr("extra", "player_targets_owner_of", r, no_err=False,
         want=("SPIRE B -1",))

    r = xr(732, field_a=["EXT-032", "EXT-001"], hand_a=["EXT-001", "EXT-032"],
           field_b=["EXT-001"])
    o = lambda c, n=0, **k: r.oid(c, n, zone="field", **k)
    r.say("LEGAL")
    r.bad("A ACT %s 2 %s" % (o("EXT-032"), o("EXT-032")), "illegal-target")
    r.use("EXT-032", 2, o("EXT-001", owner="B")).say("DUMP", "LEGAL")
    r.bad("A ACT %s 2 %s" % (o("EXT-032"), o("EXT-001", owner="A")),
          "cost-unpayable")
    r.to_turn(3).say("LEGAL").use("EXT-032", 2, o("EXT-001", owner="A"))
    r.say("DUMP")
    addr("extra", "multi_item_cost", r, no_err=False,
         want=("PAY A spire 1",))


# ============================================================== examples =====

def build_examples():
    """The worked examples of SPEC.md section 26, checked byte for byte."""
    import re
    text = open(os.path.join(HERE, "SPEC.md"), encoding="utf-8").read()
    body = text[text.index("## 26. Worked examples"):
                text.index("## 27. Index of card ids")]
    parts = re.split(r"^### (26\.\d+) (.*)$", body, flags=re.M)
    for i in range(1, len(parts), 3):
        num, title, sect = parts[i], parts[i + 1], parts[i + 2]
        blocks = re.findall(r"```\n(.*?)```", sect, flags=re.S)
        inp, outp = blocks[0], blocks[1]
        if re.match(r"\s*\d+  ", inp):
            inp = "".join(re.sub(r"^\s*\d+  ", "", ln) + "\n"
                          for ln in inp.splitlines())
        name = "spec_%s_%s" % (num.replace(".", "_"),
                               re.sub(r"[^a-z0-9]+", "_",
                                      title.lower()).strip("_")[:30])
        out = add("examples", name, inp, no_err=False)
        if out.rstrip("\n") != outp.rstrip("\n"):
            FAILURES.append("examples/%s: differs from SPEC.md" % name)


# ================================================================ random =====

POOL = None


def card_pool():
    global POOL
    if POOL is None:
        POOL = sorted(c for c in load_database(DB) if not c.startswith("TOK"))
    return POOL


def field_pool():
    """The non-token units and relics: the cards a FIELD line may name."""
    db = load_database(DB)
    return [c for c in card_pool() if db[c].type != "rite"]


def random_setup(rng, seed, size):
    """Random match settings; `size` scales Spire and deck sizes."""
    pool = card_pool()
    fpool = field_pool()
    mode = rng.randrange(4)
    if mode == 0:
        houses = rng.sample(["CIN", "TID", "LOM", "DSK", "NEU"], 2)
        sub_a = [c for c in pool if c[:3] in (houses[0], "NEU")]
        sub_b = [c for c in pool if c[:3] in (houses[1], "NEU")]
    elif mode == 1:
        sub_a = rng.sample(pool, 25)
        sub_b = rng.sample(pool, 25)
    else:
        sub_a = sub_b = pool

    def deck(sub, n):
        counts = {}
        for _ in range(n):
            c = rng.choice(sub)
            counts[c] = counts.get(c, 0) + 1
        return ["%s*%d" % (c, k) if k > 1 else c
                for c, k in sorted(counts.items(), key=lambda kv: kv[0])]

    nd = {"s": 30, "m": 60, "l": 400, "x": 2600}[size]
    spire = {"s": rng.randint(8, 30), "m": rng.randint(20, 60),
             "l": rng.randint(300, 1000),
             "x": rng.randint(20000, 1000000)}[size]
    kw = dict(seed=seed, spire=spire, opening=rng.randint(3, 7),
              shuffle="on" if rng.random() < 0.8 else "off",
              deck_a=deck(sub_a, nd + rng.randint(0, 10)),
              deck_b=deck(sub_b, nd + rng.randint(0, 10)))
    if rng.random() < 0.3:
        kw["first"] = "B"
    if rng.random() < 0.3:
        kw["maxcap"] = rng.randint(4, 14)
    if rng.random() < 0.3:
        kw["handmax"] = rng.randint(2, 9)
    if rng.random() < 0.3:
        kw["cap_a"] = rng.randint(0, 6)
        kw["cap_b"] = rng.randint(0, 6)
    if size in "sm" and rng.random() < 0.25:
        kw["turnlimit"] = rng.randint(6, 40)
    if size == "x":
        kw["turnlimit"] = 100000
    if rng.random() < 0.35:
        kw["field_a"] = [rng.choice(fpool) for _ in range(rng.randint(1, 4))]
        kw["field_b"] = [rng.choice(fpool) for _ in range(rng.randint(1, 4))]
    if rng.random() < 0.3:
        kw["hand_a"] = [rng.choice(pool) for _ in range(rng.randint(1, 3))]
        kw["ash_b"] = [rng.choice(pool) for _ in range(rng.randint(1, 5))]
        kw["rift_a"] = [rng.choice(pool) for _ in range(rng.randint(1, 2))]
    if rng.random() < 0.3:
        tok = ["TOK-%03d" % i for i in range(1, 9)]
        kw["field_b"] = kw.get("field_b", []) + [rng.choice(tok)]
        kw["hand_b"] = [rng.choice(tok)]
    return S(**kw)


def build_random():
    plan = ([("s", 120)] * 14 + [("m", 400)] * 12 + [("m", 1200)] * 8 +
            [("l", 3000)] * 8 + [("l", 6000)] * 4 + [("x", 15000)] * 4 +
            [("x", 45000)] * 2)
    for i, (size, steps) in enumerate(plan):
        seed = 9000 + 37 * i
        rng = random.Random(seed)
        setup = random_setup(rng, seed, size)
        small = steps <= 1200
        sp = SelfPlay(setup, seed + 1,
                      act_bias=rng.choice((0.5, 0.75, 0.9)),
                      attack_bias=rng.choice((0.3, 0.55, 0.8)),
                      block_bias=rng.choice((0.3, 0.5, 0.8)),
                      directive_rate=(0.04 if small else
                                      0.002 if size == "l" else 0.0004),
                      error_rate=(0.04 if small else 0.003),
                      directives=(DIRECTIVES if small else
                                  ["DUMP", "LEGAL", "CARD NEU-006"]))
        script = sp.run(steps)
        if i % 5 == 3 and not sp.g.over:
            who = sp.g.decision[0] if sp.g.decision else "A"
            script += ["%s CONCEDE" % who, "A PASS", "DUMP"]
        add("random", "selfplay_%s_%02d" % (size, i), mf(setup, script),
            no_err=False, big=True)


# ================================================================= audit ====

def build_audit():
    """Paired cases, one public and one hidden, for rules that are easy to get
    subtly wrong: error precedence between targets and costs, `siphon` paying
    the controller, the `blocked` trigger subject, `leave`/`dies` of a stripped
    unit, the hand limit, base-valued filters and the first losing reason."""
    small = dict(spire=20, deck_a=["CIN-001*6"], deck_b=["TID-001*6"])

    # Targets are checked before Ember and before activation costs.
    r = R(seed=901, hand_a=["CIN-005", "DSK-002"], field_a=["NEU-002"],
          field_b=["TOK-001", "DSK-012"], **small)
    tok, relic = r.oid("TOK-001", zone="field"), r.oid("NEU-002", zone="field")
    r.bad("A PLAY %d A" % r.pos("CIN-005"), "illegal-target")
    r.bad("A PLAY %d %s" % (r.pos("CIN-005"), relic), "illegal-target")
    r.bad("A PLAY %d" % r.pos("CIN-005"), "bad-target-count")
    r.bad("A PLAY %d %s %s" % (r.pos("DSK-002"), tok, relic),
          "bad-target-count")
    r.bad("A PLAY %d %s" % (r.pos("CIN-005"), tok), "cannot-afford")
    r.do("A PASS")
    gal = r.oid("DSK-012", zone="field")
    r.bad("B ACT %s 1 B" % gal, "illegal-target")
    r.bad("B ACT %s 1" % gal, "bad-target-count")
    r.bad("B ACT %s 1 %s" % (gal, tok), "cost-unpayable").say("LEGAL")
    addr("error", "targets_before_costs", r, no_err=False, split="public")

    r = R(seed=902, hand_a=["LOM-003", "DSK-002", "CIN-005"],
          field_a=["DSK-012", "TOK-003"], field_b=["NEU-002", "TOK-001"],
          **small)
    tok, relic = r.oid("TOK-001", zone="field"), r.oid("NEU-002", zone="field")
    gal = r.oid("DSK-012", zone="field")
    r.bad("A PLAY %d %s" % (r.pos("LOM-003"), relic), "illegal-target")
    r.bad("A PLAY %d %s %s" % (r.pos("LOM-003"), tok, tok), "bad-target-count")
    r.bad("A PLAY %d %s" % (r.pos("DSK-002"), gal), "illegal-target")
    r.bad("A PLAY %d B" % r.pos("CIN-005"), "illegal-target")
    r.bad("A PLAY %d %s" % (r.pos("DSK-002"), tok), "cannot-afford")
    r.bad("A ACT %s 1 %s" % (gal, relic), "illegal-target")
    r.do("A ACT %s 1 %s" % (gal, tok)).say("DUMP").clear().say("DUMP")
    addr("error", "targets_before_costs_2", r, no_err=False, split="hidden")

    # Siphon pays the unit's current controller, not its owner.
    r = R(seed=903, cap_a=3, hand_a=["NEU-028"], field_a=["NEU-023"],
          ash_a=["CIN-001*6"], field_b=["TID-025"], **small)
    stolen = r.oid("TID-025", zone="field")
    r.cast("NEU-028", stolen).say("DUMP")
    fight(r, [stolen])
    addr("combat", "siphon_pays_controller", r,
         want=("CONTROL %s A" % stolen, "SPIRE A +2 22"), split="public")

    r = R(seed=904, cap_a=3, hand_a=["NEU-028"], field_a=["NEU-023"],
          ash_a=["TID-001*6"], field_b=["LOM-004", "TOK-003"], **small)
    stolen, wall = r.oid("LOM-004", zone="field"), r.oid("TOK-003", zone="field")
    r.cast("NEU-028", stolen)
    fight(r, [stolen], [(wall, stolen)])
    addr("combat", "siphon_pays_controller_2", r,
         want=("PREVENT %s 1" % wall, "SPIRE A +2 22"), split="hidden")

    # The subject of `blocked` is the attacker's first blocker in canonical
    # order, whatever order the BLOCK command lists the pairs in.
    r = xr(905, field_a=["EXT-033"], field_b=["EXT-001", "EXT-001"])
    hound = r.oid("EXT-033", zone="field")
    b1, b2 = r.oid("EXT-001", 0, zone="field"), r.oid("EXT-001", 1, zone="field")
    fight(r, [hound], [(b2, hound), (b1, hound)])
    addr("extra", "blocked_subject_first_blocker", r,
         want=("DAMAGE %s %s 1" % (hound, b1),), split="public")

    r = xr(906, field_a=["EXT-033"], field_b=["EXT-001", "EXT-011", "EXT-001"],
           hand_b=["EXT-012"])
    hound = r.oid("EXT-033", zone="field")
    first, wall = r.oid("EXT-001", 0, zone="field"), r.oid("EXT-011", zone="field")
    last = r.oid("EXT-001", 1, zone="field")
    fight(r, [hound], [(last, hound), (wall, hound), (first, hound)])
    addr("extra", "blocked_subject_first_blocker_2", r,
         want=("DAMAGE %s %s 1" % (hound, first),), split="hidden")

    # A stripped unit still collects its own leave/dies triggers; a stripped
    # listener collects nothing.
    r = R(seed=907, cap_a=5, hand_a=["DSK-031", "DSK-031", "CIN-005"],
          field_b=["DSK-001", "CIN-018"], field_a=["DSK-036"], **small)
    acolyte = r.oid("DSK-001", zone="field")
    r.cast("DSK-031", acolyte).cast("DSK-031", r.oid("CIN-018", zone="field"))
    r.say("DUMP").cast("CIN-005", acolyte).say("DUMP")
    addr("trigger", "stripped_unit_dies_trigger", r,
         want=("STRIP %s" % acolyte, "SPIRE A -1 19"), split="public")

    r = R(seed=908, cap_a=3, hand_a=["DSK-031", "TID-003"],
          field_b=["NEU-011", "TID-012"], **small)
    scribe = r.oid("NEU-011", zone="field")
    r.cast("DSK-031", scribe).cast("TID-003", scribe).say("DUMP")
    addr("trigger", "stripped_unit_leave_trigger", r,
         want=("BOUNCE %s" % scribe, "DRAW B"), split="hidden")

    # Dusk discards down to exactly HANDMAX.
    r = R(seed=909, handmax=3, hand_a=["TID-001*5"], **small)
    r.to_turn(2, "main1", "B").say("DUMP")
    addr("setup", "handmax_three", r, want=("DISCARD A",), split="public")

    r = R(seed=910, handmax=1, hand_a=["CIN-016*2"], hand_b=["CIN-016*4"],
          first="B", **small)
    r.to_turn(3, "main1", "B").say("DUMP")
    addr("setup", "handmax_one", r, want=("DISCARD B",), split="hidden")

    # Filters test base edge/core: counters count, layer effects do not.
    r = R(seed=911, cap_a=4, field_a=["TOK-007", "NEU-029"],
          field_b=["TID-024"], hand_a=["CIN-011", "NEU-009", "LOM-003"],
          **small)
    drone = r.oid("TOK-007", zone="field")
    r.cast("CIN-011", drone).cast("NEU-009", drone).say("DUMP", "LEGAL")
    r.cast("LOM-003", drone).say("DUMP")
    r.to_phase("clash-attack", "A", "attackers").say("LEGAL")
    addr("layer", "filters_use_base_values", r, split="public")

    r = R(seed=912, cap_a=4, field_a=["CIN-001", "NEU-029", "TOK-007"],
          field_b=["TID-024"], hand_a=["NEU-009", "LOM-003", "CIN-011"],
          **small)
    runner, drone = r.oid("CIN-001", zone="field"), r.oid("TOK-007", zone="field")
    r.cast("LOM-003", runner).cast("NEU-009", drone).cast("CIN-011", drone)
    r.say("DUMP").to_phase("clash-attack", "A", "attackers").say("LEGAL")
    addr("layer", "filters_use_base_values_2", r, split="hidden")

    # Target and selector filters outside auras also read base values: two
    # Twin Reliquaries lift a 1/1 to 5/5, which stays a legal (core le 3)
    # target and still counts for (edge lt 2).
    r = xr(914, field_a=["EXT-010", "EXT-010", "EXT-001"],
           field_b=["EXT-011"], hand_a=["EXT-023"])
    mote = r.oid("EXT-001", zone="field", owner="A")
    r.say("DUMP", "LEGAL").cast("EXT-023", mote).say("DUMP")
    addr("extra", "target_filters_use_base_values", r,
         want=("DAMAGE", "DRAW A"), split="public")

    r = xr(915, field_b=["EXT-010", "EXT-010", "EXT-001"],
           field_a=["EXT-001", "EXT-001"], hand_a=["EXT-023"])
    mote = r.oid("EXT-001", zone="field", owner="B")
    r.say("LEGAL").cast("EXT-023", mote).say("DUMP")
    addr("extra", "target_filters_use_base_values_2", r,
         want=("DAMAGE",), split="hidden")

    # The first losing reason recorded is the one reported.
    r = er(913, spire=4, hand_a=["DSK-037"], deck_a=["CIN-001*2"])
    r.cast("DSK-037").say("DUMP")
    addr("ending", "vault_reason_first", r, want=("LOSE A vault",),
         split="public")


# ================================================================ writing ====

def write_all():
    for d in (PUBLIC_DIR, HIDDEN_DIR):
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
    seq = 0
    counts = {"public": 0, "hidden": 0}
    for group in ["examples"] + GROUPS:
        for i, (name, text, out, split) in enumerate(CASES[group]):
            seq += 1
            if split is None:
                public = group == "examples" or i % 4 == 1
            else:
                public = split == "public"
            d = PUBLIC_DIR if public else HIDDEN_DIR
            base = os.path.join(d, "%03d_%s_%s" % (seq, group, name))
            with open(base + ".in", "w", encoding="utf-8", newline="") as f:
                f.write(text)
            with open(base + ".out", "w", encoding="utf-8", newline="") as f:
                f.write(out)
            counts["public" if public else "hidden"] += 1
    return counts


def main():
    CASES["examples"] = []
    builders = [build_examples, build_fatal, build_card, build_setup,
                build_prng, build_effects, build_layers, build_triggers,
                build_combat, build_chain, build_errors, build_ending,
                build_trace, build_extra, build_random, build_audit]
    for b in builders:
        b()
    sizes = {g: len(CASES[g]) for g in ["examples"] + GROUPS}
    print("cases:", sizes, "total", sum(sizes.values()))
    if FAILURES:
        for f in FAILURES:
            print("FAIL", f)
        sys.exit(1)
    print(write_all())


if __name__ == "__main__":
    main()
