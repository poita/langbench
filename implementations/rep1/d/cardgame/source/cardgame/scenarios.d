/**
 * Golden scenario tests: the worked examples of SPEC.md section 26, run end to end
 * against a small in-memory card database.
 */
module cardgame.scenarios;

version (unittest)
{
    import cardgame.session : runMatch;
    import std.string : strip, splitLines, stripRight;
    import std.array : join;
    import std.algorithm : map;
    import core.exception : AssertError;

    private enum testDatabase = q"EOS
(card CIN-001 (name "Ember Runner") (type unit) (cost 1) (body 2 1)
  (tags cinder runner) (keywords vanguard))
(card CIN-002 (name "Flarehand Adept") (type unit) (cost 2) (body 2 2)
  (tags cinder mage)
  (on you-play-rite (modify 1 0 self)))
(card CIN-003 (name "Searing Bolt") (type rite) (cost 1) (tags cinder)
  (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))
(card CIN-005 (name "Pyre Lance") (type rite) (cost 2) (tags cinder)
  (resolve (targets (unit)) (damage 3 (t 1))))
(card CIN-006 (name "Ashblade Duelist") (type unit) (cost 2) (body 2 1)
  (tags cinder soldier) (keywords riposte))
(card CIN-011 (name "Blazing Charge") (type rite) (cost 1) (tags cinder)
  (keywords swift)
  (resolve (targets (unit)) (modify 2 0 (t 1)) (grant pierce (t 1))))
(card CIN-016 (name "Cinder Chorus") (type rite) (cost 4) (tags cinder)
  (resolve (summon TOK-001 3 you)))
(card CIN-018 (name "Ashfall Sentinel") (type unit) (cost 4) (body 3 4)
  (tags cinder construct)
  (on ally-dies (damage 1 foe)))
(card CIN-027 (name "Torch Bearer") (type unit) (cost 1) (body 1 2)
  (tags cinder mage)
  (act (cost (ember 1) (exhaust)) (targets (unit)) (damage 1 (t 1))))
(card DSK-001 (name "Gravemark Acolyte") (type unit) (cost 1) (body 1 1)
  (tags dusk undead)
  (on dies (spire -1 foe)))
(card DSK-002 (name "Shadow Lance") (type rite) (cost 2) (tags dusk)
  (resolve (targets (unit)) (destroy (t 1))))
(card DSK-005 (name "Nightreaper") (type unit) (cost 5) (body 4 3)
  (tags dusk undead)
  (on enemy-dies (counters 1 self)))
(card DSK-020 (name "Grim Harvester") (type unit) (cost 3) (body 2 2)
  (tags dusk undead)
  (on spire-loss (counters 1 self))
  (act (cost (exhaust) (spire 2)) (targets (unit)) (damage 2 (t 1))))
(card DSK-024 (name "Deathless Knight") (type unit) (cost 4) (body 3 3)
  (tags dusk undead) (keywords tenacity))
(card DSK-036 (name "Pall Bearer") (type unit) (cost 3) (body 2 4)
  (tags dusk undead)
  (on ally-dies (spire 1 you))
  (on deals-damage (spire 1 you)))
(card LOM-001 (name "Rootling") (type unit) (cost 1) (body 1 1)
  (tags loam plant)
  (on your-turn-start (counters 1 self)))
(card LOM-002 (name "Soil Tender") (type unit) (cost 2) (body 1 3)
  (tags loam plant)
  (on ally-arrive (counters 1 it)))
(card LOM-003 (name "Verdant Surge") (type rite) (cost 2) (tags loam)
  (resolve (targets (unit)) (counters 2 (t 1))))
(card LOM-039 (name "Heartwood Shrine") (type relic) (cost 5) (tags loam)
  (aura (modify 1 1 (units yours)))
  (aura (grant (plating 1) (units yours))))
(card TID-001 (name "Tidecaller Novice") (type unit) (cost 2) (body 1 2)
  (tags tide mage)
  (on arrive (draw 1 you)))
(card TID-002 (name "Reef Glider") (type unit) (cost 2) (body 1 3)
  (tags tide beast) (keywords ghostwalk))
(card TID-003 (name "Undertow") (type rite) (cost 1) (tags tide)
  (keywords swift)
  (resolve (targets (unit)) (bounce (t 1))))
(card TID-022 (name "Backwash") (type rite) (cost 2) (tags tide)
  (keywords swift)
  (resolve (targets (unit)) (setbody 0 1 (t 1))))
(card TOK-001 (name "Cinder Mote") (type unit) (cost 0) (body 1 1)
  (tags neutral mote))
(card TOK-003 (name "Stone Sentinel") (type unit) (cost 0) (body 0 3)
  (tags neutral construct) (keywords (plating 1)))
(card TOK-005 (name "Grave Hound") (type unit) (cost 0) (body 1 1)
  (tags neutral undead) (keywords venom))
EOS";

    private string normalise(string s)
    {
        return s.splitLines.map!(l => l.stripRight).join("\n").strip;
    }

    private void golden(string input, string expected, string file = __FILE__, size_t line = __LINE__)
    {
        auto got = runMatch(input, (string path) {
            if (path == "mem:cards") return testDatabase;
            throw new Exception("no such file");
        });
        if (normalise(got) != normalise(expected))
            throw new AssertError("scenario mismatch:\n" ~ got, file, line);
    }

    unittest // examples_spec_26_1_card_a_rite_a_relic_with_two_a
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
OPENING 0
SHUFFLE off
START
CARD CIN-003
CARD LOM-039
CARD DSK-020
CARD ZZZ-999
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
CARD BEGIN CIN-003
name Searing Bolt
type rite
cost 1
tags cinder
keywords swift
ability 1 resolve (targets (any)) (damage 2 (t 1))
CARD END
CARD BEGIN LOM-039
name Heartwood Shrine
type relic
cost 5
tags loam
keywords -
ability 1 aura (modify 1 1 (units yours))
ability 2 aura (grant (plating 1) (units yours))
CARD END
CARD BEGIN DSK-020
name Grim Harvester
type unit
cost 3
body 2/2
tags dusk,undead
keywords -
ability 1 on spire-loss - (counters 1 self)
ability 2 act (cost (exhaust) (spire 2)) (targets (unit)) (damage 2 (t 1))
CARD END
CARD BEGIN ZZZ-999
unknown
CARD END
8 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_3_setup_and_dump
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001*3
DECK B CIN-001*3
HAND A CIN-003
FIELD B CIN-001
START
DUMP
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
STATE BEGIN
turn 1 active A phase main1 decision A priority
player A spire 10 ember 1 cap 1 vault 3 hand 1 ash 0 rift 0
player B spire 10 ember 0 cap 0 vault 3 hand 0 ash 0 rift 0
hand A 1 #4 CIN-003
field B #8 CIN-001 2/1 w0 c0 ready - kw vanguard
STATE END
8 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_4_a_rite_kills_a_unit
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003
FIELD B TOK-001
START
A PLAY 1 #4
A PASS
B PASS
A PASS
B PASS
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 CIN-003 #4
9 PAY A ember 1
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DAMAGE #2 #4 2
14 SPENT #2 CIN-003
15 DESTROY #4 TOK-001
16 PASS A
17 PASS B
18 PHASE clash-attack
19 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_5_riposte_combat
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-006
DECK B CIN-001
FIELD A CIN-006
FIELD B TOK-001
START
A PASS
B PASS
A ATTACK #2
A PASS
B PASS
B BLOCK #4:#2
A PASS
B PASS
A PASS
B PASS
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PASS A
9 PASS B
10 PHASE clash-attack
11 EXHAUST #2
12 ATTACK #2
13 PASS A
14 PASS B
15 PHASE clash-block
16 BLOCK #4 #2
17 PASS A
18 PASS B
19 PHASE clash-riposte
20 DAMAGE #2 #4 2
21 DESTROY #4 TOK-001
22 PASS A
23 PASS B
24 PHASE clash-damage
25 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_6_trigger_ordering_across_three_
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 3
DECK A CIN-001
DECK B CIN-001
HAND A DSK-002
FIELD A CIN-018 DSK-036 TOK-001
FIELD B DSK-005
START
A PLAY 1 #5
A PASS
B PASS
A PASS
B PASS
A PASS
B PASS
A PASS
B PASS
A PASS
B PASS
DUMP
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 4 4
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 DSK-002 #5
9 PAY A ember 2
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DESTROY #5 TOK-001
14 SPENT #2 DSK-002
15 TRIGGER A ~2 #3 1
16 TRIGGER A ~3 #4 1
17 TRIGGER B ~4 #7 1
18 PASS A
19 PASS B
20 RESOLVE ~2
21 DAMAGE #3 B 1
22 SPIRE B -1 9
23 PASS A
24 PASS B
25 RESOLVE ~3
26 SPIRE A +1 11
27 PASS A
28 PASS B
29 RESOLVE ~4
30 COUNTERS #7 +1 1
31 PASS A
32 PASS B
33 PHASE clash-attack
STATE BEGIN
turn 1 active A phase clash-attack decision A attackers
player A spire 11 ember 2 cap 4 vault 1 hand 0 ash 2 rift 0
player B spire 9 ember 0 cap 0 vault 1 hand 0 ash 0 rift 0
field A #3 CIN-018 3/4 w0 c0 ready - kw -
field A #4 DSK-036 2/4 w0 c0 ready - kw -
field B #7 DSK-005 5/4 w0 c1 ready - kw -
ash A 1 #5 TOK-001
ash A 2 #2 DSK-002
STATE END
34 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_7_layers
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 4
DECK A CIN-001
DECK B CIN-001
HAND A LOM-003 TID-022 CIN-011
FIELD A TOK-003
START
A PLAY 1 #5
A PASS
B PASS
A PLAY 1 #5
A PASS
B PASS
A PLAY 1 #5
A PASS
B PASS
DUMP
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 5 5
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 LOM-003 #5
9 PAY A ember 2
10 PASS A
11 PASS B
12 RESOLVE ~1
13 COUNTERS #5 +2 2
14 SPENT #2 LOM-003
15 PLAY A ~2 #3 TID-022 #5
16 PAY A ember 2
17 PASS A
18 PASS B
19 RESOLVE ~2
20 SETBODY #5 0 1
21 SPENT #3 TID-022
22 PLAY A ~3 #4 CIN-011 #5
23 PAY A ember 1
24 PASS A
25 PASS B
26 RESOLVE ~3
27 BUFF #5 2 0
28 GRANT #5 pierce
29 SPENT #4 CIN-011
STATE BEGIN
turn 1 active A phase main1 decision A priority
player A spire 10 ember 0 cap 5 vault 1 hand 0 ash 3 rift 0
player B spire 10 ember 0 cap 0 vault 1 hand 0 ash 0 rift 0
field A #5 TOK-003 4/3 w0 c2 ready - kw pierce,plating:1
ash A 1 #2 LOM-003
ash A 2 #3 TID-022
ash A 3 #4 CIN-011
effect 1 ts2 A turn setbody 0 1 on #5
effect 2 ts3 A turn modify 2 0 on #5
effect 3 ts4 A turn grant pierce on #5
STATE END
30 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_8_tenacity_as_a_replacement_effe
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 3
DECK A CIN-001
DECK B CIN-001
HAND A CIN-005 CIN-005
FIELD B DSK-024
START
A PLAY 1 #5
A PASS
B PASS
A PLAY 1 #5
A PASS
B PASS
DUMP
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 4 4
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 CIN-005 #5
9 PAY A ember 2
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DAMAGE #2 #5 3
14 SPENT #2 CIN-005
15 TENACITY #5
16 PLAY A ~2 #3 CIN-005 #5
17 PAY A ember 2
18 PASS A
19 PASS B
20 RESOLVE ~2
21 DAMAGE #3 #5 3
22 SPENT #3 CIN-005
23 DESTROY #5 DSK-024
STATE BEGIN
turn 1 active A phase main1 decision A priority
player A spire 10 ember 0 cap 4 vault 1 hand 0 ash 2 rift 0
player B spire 10 ember 0 cap 0 vault 1 hand 0 ash 1 rift 0
ash A 1 #2 CIN-005
ash A 2 #3 CIN-005
ash B 1 #5 DSK-024
STATE END
24 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_9_fizzling
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 1
CAP B 1
DECK A CIN-001
DECK B CIN-001
HAND A CIN-005
HAND B TID-003
FIELD B TOK-001
START
A PLAY 1 #5
A PASS
B PLAY 1 #5
B PASS
A PASS
A PASS
B PASS
DUMP
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 2 2
5 EMBER B 1 1
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 CIN-005 #5
9 PAY A ember 2
10 PASS A
11 PLAY B ~2 #4 TID-003 #5
12 PAY B ember 1
13 PASS B
14 PASS A
15 RESOLVE ~2
16 BOUNCE #5 TOK-001
17 SPENT #4 TID-003
18 PASS A
19 PASS B
20 RESOLVE ~1
21 FIZZLE ~1
22 SPENT #2 CIN-005
STATE BEGIN
turn 1 active A phase main1 decision A priority
player A spire 10 ember 0 cap 2 vault 1 hand 0 ash 1 rift 0
player B spire 10 ember 0 cap 1 vault 1 hand 1 ash 1 rift 0
hand B 1 #5 TOK-001
ash A 1 #2 CIN-005
ash B 1 #4 TID-003
STATE END
23 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_10_legal_at_all_three_decision_ki
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
CAP A 2
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003 CIN-027
FIELD A TOK-001
FIELD B TOK-005
START
LEGAL
A PASS
B PASS
LEGAL
A ATTACK #4
A PASS
B PASS
LEGAL
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 3 3
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
LEGAL BEGIN A priority
PASS
PLAY 1 CIN-003 A
PLAY 1 CIN-003 B
PLAY 1 CIN-003 #4
PLAY 1 CIN-003 #6
PLAY 2 CIN-027
LEGAL END
8 PASS A
9 PASS B
10 PHASE clash-attack
LEGAL BEGIN A attackers
CANATTACK #4
LEGAL END
11 EXHAUST #4
12 ATTACK #4
13 PASS A
14 PASS B
15 PHASE clash-block
LEGAL BEGIN B blockers
CANBLOCK #6 #4
LEGAL END
16 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_11_error_kinds_and_precedence
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003 CIN-016
START
X PASS
B PASS
A BLOCK
A PLAY 5
A PLAY 1
A PLAY 1 #99
A PLAY 2
A PLAY 1 A
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
ERR 10 bad-syntax
ERR 11 not-your-turn
ERR 12 wrong-decision
ERR 13 no-such-card
ERR 14 bad-target-count
ERR 15 illegal-target
ERR 16 cannot-afford
8 PLAY A ~1 #2 CIN-003 A
9 PAY A ember 1
10 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_12_shuffling_and_vault
    {
        golden(q"EOS
CARDS mem:cards
SEED 7
SPIRE 10
OPENING 0
DECK A CIN-001 CIN-002 CIN-003 TID-001 TID-002 LOM-001 LOM-002 DSK-001
DECK B CIN-001 CIN-002 CIN-003 TID-001 TID-002 LOM-001 LOM-002 DSK-001
START
VAULT
EOS", q"EOS
1 GAME-START A
2 SHUFFLE A
3 SHUFFLE B
4 TURN 1 A
5 PHASE dawn
6 EMBER A 1 1
7 EMBER B 0 0
8 PHASE draw
9 PHASE main1
VAULT BEGIN
vault A 1 #6 LOM-001
vault A 2 #8 DSK-001
vault A 3 #5 TID-002
vault A 4 #2 CIN-002
vault A 5 #4 TID-001
vault A 6 #1 CIN-001
vault A 7 #3 CIN-003
vault A 8 #7 LOM-002
vault B 1 #16 DSK-001
vault B 2 #14 LOM-001
vault B 3 #9 CIN-001
vault B 4 #15 LOM-002
vault B 5 #10 CIN-002
vault B 6 #11 CIN-003
vault B 7 #12 TID-001
vault B 8 #13 TID-002
VAULT END
10 RESULT pending none
EOS");
    }

    unittest // examples_spec_26_13_winning_on_spire
    {
        golden(q"EOS
CARDS mem:cards
SEED 1
SPIRE 2
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003
START
A PLAY 1 B
A PASS
B PASS
A PASS
EOS", q"EOS
1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #2 CIN-003 B
9 PAY A ember 1
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DAMAGE #2 B 2
14 SPIRE B -2 0
15 SPENT #2 CIN-003
16 LOSE B spire
17 RESULT A spire
ERR 13 game-over
EOS");
    }

}
