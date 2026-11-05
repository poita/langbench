/// Unit tests for the card-database reader and validator.
module tests.parser_test;

import std.exception : assertThrown, assertNotThrown;

import cardgame.cards;
import cardgame.parser;

import tests.util : testDb;

unittest
{
    auto db = parseDatabase(testDb);
    assert(db.cards.length == 11);
    auto bolt = db.find("TST-002");
    assert(bolt !is null);
    assert(bolt.type == CardType.rite);
    assert(bolt.hasKeyword(Keyword.swift));
    assert(bolt.abilities.length == 1);
    assert(bolt.abilities[0].kind == AbilKind.resolve);
    assert(bolt.abilities[0].targets.length == 1);
    assert(db.find("NOP-000") is null);
}

unittest
{
    // Ability numbering: resolve, then on, then act, then aura (SPEC 5.3).
    auto db = parseDatabase(`
        (card AAA-001 (name "X") (type unit) (cost 1) (body 1 1)
          (aura (modify 1 1 self))
          (act (cost (once)) (draw 1 you))
          (on arrive (draw 1 you)))`);
    auto c = db.find("AAA-001");
    assert(c.abilities.length == 3);
    assert(c.abilities[0].kind == AbilKind.on);
    assert(c.abilities[1].kind == AbilKind.act);
    assert(c.abilities[2].kind == AbilKind.aura);
    assert(c.eventMask == 1u << Event.arrive);
}

unittest
{
    // The empty database is valid.
    assert(parseDatabase("; nothing\n").cards.length == 0);
}

unittest
{
    // Aura dependency bits are derived from the statics.
    auto db = parseDatabase(`
        (card AAA-001 (name "X") (type relic) (cost 1)
          (aura (when (myturn) (modify 1 0 (units yours (wounded))))))`);
    auto deps = db.find("AAA-001").abilities[0].deps;
    assert(deps & Dep.turn);
    assert(deps & Dep.wounds);
    assert(!(deps & Dep.spire));
}

private void rejects(string text, string file = __FILE__, size_t line = __LINE__)
{
    assertThrown!DatabaseError(parseDatabase(text), "should be rejected", file, line);
}

unittest
{
    // Lexical and structural errors.
    rejects(`(card AAA-001 (name "One") (type unit) (cost 0) (body 1 1)`);
    rejects(`(card AAA-001 (name "One) (type unit) (cost 0) (body 1 1))`);
    rejects(`card (card AAA-001 (name "One") (type unit) (cost 0) (body 1 1))`);
    rejects(`(deck AAA-001 (name "One") (type unit) (cost 0) (body 1 1))`);
    rejects(`(card aaa-001 (name "One") (type unit) (cost 0) (body 1 1))`);
    rejects(`(card AAA-0012 (name "One") (type unit) (cost 0) (body 1 1))`);
    rejects(`(card AAA-001 (name "One") (type unit) (cost 99999999999999999999) (body 1 1))`);
}

unittest
{
    // Clause rules.
    enum head = `(card AAA-001 `;
    rejects(head ~ `(type unit) (cost 0) (body 1 1))`);
    rejects(head ~ `(name "A") (name "B") (type unit) (cost 0) (body 1 1))`);
    rejects(head ~ `(name "A") (type creature) (cost 0) (body 1 1))`);
    rejects(head ~ `(name "A") (type unit) (cost -1) (body 1 1))`);
    rejects(head ~ `(name "A") (type unit) (cost 0))`);
    rejects(head ~ `(name "A") (type unit) (cost 0) (body 1 -1))`);
    rejects(head ~ `(name "A") (type rite) (cost 1) (body 1 1) (resolve (nothing)))`);
    rejects(head ~ `(name "A") (type rite) (cost 1))`);
    rejects(head ~ `(name "A") (type unit) (cost 0) (body 1 1) (resolve (nothing)))`);
    rejects(head ~ `(name "A") (type unit) (cost 0) (body 1 1) (text "a") (text "b"))`);
    rejects(head ~ `(name "A") (type unit) (cost 0) (body 1 1) (flavour "hi"))`);
    rejects(head ~ `(name "A") (type unit) (cost 0) (body 1 1) (tags "loud"))`);
}

