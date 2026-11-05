/**
 * Typed card model: cards, abilities and the effect-language syntax tree.
 *
 * The database parser (`cardgame.parser`) converts s-expressions into these
 * pre-resolved structures once, so the game engine never compares strings
 * while interpreting abilities.
 */
module cardgame.cards;

import cardgame.sexpr;

/// Card types (SPEC 5.2).
enum CardType : ubyte
{
    unit,
    rite,
    relic,
}

/// The sixteen keywords (SPEC 16).
enum Keyword : ubyte
{
    swift,
    vanguard,
    vigil,
    riposte,
    pierce,
    ghostwalk,
    skyhook,
    venom,
    siphon,
    plating,
    provoke,
    spectral,
    tenacity,
    siegework,
    shackled,
    relentless,
}

/// A keyword instance; `value` is only meaningful for `plating`.
struct Kw
{
    Keyword kind;
    long value;
}

/// Comparators (SPEC 6.1).
enum Cmp : ubyte
{
    le,
    lt,
    eq,
    ge,
    gt,
    ne,
}

/// Evaluate `left <cmp> right`.
bool compare(Cmp c, long left, long right) @safe pure nothrow @nogc
{
    final switch (c)
    {
    case Cmp.le:
        return left <= right;
    case Cmp.lt:
        return left < right;
    case Cmp.eq:
        return left == right;
    case Cmp.ge:
        return left >= right;
    case Cmp.gt:
        return left > right;
    case Cmp.ne:
        return left != right;
    }
}

/// Selector scopes (SPEC 6.3).
enum ScopeKind : ubyte
{
    yours,
    theirs,
    all,
}

/// Where an object currently is.
enum ZoneKind : ubyte
{
    none,
    vault,
    hand,
    field,
    ash,
    rift,
    chain,
}

/// Trigger events (SPEC 13.1).
enum Event : ubyte
{
    arrive,
    leave,
    dies,
    allyArrive,
    enemyArrive,
    allyDies,
    enemyDies,
    turnStart,
    yourTurnStart,
    turnEnd,
    yourTurnEnd,
    attacks,
    blocks,
    blocked,
    unblocked,
    damaged,
    dealsDamage,
    youPlayRite,
    enemyPlaysRite,
    youDraw,
    spireLoss,
    enemySpireLoss,
    endOfCombat,
}

/// Delayed-trigger timings (SPEC 6.8, 13.5).
enum DelayWhen : ubyte
{
    turnEnd,
    endOfCombat,
    yourNextTurnStart,
}

/// Selector forms: object selectors (6.3) and player selectors (6.4).
enum SelKind : ubyte
{
    self,
    it,
    that,
    target,
    units,
    relics,
    cards,
    randomUnit,
    you,
    foe,
    both,
    ownerOf,
}

/// Filter forms (6.5).
enum FilterKind : ubyte
{
    kw,
    noKw,
    tag,
    type,
    cost,
    edge,
    core,
    wounded,
    ready,
    exhausted,
    settling,
    attacking,
    blocking,
    mine,
    enemy,
    other,
    not,
}

/// A predicate over objects; also used as a "card filter" by `cheaper`.
final class Filter
{
    FilterKind kind;
    Keyword kw;
    int tag = -1;
    CardType type;
    Cmp cmp;
    long n;
    Filter inner;
}

/// A selector (object, player or damage selector, depending on context).
final class Sel
{
    SelKind kind;
    /// Target number for `(t n)`.
    int n;
    ScopeKind scp;
    ZoneKind zone;
    Filter[] filters;
    Sel inner;
}

/// Amount forms (6.6).
enum AmtKind : ubyte
{
    constant,
    count,
    hand,
    ash,
    vault,
    edge,
    core,
    wounds,
}

/// An integer-valued expression.
final class Amt
{
    AmtKind kind;
    long value;
    Sel sel;
}

/// Condition forms (6.7).
enum CondKind : ubyte
{
    count,
    spire,
    hand,
    ash,
    vault,
    ember,
    myturn,
    and,
    or,
    not,
}

/// A boolean expression.
final class Cond
{
    CondKind kind;
    Sel sel;
    Cmp cmp;
    long n;
    Cond[] subs;
}

/// Effect forms (6.8).
enum EffKind : ubyte
{
    damage,
    destroy,
    sacrifice,
    exile,
    bounce,
    draw,
    discard,
    mill,
    spire,
    ember,
    cap,
    modify,
    setbody,
    swapstats,
    grant,
    strip,
    control,
    counters,
    ready,
    exhaust,
    doom,
    ward,
    shield,
    summon,
    conjure,
    reanimate,
    recall,
    negate,
    dig,
    delay,
    ifElse,
    each,
    repeat,
    nothing,
}

