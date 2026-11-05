/**
 * Game state: objects, zones, players, the Chain and the event log.
 *
 * This module holds data and trivial accessors only; the rules live in
 * `cardgame.derive`, `cardgame.actions`, `cardgame.effects` and
 * `cardgame.engine`.
 */
module cardgame.game;

import std.algorithm : remove;
import std.array : Appender, appender;

import cardgame.cards;
import cardgame.derive;
import cardgame.rng;

/// Turn phases and steps in order (SPEC 9).
enum Phase : ubyte
{
    dawn,
    draw,
    main1,
    clashAttack,
    clashBlock,
    clashRiposte,
    clashDamage,
    clashEnd,
    main2,
    duskTrigger,
    duskDiscard,
    duskCleanup,
}

/// Printed names of the phases.
immutable string[12] phaseNames = [
    "dawn", "draw", "main1", "clash-attack", "clash-block", "clash-riposte",
    "clash-damage", "clash-end", "main2", "dusk-trigger", "dusk-discard",
    "dusk-cleanup"
];

/// Where the turn machine goes next when it is not waiting for input.
enum Step : ubyte
{
    turnStart,
    dawn,
    draw,
    main1,
    clashAttack,
    clashBlock,
    clashRiposte,
    clashDamage,
    clashEnd,
    main2,
    duskTrigger,
    duskDiscard,
    duskCleanup,
    turnAdvance,
}

/// What kind of input the engine is waiting for (SPEC 10.2).
enum DecKind : ubyte
{
    none,
    priority,
    attackers,
    blockers,
}

/// Reasons a player can lose (SPEC 20).
enum Loss : ubyte
{
    none,
    spire,
    vault,
    concede,
}

/// Names of loss reasons.
immutable string[4] lossNames = ["none", "spire", "vault", "concede"];

/// Automatic block printed after every accepted action.
enum TraceMode : ubyte
{
    none,
    legal,
    state,
}

/// Match configuration (SPEC 4.1).
struct Config
{
    string cardsPath;
    ulong seed;
    int spire = 25;
    int opening = 5;
    int maxCap = 10;
    int handMax = 7;
    int turnLimit = 200;
    int first = 0;
    bool shuffle = true;
    TraceMode trace = TraceMode.none;
    int[2] cap;
}

/// A rendered-target token: a player, an object, or a Chain entry.
struct Target
{
    ubyte kind; // 0 player, 1 object, 2 Chain entry
    int id;

    static Target player(int p) @safe pure nothrow @nogc
    {
        return Target(0, p);
    }

    static Target object(int oid) @safe pure nothrow @nogc
    {
        return Target(1, oid);
    }

    static Target chain(int cid) @safe pure nothrow @nogc
    {
        return Target(2, cid);
    }
}

/// Trigger subject (`it`): nothing, an object, or a player.
struct Subject
{
    ubyte kind; // 0 none, 1 object, 2 player
    int id;

    static Subject obj(int oid) @safe pure nothrow @nogc
    {
        return Subject(1, oid);
    }

    static Subject player(int p) @safe pure nothrow @nogc
    {
        return Subject(2, p);
    }
}

/// An object (card instance) of the match.
struct Obj
{
    int card;
    ubyte owner;
    ZoneKind zone;
    int ts;
    /// Base controller while on the Field; last controller afterwards.
    ubyte ctrl;

    // Field state (SPEC 7.5).
    bool exhausted, doomed, attacking, blocking, blocked, tenUsed;
    int wounds, counters, ward, since;
    int blockTarget;
    ulong onceMask;
    int[] blockers;

    // Derived characteristics (valid for Field objects when not stale).
    ubyte cur;
    bool stripped;
    long edge, core;
    Kw[] kws;
}

/// Kinds of continuous-effect record (SPEC 14.1).
enum RecKind : ubyte
{
    modify,
    setbody,
    swapstats,
    grant,
    strip,
    control,
    cheaper,
}

/// Result of evaluating one aura static at the latest derivation.
struct Leaf
{
    StKind kind;
    bool active;
    long a, b;
    Kw kw;
    long n;
    Filter[] cardFilters;
    int[] affected;
}

/// A continuous-effect record, discrete or aura.
final class Rec
{
    int eid, ts, ctrl, src;
    RecKind kind;
    bool aura;
    long a, b;
    Kw kw;
    long n;
    /// Affected objects of a discrete record.
    int[] affected;
    /// Aura clause and its leaves from the latest derivation.
    Ability ability;
    Leaf[] leaves;
}

/// Kinds of Chain entry.
enum EntryKind : ubyte
{
    rite,
    unit,
    relic,
    ability,
    trigger,
}

/// Printed names of entry kinds.
immutable string[5] entryKindNames = ["rite", "unit", "relic", "ability", "trigger"];