unittest
{
    // Keyword legality.
    enum unit = `(card AAA-001 (name "A") (type unit) (cost 0) (body 1 1) `;
    assertNotThrown!DatabaseError(parseDatabase(unit ~ `(keywords vanguard (plating 2)))`));
    rejects(unit ~ `(keywords swift))`);
    rejects(unit ~ `(keywords flying))`);
    rejects(unit ~ `(keywords plating))`);
    rejects(`(card AAA-001 (name "A") (type relic) (cost 0) (keywords vanguard) (aura (modify 1 1 self)))`);
    rejects(`(card AAA-001 (name "A") (type rite) (cost 0) (keywords venom) (resolve (nothing)))`);
    assertNotThrown!DatabaseError(parseDatabase(
            `(card AAA-001 (name "A") (type rite) (cost 0) (keywords swift) (resolve (nothing)))`));
}

unittest
{
    // Ability structure.
    enum unit = `(card AAA-001 (name "A") (type unit) (cost 0) (body 1 1) `;
    rejects(unit ~ `(act (draw 1 you)))`);
    rejects(unit ~ `(act (cost (ember 1))))`);
    rejects(unit ~ `(act (cost (ember 1)) (cost (ember 2)) (draw 1 you)))`);
    rejects(unit ~ `(act (cost (tap)) (draw 1 you)))`);
    rejects(unit ~ `(on arrive))`);
    rejects(unit ~ `(on sunrise (draw 1 you)))`);
    rejects(unit ~ `(on arrive (cost (ember 1)) (draw 1 you)))`);
    rejects(unit ~ `(on arrive (draw 1 you) (targets (unit))))`);
    rejects(unit ~ `(on arrive (targets (unit)) (targets (unit)) (draw 1 you)))`);
    rejects(unit ~ `(aura))`);
    rejects(unit ~ `(aura (destroy (units theirs))))`);
    rejects(unit ~ `(on arrive (targets (planet)) (draw 1 you)))`);
}

unittest
{
    // Effect, selector, filter, amount and condition forms.
    enum rite = `(card AAA-001 (name "A") (type rite) (cost 1) (resolve `;
    rejects(rite ~ `(explode 2 foe)))`);
    rejects(rite ~ `(damage 2)))`);
    rejects(rite ~ `(draw 1 everyone)))`);
    rejects(rite ~ `(destroy (units mine))))`);
    rejects(rite ~ `(destroy (units all (colour red)))))`);
    rejects(rite ~ `(damage 2 (units theirs (cost gte 2)))))`);
    rejects(rite ~ `(negate self)))`);
    rejects(rite ~ `(if (myturn) (draw 1 you))))`);
    rejects(rite ~ `(delay sunset (draw 1 you))))`);
    rejects(rite ~ `(dig (hand you) ((type unit)) you)))`);
    rejects(rite ~ `(summon BBB-002 1 you)))`);
    assertNotThrown!DatabaseError(parseDatabase(rite ~ `(if (or (ember you ge 3) (not (myturn)))
        ((ember 1 you)) ((cap 2 both))) (each (units all (not (kw plating))) (counters 1 that))
        (dig 3 ((type unit)) you) (delay turn-end (draw 1 you)) (repeat (count (units yours)) (nothing))))`));
}

unittest
{
    // summon and conjure must name defined cards; summoning a rite is invalid.
    rejects(`(card AAA-001 (name "A") (type rite) (cost 1) (resolve (conjure ZZZ-404 1 you)))`);
    rejects(`(card AAA-001 (name "A") (type rite) (cost 1) (resolve (summon AAA-002 1 you)))
             (card AAA-002 (name "B") (type rite) (cost 1) (resolve (nothing)))`);
    // Conjuring a rite, and a forward reference to a unit, are fine.
    assertNotThrown!DatabaseError(parseDatabase(
            `(card AAA-001 (name "A") (type rite) (cost 1) (resolve (conjure AAA-002 1 you) (summon AAA-003 1 you)))
             (card AAA-002 (name "B") (type rite) (cost 1) (resolve (nothing)))
             (card AAA-003 (name "C") (type unit) (cost 1) (body 1 1))`));
}

unittest
{
    // Duplicate ids are rejected.
    rejects(`(card AAA-001 (name "A") (type unit) (cost 0) (body 1 1))
             (card AAA-001 (name "B") (type unit) (cost 1) (body 2 2))`);
}
