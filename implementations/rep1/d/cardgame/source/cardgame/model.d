/**
 * The typed card model: cards, abilities, and the tree of effects, selectors,
 * filters, amounts, conditions and statics that the interpreter walks
 * (SPEC.md sections 5 and 6).
 */
module cardgame.model;

import cardgame.sexpr : SExpr;

/// The two players.
enum Player : ubyte { A = 0, B = 1 }

/// The opponent of `p`.
Player opponent(Player p) pure nothrow @safe @nogc { return p == Player.A ? Player.B : Player.A; }

/// `"A"` or `"B"`.
string playerName(Player p) pure nothrow @safe @nogc { return p == Player.A ? "A" : "B"; }

/// Card types.
enum CardType : ubyte { unit, rite, relic }

/// The sixteen keywords.
enum Kw : ubyte
{
    vanguard, vigil, riposte, pierce, ghostwalk, skyhook, venom, siphon,
    plating, provoke, spectral, tenacity, siegework, shackled, relentless, swift
}

/// A keyword instance; `value` is only meaningful for `plating`.
struct KwSpec
{
    Kw kw;
    int value;

    /// Render as in `GRANT` events and `CARD` blocks.
    string render() const @safe
    {
        import std.conv : to;
        if (kw == Kw.plating) return "plating:" ~ value.to!string;
        return kw.to!string;
    }
}

/// Look up a keyword by name.
bool keywordFromName(string s, out Kw k) pure nothrow @safe
{
    foreach (i, n; keywordNames)
        if (n == s) { k = cast(Kw) i; return true; }
    return false;
}

/// Keyword names indexed by `Kw`.
immutable string[] keywordNames = [
    "vanguard", "vigil", "riposte", "pierce", "ghostwalk", "skyhook", "venom", "siphon",
    "plating", "provoke", "spectral", "tenacity", "siegework", "shackled", "relentless", "swift"];

/// Comparators of section 6.1.
enum Cmp : ubyte { le, lt, eq, ge, gt, ne }

/// Apply a comparator: `l <cmp> r`.
bool compare(long l, Cmp c, long r) pure nothrow @safe @nogc
{
    final switch (c)
    {
    case Cmp.le: return l <= r;
    case Cmp.lt: return l < r;
    case Cmp.eq: return l == r;
    case Cmp.ge: return l >= r;
    case Cmp.gt: return l > r;
    case Cmp.ne: return l != r;
    }
}

/// Selector scopes.
enum Scope : ubyte { yours, theirs, all }

/// Zones an object can be in. `chain` is used while a played card waits on the Chain.
enum Zone : ubyte { none, vault, hand, field, ash, rift, chain }

/// Lower-case zone name as used in `EXILE`/`CREATE` events.
string zoneName(Zone z) pure nothrow @safe @nogc
{
    final switch (z)
    {
    case Zone.none: return "none";
    case Zone.vault: return "vault";
    case Zone.hand: return "hand";
    case Zone.field: return "field";
    case Zone.ash: return "ash";
    case Zone.rift: return "rift";
    case Zone.chain: return "chain";
    }
}

/// Triggered-ability events (section 13.1).
enum Event : ubyte
{
    arrive, leave, dies, allyArrive, enemyArrive, allyDies, enemyDies,
    turnStart, yourTurnStart, turnEnd, yourTurnEnd, attacks, blocks, blocked,
    unblocked, damaged, dealsDamage, youPlayRite, enemyPlaysRite, youDraw,
    spireLoss, enemySpireLoss, endOfCombat
}

/// Source-text names of the events, indexed by `Event`.
immutable string[] eventNames = [
    "arrive", "leave", "dies", "ally-arrive", "enemy-arrive", "ally-dies", "enemy-dies",
    "turn-start", "your-turn-start", "turn-end", "your-turn-end", "attacks", "blocks", "blocked",
    "unblocked", "damaged", "deals-damage", "you-play-rite", "enemy-plays-rite", "you-draw",
    "spire-loss", "enemy-spire-loss", "end-of-combat"];

/// When a delayed trigger fires.
enum When : ubyte { turnEnd, endOfCombat, yourNextTurnStart }

/// Source-text names, indexed by `When`.
immutable string[] whenNames = ["turn-end", "end-of-combat", "your-next-turn-start"];

// ---------------------------------------------------------------- filters