/// An entry on the Chain.
final class Entry
{
    int cid;
    EntryKind kind;
    int ctrl;
    int src;
    int abil;
    Target[] targets;
    bool[] removed;
    TSpec[] specs;
    /// Effects of a delayed trigger (abil == 0 and kind == trigger).
    Effect[] delayedEffects;
    Subject it;
}

/// A delayed trigger waiting for its timing (SPEC 13.5).
final class Delayed
{
    int ts, ctrl, src;
    DelayWhen when;
    Effect[] effects;
    Target[] targets;
    TSpec[] specs;
}

/// A collected trigger awaiting the next push.
struct Pending
{
    int side; // 0 when the controller is the active player, else 1
    int ts, oid, abil;
    int ctrl;
    Subject it;
    Delayed delayed;
    int seq;
}

/// Renders as `#oid`.
struct O
{
    int v;
}

/// Renders as `~cid`.
struct Q
{
    int v;
}

/// Renders as `A` or `B`.
struct Pl
{
    int v;
}

/// Renders with an explicit sign.
struct Sg
{
    long v;
}

/// The complete state of one match.
final class Game
{
    CardDb db;
    Config cfg;
    Rng rng;

    Appender!(char[]) outBuf;
    int seq;

    Obj[] objs;
    int[][2] vault, hand, ash, rift;
    int[] field;
    Entry[] chain;
    Rec[] recs;
    Delayed[] delayed;
    Pending[] pending;
    int pendingSeq;

    int[2] spire, ember, cap, shield;
    int turn = 1;
    int active;
    int first;
    int nextOid = 1;
    int nextCid = 1;
    int nextEid = 1;
    int nextTs = 1;

    Phase phase = Phase.dawn;
    Step next = Step.turnStart;
    DecKind dec = DecKind.none;
    int holder;
    int passCount;
    /// Units that dealt their combat damage in the riposte sub-step.
    int[] riposters;

    bool over;
    Loss[2] loss;
    bool turnLimitDraw;
    string resultWinner = "";
    string resultReason = "";

    bool stale = true;
    bool deriving;
    /// Union of the `Dep` bits read by live aura records.
    uint liveDeps;

    this(CardDb db, Config cfg)
    {
        this.db = db;
        this.cfg = cfg;
        objs = new Obj[](1);
        outBuf = appender!(char[])();
        outBuf.reserve(1 << 16);
        first = cfg.first;
        active = cfg.first;
        spire[] = cfg.spire;
        cap = cfg.cap;
    }

    /// Mark derived characteristics out of date (structural change).
    void touch() @safe pure nothrow @nogc
    {
        stale = true;
    }

    /// Mark derived characteristics out of date only if a live aura reads `bits`.
    void touchDep(uint bits) @safe pure nothrow @nogc
    {
        if (liveDeps & bits)
            stale = true;
    }

    /// The card of an object.
    Card cardOf(int oid) @safe pure nothrow
    {
        return db.cards[objs[oid].card];
    }

    /// Allocate a new object of the given card owned by `owner`.
    int newObject(int cardIdx, int owner)
    {
        Obj o;
        o.card = cardIdx;
        o.owner = cast(ubyte) owner;
        o.ctrl = cast(ubyte) owner;
        o.cur = cast(ubyte) owner;
        o.zone = ZoneKind.none;
        objs ~= o;
        return nextOid++;
    }

    /// Fresh timestamp.
    int takeTs() @safe pure nothrow @nogc
    {
        return nextTs++;
    }

    /// Current controller (Field) or last controller (elsewhere).
    int ctl(int oid)
    {
        if (objs[oid].zone == ZoneKind.field)
        {
            ensureDerived(this);
            return objs[oid].cur;
        }
        return objs[oid].ctrl;
    }

    /// True when the object is on the Field.
    bool onField(int oid) const @safe pure nothrow @nogc
    {
        return oid > 0 && oid < objs.length && objs[oid].zone == ZoneKind.field;
    }

    /// Does the object exist?
    bool exists(long oid) const @safe pure nothrow @nogc
    {
        return oid > 0 && oid < objs.length;
    }

    /// Current edge of an object (printed outside the Field).
    long edgeOf(int oid)
    {
        if (objs[oid].zone == ZoneKind.field)
        {
            ensureDerived(this);
            return objs[oid].edge;
        }
        return cardOf(oid).edge;
    }

    /// Current core of an object (printed outside the Field).
    long coreOf(int oid)
    {
        if (objs[oid].zone == ZoneKind.field)
        {
            ensureDerived(this);
            return objs[oid].core;
        }
        return cardOf(oid).core;
    }