/// One node of an effect tree; fields are used according to `kind`.
final class Effect
{
    EffKind kind;
    Amt a, b;
    Sel sel;
    Kw kw;
    /// Index into `CardDb.cards` for `summon`/`conjure`.
    int cardIdx = -1;
    string cardId;
    Cond cond;
    /// Body of `delay`, `each`, `repeat`, and the "then" branch of `if`.
    Effect[] body_;
    /// The "else" branch of `if`.
    Effect[] elseBody;
    /// `dig` filters.
    Filter[] filters;
    /// `dig` depth.
    long k;
    DelayWhen when;
}

/// Static forms of an `aura` clause (6.11).
enum StKind : ubyte
{
    modify,
    setbody,
    swapstats,
    grant,
    cheaper,
    when,
}

/// A continuous-effect description.
final class Static
{
    StKind kind;
    Amt a, b;
    Sel sel;
    Kw kw;
    /// Reduction of `cheaper`.
    long n;
    Filter[] cardFilters;
    Cond cond;
    Static[] subs;
}

/// Target specification forms (12.1).
enum TKind : ubyte
{
    unit,
    relic,
    any,
    player,
    chained,
    ashcard,
}

/// One entry of a `targets` clause.
final class TSpec
{
    TKind kind;
    Filter[] filters;
}

/// Activated-ability cost items (6.10).
enum CostKind : ubyte
{
    ember,
    spire,
    discard,
    exhaust,
    sacself,
    counters,
    once,
}

/// One payment of an `act` cost.
struct CostItem
{
    CostKind kind;
    long n;
}

/// The four ability clause kinds, in numbering order (5.3).
enum AbilKind : ubyte
{
    resolve,
    on,
    act,
    aura,
}

/// Kinds of mutable game state an aura's evaluation can observe (SPEC 14.3 / APPROACH 7).
enum Dep : uint
{
    none = 0,
    wounds = 1,
    ready = 2,
    combat = 4,
    turn = 8,
    spire = 16,
    ember = 32,
    zones = 64,
}

/// One numbered ability of a card.
final class Ability
{
    /// For auras: union of `Dep` bits the statics read.
    uint deps;
    AbilKind kind;
    Event event;
    CostItem[] costs;
    TSpec[] targets;
    Effect[] effects;
    Static[] statics;
    /// Raw clauses retained for the canonical `CARD` printer.
    SExpr costRaw;
    SExpr targetsRaw;
    SExpr[] bodyRaw;
}

/// A card definition.
final class Card
{
    /// Position in `CardDb.cards`.
    int index;
    string id;
    string name;
    CardType type;
    long cost;
    long edge, core;
    string[] tags;
    int[] tagIds;
    Kw[] keywords;
    string text;
    bool hasText;
    /// Abilities in SPEC 5.3 numbering order (ability number n is `abilities[n-1]`).
    Ability[] abilities;
    /// Bit `e` is set when some `on` ability listens for `Event` `e`.
    uint eventMask;

    /// True when the printed keywords include `k`.
    bool hasKeyword(Keyword k) const @safe pure nothrow @nogc
    {
        foreach (w; keywords)
            if (w.kind == k)
                return true;
        return false;
    }
}

/// A validated card database.
final class CardDb
{
    Card[] cards;
    int[string] byId;
    int[string] tagIndex;

    /// Look a card up by id, or return null.
    Card find(string id) @safe pure nothrow
    {
        if (auto p = id in byId)
            return cards[*p];
        return null;
    }

    /// Intern a tag name.
    int internTag(string name) @safe pure nothrow
    {
        if (auto p = name in tagIndex)
            return *p;
        immutable id = cast(int) tagIndex.length;
        tagIndex[name] = id;
        return id;
    }
}

/// Name of a keyword as written in the database.
string keywordName(Keyword k) @safe pure nothrow @nogc
{
    static immutable string[16] names = [
        "swift", "vanguard", "vigil", "riposte", "pierce", "ghostwalk", "skyhook",
        "venom", "siphon", "plating", "provoke", "spectral", "tenacity", "siegework",
        "shackled", "relentless"
    ];
    return names[k];
}

/// Name of an event as written in the database.
string eventName(Event e) @safe pure nothrow @nogc
{
    static immutable string[23] names = [
        "arrive", "leave", "dies", "ally-arrive", "enemy-arrive", "ally-dies",
        "enemy-dies", "turn-start", "your-turn-start", "turn-end", "your-turn-end",
        "attacks", "blocks", "blocked", "unblocked", "damaged", "deals-damage",
        "you-play-rite", "enemy-plays-rite", "you-draw", "spire-loss",
        "enemy-spire-loss", "end-of-combat"
    ];
    return names[e];
}

/// Name of a delayed-trigger timing.
string delayName(DelayWhen w) @safe pure nothrow @nogc
{
    static immutable string[3] names = ["turn-end", "end-of-combat", "your-next-turn-start"];
    return names[w];
}
