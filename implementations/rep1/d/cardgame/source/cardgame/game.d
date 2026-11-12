/**
 * Game state: players, objects, zones, the Chain, continuous-effect records,
 * counters and the event log. This module holds data and trivial mutators; the
 * rules live in the other modules.
 */
module cardgame.game;

import std.array : appender, Appender;
import std.conv : to;
import cardgame.database;
import cardgame.model;
import cardgame.rng;

/// Match options from the setup block of the match file (section 4.1).
struct Settings
{
    long spire = 25;
    int opening = 5;
    int maxCap = 10;
    int handMax = 7;
    int turnLimit = 200;
    Player first = Player.A;
    bool shuffle = true;
    enum Trace : ubyte { none, legal, state }
    Trace trace;
    ulong seed;
    long[2] startCap;
}

/// Reference to something that can be a trigger subject.
struct Subject
{
    enum Kind : ubyte { none, obj, player }
    Kind kind;
    int id;

    static Subject ofObj(int oid) { return Subject(Kind.obj, oid); }
    static Subject ofPlayer(Player p) { return Subject(Kind.player, p); }
}

/// A target of an ability: a player, an object or a Chain entry.
struct Target
{
    enum Kind : ubyte { player, obj, chain }
    Kind kind;
    int id;            /// player index, oid or cid
    bool removed;      /// set when found illegal at resolution

    static Target ofPlayer(Player p) { return Target(Kind.player, p, false); }
    static Target ofObj(int oid) { return Target(Kind.obj, oid, false); }
    static Target ofChain(int cid) { return Target(Kind.chain, cid, false); }
}

/// A card instance. Fields below the divider are only meaningful on the Field.
final class Obj
{
    int oid;
    Card card;
    Player owner;
    Zone zone;
    long ts;            /// timestamp of the last entry to the Field (0 if never)
    Player ctrl;        /// current controller (derived on the Field; last controller elsewhere)
    Player baseCtrl;
    // ---- Field state
    bool exhausted;
    int wounds;
    int counters;
    int ward;
    bool doomed;
    long since;
    bool attacking, blocking, blockedFlag;
    Obj[] blockers;     /// for an attacker, in canonical order
    Obj blockedAttacker;
    bool tenacityUsed;
    int[] usedOnce;
    // ---- derived
    bool stripped;
    long edge, core;
    uint kwMask;
    int platingSum;

    bool isUnit() const { return card.type == CardType.unit; }
    bool has(Kw k) const { return (kwMask >> k) & 1; }
}

/// Kinds of Chain entry.
enum EntryKind : ubyte { rite, unit, relic, ability, trigger }

/// A stored effect list of a delayed trigger.
final class Delayed
{
    long ts;
    Player ctrl;
    When when;
    Obj src;
    Target[] targets;
    TSpec[] specs;
    Effect[] effects;
}

/// An entry on the Chain.
final class Entry
{
    int cid;
    EntryKind kind;
    Player ctrl;
    Obj src;
    int abilityIndex;     /// 0 for a played card or a delayed trigger
    Target[] targets;
    TSpec[] specs;
    Subject it;
    Effect[] delayedEffects;
    bool delayed;
}

/// Kinds of continuous-effect record.
enum RecKind : ubyte { modify, setbody, swapstats, grant, strip, control, cheaper }

/// One evaluated static of a record (an aura clause may hold several).
struct RecPart
{
    RecKind kind;
    bool active;
    long a, b;
    KwSpec kw;
    long cheaperBy;
    Filter[] cardFilters;
    Obj[] affected;
}

/// A continuous-effect record (section 14.1).
final class Record
{
    int eid;
    long ts;
    Player ctrl;
    Obj src;
    bool aura;
    // discrete
    RecKind kind;
    long a, b;
    KwSpec kw;
    int[] affected;
    // aura
    Ability ability;
    RecPart[] parts;
}

/// A trigger waiting for the next push.
struct Pending
{
    Obj src;
    int abilityIndex;
    Player ctrl;
    long ts;
    Subject it;
    Delayed delayed;    /// non-null for a delayed trigger
}

/// A pile with O(1) push at either end and pop from the front (the Vault).
struct Pile
{
    private Obj[] buf;
    private size_t head;

    size_t length() const { return buf.length - head; }
    bool empty() const { return buf.length == head; }
    Obj opIndex(size_t i) { return buf[head + i]; }
    Obj[] items() { return buf[head .. $]; }
    Obj front() { return buf[head]; }

    void popFront()
    {
        buf[head] = null;
        ++head;
        if (head == buf.length) { buf.length = 0; head = 0; }
        else if (head > 4096 && head * 2 > buf.length) { buf = buf[head .. $].dup; head = 0; }
    }
    void pushBack(Obj o) { buf ~= o; }
    void removeObj(Obj o)
    {
        foreach (i; head .. buf.length)
            if (buf[i] is o)
            {
                buf = buf[0 .. i] ~ buf[i + 1 .. $];
                return;
            }
    }
}

/// Per-player state.
final class PlayerState
{
    long spire;
    long ember, cap, shield;
    Pile vault;
    Obj[] hand, ash, rift;
}