    /// Base edge: printed edge plus charge counters.
    long baseEdge(int oid)
    {
        return cardOf(oid).edge + objs[oid].counters;
    }

    /// Base core: printed core plus charge counters.
    long baseCore(int oid)
    {
        return cardOf(oid).core + objs[oid].counters;
    }

    /// Does the object currently have keyword `k`?
    bool hasKw(int oid, Keyword k)
    {
        if (objs[oid].zone == ZoneKind.field)
        {
            ensureDerived(this);
            foreach (w; objs[oid].kws)
                if (w.kind == k)
                    return true;
            return false;
        }
        return cardOf(oid).hasKeyword(k);
    }

    /// Sum of the `plating` values among the current keywords.
    long plating(int oid)
    {
        long s = 0;
        if (objs[oid].zone == ZoneKind.field)
        {
            ensureDerived(this);
            foreach (w; objs[oid].kws)
                if (w.kind == Keyword.plating)
                    s += w.value;
        }
        else
            foreach (w; cardOf(oid).keywords)
                if (w.kind == Keyword.plating)
                    s += w.value;
        return s;
    }

    /// Are the object's abilities removed by `strip`? Only meaningful on the Field.
    bool isStripped(int oid)
    {
        if (objs[oid].zone != ZoneKind.field)
            return false;
        ensureDerived(this);
        return objs[oid].stripped;
    }

    /// Is the object on the Field and Settling (SPEC 16.1)?
    bool isSettling(int oid) const @safe pure nothrow @nogc
    {
        return objs[oid].zone == ZoneKind.field && objs[oid].since >= turn;
    }

    /// Opponent of a player.
    static int other(int p) @safe pure nothrow @nogc
    {
        return 1 - p;
    }

    /// Canonical object order comparison: ascending (timestamp, oid).
    bool canonLess(int a, int b) const @safe pure nothrow @nogc
    {
        if (objs[a].ts != objs[b].ts)
            return objs[a].ts < objs[b].ts;
        return a < b;
    }

    // ------------------------------------------------------------- output

    private void putNum(long v)
    {
        if (v < 0)
        {
            outBuf.put('-');
            putUnsigned(cast(ulong)(0 - cast(ulong) v));
        }
        else
            putUnsigned(cast(ulong) v);
    }

    private void putUnsigned(ulong v)
    {
        char[20] buf;
        size_t i = buf.length;
        do
        {
            buf[--i] = cast(char)('0' + v % 10);
            v /= 10;
        }
        while (v);
        outBuf.put(buf[i .. $]);
    }

    private void putArg(T)(T arg)
    {
        import std.traits : Unqual;

        alias U = Unqual!T;
        U a = arg;
        static if (is(U == string) || is(U == char[]) || is(U == const(char)[]))
            outBuf.put(a);
        else static if (is(U == O))
        {
            outBuf.put('#');
            putNum(a.v);
        }
        else static if (is(U == Q))
        {
            outBuf.put('~');
            putNum(a.v);
        }
        else static if (is(U == Pl))
            outBuf.put(a.v == 0 ? 'A' : 'B');
        else static if (is(U == Sg))
        {
            if (a.v >= 0)
                outBuf.put('+');
            putNum(a.v);
        }
        else static if (is(U == Target))
        {
            final switch (a.kind)
            {
            case 0:
                outBuf.put(a.id == 0 ? 'A' : 'B');
                break;
            case 1:
                outBuf.put('#');
                putNum(a.id);
                break;
            case 2:
                outBuf.put('~');
                putNum(a.id);
                break;
            }
        }
        else
            putNum(a);
    }

    /// Emit one numbered event line.
    void ev(A...)(string name, A args)
    {
        seq++;
        putNum(seq);
        outBuf.put(' ');
        outBuf.put(name);
        foreach (a; args)
        {
            static if (is(typeof(a) == Target[]))
            {
                foreach (t; a)
                {
                    outBuf.put(' ');
                    putArg(t);
                }
            }
            else
            {
                outBuf.put(' ');
                putArg(a);
            }
        }
        outBuf.put('\n');
    }

    /// Emit a raw (unnumbered) line.
    void raw(const(char)[] line)
    {
        outBuf.put(line);
        outBuf.put('\n');
    }

    /// Everything written so far.
    string output()
    {
        return outBuf.data.idup;
    }
}

/// Remove the first occurrence of `v` from `arr`, preserving order.
void removeValue(ref int[] arr, int v)
{
    foreach (i, x; arr)
        if (x == v)
        {
            if (i == 0)
                arr = arr[1 .. $];
            else
                arr = arr.remove(i);
            return;
        }
}

/// Letter of a player.
char playerLetter(int p) @safe pure nothrow @nogc
{
    return p == 0 ? 'A' : 'B';
}
