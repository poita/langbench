/// Shared helpers for the unit tests: a tiny in-memory card database and a
/// one-call match runner.
module tests.util;

import std.array : join;

import cardgame.match : simulate;

/// A small database exercising units, rites, relics, auras, triggers and costs.
enum testDb = `
; test database
(card TST-001 (name "Runner") (type unit) (cost 1) (body 2 1) (tags test runner) (keywords vanguard))
(card TST-002 (name "Bolt") (type rite) (cost 1) (tags test) (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))
(card TST-003 (name "Mote") (type unit) (cost 0) (body 1 1) (tags test))
(card TST-004 (name "Duelist") (type unit) (cost 2) (body 2 1) (tags test) (keywords riposte))
(card TST-005 (name "Banner") (type relic) (cost 2) (tags test)
  (aura (modify 1 1 (units yours))))
(card TST-006 (name "Knight") (type unit) (cost 4) (body 3 3) (tags test) (keywords tenacity))
(card TST-007 (name "Lance") (type rite) (cost 2) (tags test)
  (resolve (targets (unit)) (damage 3 (t 1))))
(card TST-008 (name "Undertow") (type rite) (cost 1) (tags test) (keywords swift)
  (resolve (targets (unit)) (bounce (t 1))))
(card TST-009 (name "Sentinel") (type unit) (cost 4) (body 3 4) (tags test)
  (on ally-dies (damage 1 foe)))
(card TST-010 (name "Harvester") (type unit) (cost 3) (body 2 2) (tags test undead)
  (on spire-loss (counters 1 self))
  (act (cost (exhaust) (spire 2)) (targets (unit)) (damage 2 (t 1))))
(card TST-011 (name "Shadow") (type rite) (cost 2) (tags test)
  (resolve (targets (unit)) (destroy (t 1))))
`;

/// Run a match against `testDb` (or another database text) and return the log.
string runMatch(string[] lines, string db = testDb)
{
    return simulate(lines.join("\n") ~ "\n", (string path) {
        if (path == "db")
            return db;
        throw new Exception("no such file");
    });
}

/// The usual quiet setup: seed 1, no shuffling, no opening hands, Spire 10.
enum string[] quietSetup = [
    "CARDS db", "SEED 1", "SPIRE 10", "OPENING 0", "SHUFFLE off",
];