/// A predicate over objects (section 6.5).
final class Filter
{
    enum Kind : ubyte
    {
        kw, noKw, tag, type, cost, edge, core, wounded, ready, exhausted,
        settling, attacking, blocking, mine, enemy, other, not
    }
    Kind kind;
    Kw kw;
    string tag;
    CardType type;
    Cmp cmp;
    long n;
    Filter inner;
}

// ---------------------------------------------------------------- selectors

/// Selector of objects (section 6.3).
final class Selector
{
    enum Kind : ubyte { self, it, that, target, units, relics, cards, randomUnit }
    Kind kind;
    int n;          // target number for `(t n)`
    Scope scope_;
    Zone zone;      // for `cards`
    Filter[] filters;
}

/// Selector of players (section 6.4).
final class PSel
{
    enum Kind : ubyte { you, foe, both, target, ownerOf }
    Kind kind;
    int n;
    Selector inner; // for ownerOf
}

/// Damage selector (section 6.4.1).
final class DSel
{
    enum Kind : ubyte { player, object, target }
    Kind kind;
    PSel player;
    Selector object;
    int n;
}

// ---------------------------------------------------------------- amounts

/// Integer-valued expressions (section 6.6).
final class Amount
{
    enum Kind : ubyte { literal, count, hand, ash, vault, edge, core, wounds }
    Kind kind;
    long value;
    Selector sel;
    PSel psel;
}

/// Boolean expressions (section 6.7).
final class Cond
{
    enum Kind : ubyte { count, spire, hand, ash, vault, ember, myturn, and, or, not }
    Kind kind;
    Selector sel;
    PSel psel;
    Cmp cmp;
    long value;
    Cond[] subs;
}

// ---------------------------------------------------------------- effects

/// An effect form (section 6.8).
final class Effect
{
    enum Kind : ubyte
    {
        damage, destroy, sacrifice, exile, bounce, draw, discard, mill, spire,
        ember, cap, modify, setbody, swapstats, grant, strip, control, counters,
        ready, exhaust, doom, ward, shield, summon, conjure, reanimate, recall,
        negate, dig, delay, if_, each, repeat, nothing
    }
    Kind kind;
    Amount amt, amt2;
    Selector sel;
    PSel psel;
    DSel dsel;
    KwSpec kw;
    string cardId;
    Cond cond;
    Effect[] body_, elseBody;
    long digCount;
    Filter[] digFilters;
    When when;
    SExpr raw;
}

/// Statics of an `aura` clause (section 6.11).
final class Static
{
    enum Kind : ubyte { modify, setbody, swapstats, grant, cheaper, when }
    Kind kind;
    Amount amt, amt2;
    Selector sel;
    KwSpec kw;
    long cheaperBy;
    Filter[] cardFilters;
    Cond cond;
    Static[] inner;
}

/// A cost item of an activated ability (section 6.10).
struct CostItem
{
    enum Kind : ubyte { ember, spire, discard, exhaust, sacself, counters, once }
    Kind kind;
    long n;
}

/// Target specification (section 12.1).
final class TSpec
{
    enum Kind : ubyte { unit, relic, any, player, chained, ashcard }
    Kind kind;
    Filter[] filters;
}

// ---------------------------------------------------------------- cards

/// The four kinds of ability a card can have.
enum AbilityKind : ubyte { resolve, on, act, aura }

/// One numbered ability of a card.
final class Ability
{
    AbilityKind kind;
    int index;                 /// 1-based ability number
    Event event;               /// for `on`
    SExpr costClause;          /// printed as given; valid when `hasCost`
    bool hasCost;
    CostItem[] costs;
    SExpr targetsClause;       /// valid when `hasTargets`
    bool hasTargets;
    TSpec[] targets;
    Effect[] effects;
    Static[] statics;
    SExpr[] rawParts;          /// effect or static forms, for the `CARD` printer
}

/// A card definition.
final class Card
{
    string id;
    string name;
    CardType type;
    long cost;
    long edge, core;           /// printed body (0/0 for non-units)
    string[] tags;
    KwSpec[] keywords;         /// printed keywords, in file order
    uint kwMask;               /// bit per `Kw` among the printed keywords
    string text;
    Ability[] abilities;       /// numbered abilities (index 0 is ability 1)

    /// Whether the printed keywords include `k`.
    bool hasKeyword(Kw k) const pure nothrow @safe @nogc { return (kwMask >> k) & 1; }
}