/// Decision kinds (section 10.2).
enum Decision : ubyte { priority, attackers, blockers, over }

/// Thrown when the match ends, to unwind out of the rules code.
final class MatchEnded : Exception
{
    this() { super("match ended"); }
}

/// The complete state of one match.
final class Game
{
    Database db;
    Settings cfg;
    Obj[] objs;                 // index = oid
    PlayerState[2] pl;
    Obj[] field;                // in entry order == canonical order
    Entry[] chain;              // bottom first
    Record[] records;           // creation order
    Delayed[] delayed;
    Pending[] pending;
    int nextOid = 1, nextCid = 1, nextEid = 1;
    long nextTs = 1;
    long turn = 1;
    Player active;
    string phase = "dawn";
    Player decisionPlayer;
    Decision decision = Decision.priority;
    bool ended;
    string[2] loss;             // first recorded losing reason, or null
    string resultWinner = "pending", resultReason = "none";
    Rng rng;
    bool dirty = true;
    bool deriving;
    bool quiet;                 // suppress trigger collection (opening hands)

    private int seq_;
    private Appender!string out_;

    this(Database db, Settings cfg)
    {
        this.db = db;
        this.cfg = cfg;
        objs = [null];
        foreach (ref p; pl) p = new PlayerState;
        out_ = appender!string();
    }

    /// Everything printed so far.
    string output() { return out_.data; }

    /// Append raw text (blocks and ERR lines; these do not consume sequence numbers).
    void rawLine(const(char)[] s) { out_ ~= s; out_ ~= '\n'; }

    /// Emit an event line: sequence number, name and fields.
    void emit(T...)(string name, T fields)
    {
        out_ ~= (++seq_).to!string;
        out_ ~= ' ';
        out_ ~= name;
        foreach (f; fields)
        {
            out_ ~= ' ';
            static if (is(typeof(f) : const(char)[])) out_ ~= f;
            else out_ ~= f.to!string;
        }
        out_ ~= '\n';
    }

    /// Emit a pre-formatted event line (everything after the sequence number).
    void rawEvent(string rest)
    {
        out_ ~= (++seq_).to!string;
        out_ ~= ' ';
        out_ ~= rest;
        out_ ~= '\n';
    }

    long takeTs() { return nextTs++; }

    Obj obj(long oid) { return oid > 0 && oid < objs.length ? objs[cast(size_t) oid] : null; }

    Entry entryByCid(long cid)
    {
        foreach (e; chain) if (e.cid == cid) return e;
        return null;
    }

    ref PlayerState P(Player p) { return pl[p]; }

    // ---- rendering
    static string r(const Obj o) { return "#" ~ o.oid.to!string; }
    static string r(Player p) { return p == Player.A ? "A" : "B"; }
    static string signed(long n) { return n >= 0 ? "+" ~ n.to!string : n.to!string; }

    string render(in Target t) const
    {
        final switch (t.kind)
        {
        case Target.Kind.player: return t.id == 0 ? "A" : "B";
        case Target.Kind.obj: return "#" ~ t.id.to!string;
        case Target.Kind.chain: return "~" ~ t.id.to!string;
        }
    }

    // ---- zone plumbing

    /// Create a fresh object of `card` owned by `owner`, not yet in any zone.
    Obj createObj(Card card, Player owner)
    {
        auto o = new Obj;
        o.oid = nextOid++;
        o.card = card;
        o.owner = owner;
        o.ctrl = owner;
        o.baseCtrl = owner;
        o.zone = Zone.none;
        objs ~= o;
        return o;
    }

    /// Remove `o` from whichever container holds it.
    void unplace(Obj o)
    {
        final switch (o.zone)
        {
        case Zone.none: case Zone.chain: break;
        case Zone.vault: pl[o.owner].vault.removeObj(o); break;
        case Zone.hand: removeFrom(pl[o.owner].hand, o); break;
        case Zone.ash: removeFrom(pl[o.owner].ash, o); break;
        case Zone.rift: removeFrom(pl[o.owner].rift, o); break;
        case Zone.field: removeFrom(field, o); break;
        }
        o.zone = Zone.none;
        dirty = true;
    }

    /// Append `o` to the end of the owner's zone `z` (not the Field; see `rules`).
    void place(Obj o, Zone z)
    {
        o.zone = z;
        final switch (z)
        {
        case Zone.vault: pl[o.owner].vault.pushBack(o); break;
        case Zone.hand: pl[o.owner].hand ~= o; break;
        case Zone.ash: pl[o.owner].ash ~= o; break;
        case Zone.rift: pl[o.owner].rift ~= o; break;
        case Zone.field: field ~= o; break;
        case Zone.chain: case Zone.none: break;
        }
        dirty = true;
    }

    /// Move to the end of the owner's zone `z`.
    void move(Obj o, Zone z) { unplace(o); place(o, z); }

    private static void removeFrom(ref Obj[] a, Obj o)
    {
        foreach (i, x; a)
            if (x is o)
            {
                foreach (j; i + 1 .. a.length) a[j - 1] = a[j];
                a.length = a.length - 1;
                return;
            }
    }
}
