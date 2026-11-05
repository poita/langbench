/**
 * Card-database reader and validator (SPEC section 5).
 *
 * `parseDatabase` turns the text of a `.spire` file into a typed `CardDb`, or
 * throws `DatabaseError` when the file is malformed in any way the
 * specification calls invalid.
 */
module cardgame.parser;

import std.algorithm : canFind;
import std.conv : to;
import std.exception : enforce;

import cardgame.cards;
import cardgame.sexpr;

/// Raised when a card database is invalid (`FATAL bad-database`).
class DatabaseError : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) @safe pure
    {
        super(msg, file, line);
    }
}

private void bad(string why = "invalid database") @safe pure
{
    throw new DatabaseError(why);
}

private void check(bool cond, string why = "invalid database") @safe pure
{
    if (!cond)
        bad(why);
}

/// Parse and validate the text of a card database.
CardDb parseDatabase(string text) @safe
{
    SExpr[] forms;
    try
        forms = readAll(text);
    catch (SExprError e)
        throw new DatabaseError(e.msg);

    auto p = new Parser(new CardDb);
    foreach (f; forms)
        p.parseCard(f);
    p.resolveReferences();
    return p.db;
}

private struct PendingRef
{
    Effect effect;
    bool isSummon;
}

private final class Parser
{
    CardDb db;
    PendingRef[] refs;

    this(CardDb d) @safe pure nothrow
    {
        db = d;
    }

    // ------------------------------------------------------------ helpers

    static bool isCardId(string s) @safe pure nothrow @nogc
    {
        if (s.length != 7 || s[3] != '-')
            return false;
        foreach (i; 0 .. 3)
            if (s[i] < 'A' || s[i] > 'Z')
                return false;
        foreach (i; 4 .. 7)
            if (s[i] < '0' || s[i] > '9')
                return false;
        return true;
    }

    static SExpr[] args(SExpr f, size_t n) @safe pure
    {
        check(f.isList && f.items.length == n + 1, "arity");
        return f.items[1 .. $];
    }

    static string headOf(SExpr f) @safe pure
    {
        check(f.isList && f.items.length > 0 && f.items[0].isSymbol, "form head");
        return f.items[0].text;
    }

    static long intOf(SExpr n) @safe pure
    {
        check(n.isInt, "integer expected");
        return n.num;
    }

    static string symOf(SExpr n) @safe pure
    {
        check(n.isSymbol, "symbol expected");
        return n.text;
    }

    // ------------------------------------------------------- small enums

    static Cmp parseCmp(SExpr n) @safe pure
    {
        switch (symOf(n))
        {
        case "le":
            return Cmp.le;
        case "lt":
            return Cmp.lt;
        case "eq":
            return Cmp.eq;
        case "ge":
            return Cmp.ge;
        case "gt":
            return Cmp.gt;
        case "ne":
            return Cmp.ne;
        default:
            bad("comparator");
        }
        assert(0);
    }

    static ScopeKind parseScope(SExpr n) @safe pure
    {
        switch (symOf(n))
        {
        case "yours":
            return ScopeKind.yours;
        case "theirs":
            return ScopeKind.theirs;
        case "all":
            return ScopeKind.all;
        default:
            bad("scope");
        }
        assert(0);
    }

    static CardType parseType(SExpr n) @safe pure
    {
        switch (symOf(n))
        {
        case "unit":
            return CardType.unit;
        case "rite":
            return CardType.rite;
        case "relic":
            return CardType.relic;
        default:
            bad("card type");
        }
        assert(0);
    }

    static Keyword parseKeywordName(string s) @safe pure
    {
        foreach (k; 0 .. 16)
            if (keywordName(cast(Keyword) k) == s)
                return cast(Keyword) k;
        bad("keyword");
        assert(0);
    }

    static Kw parseKwSpec(SExpr n) @safe pure
    {
        if (n.isSymbol)
        {
            immutable k = parseKeywordName(n.text);
            check(k != Keyword.plating, "plating needs a value");
            return Kw(k, 0);
        }
        auto a = args(n, 1);
        check(headOf(n) == "plating", "kwspec");
        return Kw(Keyword.plating, intOf(a[0]));
    }

    static Event parseEvent(SExpr n) @safe pure
    {
        immutable s = symOf(n);
        foreach (e; 0 .. 23)
            if (eventName(cast(Event) e) == s)
                return cast(Event) e;
        bad("event");
        assert(0);
    }

    static DelayWhen parseWhen(SExpr n) @safe pure
    {
        immutable s = symOf(n);
        foreach (w; 0 .. 3)
            if (delayName(cast(DelayWhen) w) == s)
                return cast(DelayWhen) w;
        bad("delay timing");
        assert(0);
    }

    // ----------------------------------------------------------- filters

    Filter parseFilter(SExpr f) @safe
    {
        auto r = new Filter;
        immutable h = headOf(f);
        switch (h)
        {
        case "kw":
        case "no-kw":
            auto a = args(f, 1);
            r.kind = h == "kw" ? FilterKind.kw : FilterKind.noKw;
            r.kw = parseKeywordName(symOf(a[0]));
            break;
        case "tag":
            auto a = args(f, 1);
            r.kind = FilterKind.tag;
            r.tag = db.internTag(symOf(a[0]));
            break;
        case "type":
            auto a = args(f, 1);
            r.kind = FilterKind.type;
            r.type = parseType(a[0]);
            break;
        case "cost":
        case "edge":
        case "core":
            auto a = args(f, 2);
            r.kind = h == "cost" ? FilterKind.cost : h == "edge" ? FilterKind.edge : FilterKind.core;
            r.cmp = parseCmp(a[0]);
            r.n = intOf(a[1]);
            break;
        case "wounded":
            args(f, 0);
            r.kind = FilterKind.wounded;
            break;
        case "ready":
            args(f, 0);
            r.kind = FilterKind.ready;
            break;
        case "exhausted":
            args(f, 0);
            r.kind = FilterKind.exhausted;
            break;
        case "settling":
            args(f, 0);
            r.kind = FilterKind.settling;
            break;
        case "attacking":
            args(f, 0);
            r.kind = FilterKind.attacking;
            break;
        case "blocking":
            args(f, 0);
            r.kind = FilterKind.blocking;
            break;
        case "mine":
            args(f, 0);
            r.kind = FilterKind.mine;
            break;
        case "enemy":
            args(f, 0);
            r.kind = FilterKind.enemy;
            break;
        case "other":
            args(f, 0);
            r.kind = FilterKind.other;
            break;
        case "not":
            auto a = args(f, 1);
            r.kind = FilterKind.not;
            r.inner = parseFilter(a[0]);
            break;
        default:
            bad("filter");
        }
        return r;
    }

    Filter[] parseFilters(SExpr[] items) @safe
    {
        Filter[] r;
        foreach (i; items)
            r ~= parseFilter(i);
        return r;
    }

    /// `cheaper` card filters: (type t) (tag s) (cost cmp n).
    Filter parseCardFilter(SExpr f) @safe
    {
        immutable h = headOf(f);
        check(h == "type" || h == "tag" || h == "cost", "card filter");
        return parseFilter(f);
    }

    // --------------------------------------------------------- selectors

    /// Object selector (6.3).
    Sel parseSel(SExpr s) @safe
    {
        auto r = new Sel;
        if (s.isSymbol)
        {
            switch (s.text)
            {
            case "self":
                r.kind = SelKind.self;
                return r;
            case "it":
                r.kind = SelKind.it;
                return r;
            case "that":
                r.kind = SelKind.that;
                return r;
            default:
                bad("selector");
            }
        }
        immutable h = headOf(s);
        switch (h)
        {
        case "t":
            auto a = args(s, 1);
            r.kind = SelKind.target;
            immutable n = intOf(a[0]);
            check(n >= 1 && n <= 1000, "target index");
            r.n = cast(int) n;
            break;
        case "units":
        case "relics":
        case "random-unit":
            check(s.items.length >= 2, "arity");
            r.kind = h == "units" ? SelKind.units : h == "relics" ? SelKind.relics : SelKind.randomUnit;
            r.scp = parseScope(s.items[1]);
            r.filters = parseFilters(s.items[2 .. $]);
            break;
        case "cards":
            check(s.items.length >= 3, "arity");
            r.kind = SelKind.cards;
            switch (symOf(s.items[1]))
            {
            case "hand":
                r.zone = ZoneKind.hand;
                break;
            case "ash":
                r.zone = ZoneKind.ash;
                break;
            case "vault":
                r.zone = ZoneKind.vault;
                break;
            case "rift":
                r.zone = ZoneKind.rift;
                break;
            default:
                bad("zone");
            }
            r.scp = parseScope(s.items[2]);
            r.filters = parseFilters(s.items[3 .. $]);
            break;
        default:
            bad("selector");
        }
        return r;
    }

    /// Player selector (6.4).
    Sel parsePsel(SExpr s) @safe
    {
        auto r = new Sel;
        if (s.isSymbol)
        {
            switch (s.text)
            {
            case "you":
                r.kind = SelKind.you;
                return r;
            case "foe":
                r.kind = SelKind.foe;
                return r;
            case "both":
                r.kind = SelKind.both;
                return r;
            default:
                bad("player selector");
            }
        }
        immutable h = headOf(s);
        if (h == "t")
            return parseSel(s);
        check(h == "owner-of", "player selector");
        auto a = args(s, 1);
        r.kind = SelKind.ownerOf;
        r.inner = parseSel(a[0]);
        return r;
    }

    /// Damage selector (6.4.1).
    Sel parseDsel(SExpr s) @safe
    {
        if (s.isSymbol && (s.text == "you" || s.text == "foe" || s.text == "both"))
            return parsePsel(s);
        if (s.isForm("owner-of"))
            return parsePsel(s);
        return parseSel(s);
    }

    // ----------------------------------------------------------- amounts

    Amt parseAmt(SExpr s) @safe
    {
        auto r = new Amt;
        if (s.isInt)
        {
            r.kind = AmtKind.constant;
            r.value = s.num;
            return r;
        }
        immutable h = headOf(s);
        auto a = args(s, 1);
        switch (h)
        {
        case "count":
            r.kind = AmtKind.count;
            r.sel = parseSel(a[0]);
            break;
        case "hand":
            r.kind = AmtKind.hand;
            r.sel = parsePsel(a[0]);
            break;
        case "ash":
            r.kind = AmtKind.ash;
            r.sel = parsePsel(a[0]);
            break;
        case "vault":
            r.kind = AmtKind.vault;
            r.sel = parsePsel(a[0]);
            break;
        case "edge":
            r.kind = AmtKind.edge;
            r.sel = parseSel(a[0]);
            break;
        case "core":
            r.kind = AmtKind.core;
            r.sel = parseSel(a[0]);
            break;
        case "wounds":
            r.kind = AmtKind.wounds;
            r.sel = parseSel(a[0]);
            break;
        default:
            bad("amount");
        }
        return r;
    }

    // -------------------------------------------------------- conditions

    Cond parseCond(SExpr s) @safe
    {
        auto r = new Cond;
        immutable h = headOf(s);
        switch (h)
        {
        case "count":
            auto a = args(s, 3);
            r.kind = CondKind.count;
            r.sel = parseSel(a[0]);
            r.cmp = parseCmp(a[1]);
            r.n = intOf(a[2]);
            break;
        case "spire":
        case "hand":
        case "ash":
        case "vault":
        case "ember":
            auto a = args(s, 3);
            r.kind = h == "spire" ? CondKind.spire : h == "hand" ? CondKind.hand : h == "ash"
                ? CondKind.ash : h == "vault" ? CondKind.vault : CondKind.ember;
            r.sel = parsePsel(a[0]);
            r.cmp = parseCmp(a[1]);
            r.n = intOf(a[2]);
            break;
        case "myturn":
            args(s, 0);
            r.kind = CondKind.myturn;
            break;
        case "and":
        case "or":
            r.kind = h == "and" ? CondKind.and : CondKind.or;
            foreach (c; s.items[1 .. $])
                r.subs ~= parseCond(c);
            break;
        case "not":
            auto a = args(s, 1);
            r.kind = CondKind.not;
            r.subs ~= parseCond(a[0]);
            break;
        default:
            bad("condition");
        }
        return r;
    }

    // ----------------------------------------------------------- effects

    Effect[] parseEffectList(SExpr[] items) @safe
    {
        Effect[] r;
        foreach (i; items)
            r ~= parseEffect(i);
        return r;
    }

    Effect parseEffect(SExpr f) @safe
    {
        auto e = new Effect;
        immutable h = headOf(f);
        switch (h)
        {
        case "damage":
            auto a = args(f, 2);
            e.kind = EffKind.damage;
            e.a = parseAmt(a[0]);
            e.sel = parseDsel(a[1]);
            break;
        case "destroy":
        case "sacrifice":
        case "exile":
        case "bounce":
        case "strip":
        case "control":
        case "ready":
        case "exhaust":
        case "doom":
        case "reanimate":
        case "recall":
        case "swapstats":
            auto a = args(f, 1);
            e.kind = h == "destroy" ? EffKind.destroy : h == "sacrifice" ? EffKind.sacrifice
                : h == "exile" ? EffKind.exile : h == "bounce" ? EffKind.bounce : h == "strip"
                ? EffKind.strip : h == "control" ? EffKind.control : h == "ready" ? EffKind.ready
                : h == "exhaust" ? EffKind.exhaust : h == "doom" ? EffKind.doom : h == "reanimate"
                ? EffKind.reanimate : h == "recall" ? EffKind.recall : EffKind.swapstats;
            e.sel = parseSel(a[0]);
            break;
        case "draw":
        case "discard":
        case "mill":
        case "spire":
        case "ember":
        case "cap":
        case "shield":
            auto a = args(f, 2);
            e.kind = h == "draw" ? EffKind.draw : h == "discard" ? EffKind.discard : h == "mill"
                ? EffKind.mill : h == "spire" ? EffKind.spire : h == "ember" ? EffKind.ember
                : h == "cap" ? EffKind.cap : EffKind.shield;
            e.a = parseAmt(a[0]);
            e.sel = parsePsel(a[1]);
            break;
        case "modify":
        case "setbody":
            auto a = args(f, 3);
            e.kind = h == "modify" ? EffKind.modify : EffKind.setbody;
            e.a = parseAmt(a[0]);
            e.b = parseAmt(a[1]);
            e.sel = parseSel(a[2]);
            break;
        case "grant":
            auto a = args(f, 2);
            e.kind = EffKind.grant;
            e.kw = parseKwSpec(a[0]);
            e.sel = parseSel(a[1]);
            break;
        case "counters":
        case "ward":
            auto a = args(f, 2);
            e.kind = h == "counters" ? EffKind.counters : EffKind.ward;
            e.a = parseAmt(a[0]);
            e.sel = parseSel(a[1]);
            break;
        case "summon":
        case "conjure":
            auto a = args(f, 3);
            e.kind = h == "summon" ? EffKind.summon : EffKind.conjure;
            e.cardId = symOf(a[0]);
            check(isCardId(e.cardId), "card id");
            e.a = parseAmt(a[1]);
            e.sel = parsePsel(a[2]);
            refs ~= PendingRef(e, h == "summon");
            break;
        case "negate":
            auto a = args(f, 1);
            e.kind = EffKind.negate;
            e.sel = parseSel(a[0]);
            check(e.sel.kind == SelKind.target, "negate needs a target");
            break;
        case "dig":
            auto a = args(f, 3);
            e.kind = EffKind.dig;
            e.k = intOf(a[0]);
            check(a[1].isList, "dig filters");
            e.filters = parseFilters(a[1].items);
            e.sel = parsePsel(a[2]);
            break;
        case "delay":
            check(f.items.length >= 2, "arity");
            e.kind = EffKind.delay;
            e.when = parseWhen(f.items[1]);
            e.body_ = parseEffectList(f.items[2 .. $]);
            break;
        case "if":
            check(f.items.length == 3 || f.items.length == 4, "arity");
            e.kind = EffKind.ifElse;
            e.cond = parseCond(f.items[1]);
            check(f.items[2].isList, "if branch");
            e.body_ = parseEffectList(f.items[2].items);
            if (f.items.length == 4)
            {
                check(f.items[3].isList, "if branch");
                e.elseBody = parseEffectList(f.items[3].items);
            }
            break;
        case "each":
            check(f.items.length >= 2, "arity");
            e.kind = EffKind.each;
            e.sel = parseSel(f.items[1]);
            e.body_ = parseEffectList(f.items[2 .. $]);
            break;
        case "repeat":
            check(f.items.length >= 2, "arity");
            e.kind = EffKind.repeat;
            e.a = parseAmt(f.items[1]);
            e.body_ = parseEffectList(f.items[2 .. $]);
            break;
        case "nothing":
            args(f, 0);
            e.kind = EffKind.nothing;
            break;
        default:
            bad("effect");
        }
        return e;
    }

    // ----------------------------------------------------------- statics

    Static parseStatic(SExpr f) @safe
    {
        auto s = new Static;
        immutable h = headOf(f);
        switch (h)
        {
        case "modify":
        case "setbody":
            auto a = args(f, 3);
            s.kind = h == "modify" ? StKind.modify : StKind.setbody;
            s.a = parseAmt(a[0]);
            s.b = parseAmt(a[1]);
            s.sel = parseSel(a[2]);
            break;
        case "swapstats":
            auto a = args(f, 1);
            s.kind = StKind.swapstats;
            s.sel = parseSel(a[0]);
            break;
        case "grant":
            auto a = args(f, 2);
            s.kind = StKind.grant;
            s.kw = parseKwSpec(a[0]);
            s.sel = parseSel(a[1]);
            break;
        case "cheaper":
            check(f.items.length >= 2, "arity");
            s.kind = StKind.cheaper;
            s.n = intOf(f.items[1]);
            foreach (c; f.items[2 .. $])
                s.cardFilters ~= parseCardFilter(c);
            break;
        case "when":
            check(f.items.length >= 2, "arity");
            s.kind = StKind.when;
            s.cond = parseCond(f.items[1]);
            foreach (c; f.items[2 .. $])
                s.subs ~= parseStatic(c);
            break;
        default:
            bad("static");
        }
        return s;
    }

    // ------------------------------------------------- targets and costs

    TSpec parseTSpec(SExpr f) @safe
    {
        auto t = new TSpec;
        immutable h = headOf(f);
        switch (h)
        {
        case "unit":
        case "relic":
        case "any":
        case "ashcard":
            t.kind = h == "unit" ? TKind.unit : h == "relic" ? TKind.relic : h == "any"
                ? TKind.any : TKind.ashcard;
            t.filters = parseFilters(f.items[1 .. $]);
            break;
        case "player":
            args(f, 0);
            t.kind = TKind.player;
            break;
        case "chained":
            args(f, 0);
            t.kind = TKind.chained;
            break;
        default:
            bad("target spec");
        }
        return t;
    }

    CostItem parseCostItem(SExpr f) @safe
    {
        immutable h = headOf(f);
        switch (h)
        {
        case "ember":
        case "spire":
        case "discard":
        case "counters":
            auto a = args(f, 1);
            immutable n = intOf(a[0]);
            check(n >= 0, "negative cost");
            return CostItem(h == "ember" ? CostKind.ember : h == "spire" ? CostKind.spire
                    : h == "discard" ? CostKind.discard : CostKind.counters, n);
        case "exhaust":
            args(f, 0);
            return CostItem(CostKind.exhaust, 0);
        case "sacself":
            args(f, 0);
            return CostItem(CostKind.sacself, 0);
        case "once":
            args(f, 0);
            return CostItem(CostKind.once, 0);
        default:
            bad("cost item");
        }
        assert(0);
    }

    /// Parse the parts of a `resolve`, `on` or `act` clause (items from `from`).
    Ability parseAbility(SExpr clause, size_t from, AbilKind kind) @safe
    {
        auto ab = new Ability;
        ab.kind = kind;
        bool seenCost, seenTargets;
        foreach (part; clause.items[from .. $])
        {
            check(part.isList && part.items.length > 0 && part.items[0].isSymbol, "ability part");
            immutable h = part.items[0].text;
            if (h == "cost" && ab.effects.length == 0)
            {
                check(kind == AbilKind.act && !seenCost, "cost clause");
                seenCost = true;
                ab.costRaw = part;
                foreach (c; part.items[1 .. $])
                    ab.costs ~= parseCostItem(c);
            }
            else if (h == "targets" && ab.effects.length == 0)
            {
                check(!seenTargets, "targets clause");
                seenTargets = true;
                ab.targetsRaw = part;
                foreach (t; part.items[1 .. $])
                    ab.targets ~= parseTSpec(t);
            }
            else
            {
                ab.effects ~= parseEffect(part);
                ab.bodyRaw ~= part;
            }
        }
        check(ab.effects.length > 0, "ability has no effects");
        check(kind != AbilKind.act || seenCost, "act without cost");
        return ab;
    }

    // -------------------------------------------------------------- cards

    void parseCard(SExpr f) @safe
    {
        check(f.isList && f.items.length >= 2 && f.items[0].isSym("card"), "card form");
        auto c = new Card;
        c.id = symOf(f.items[1]);
        check(isCardId(c.id), "card id");
        check(!(c.id in db.byId), "duplicate card id");

        bool hasName, hasType, hasCost, hasBody, hasTags, hasKeywords, hasResolve;
        Ability resolveAb;
        Ability[] ons, acts, auras;
        foreach (cl; f.items[2 .. $])
        {
            check(cl.isList && cl.items.length > 0 && cl.items[0].isSymbol, "clause");
            immutable h = cl.items[0].text;
            switch (h)
            {
            case "name":
                auto a = args(cl, 1);
                check(!hasName && a[0].isStr, "name");
                hasName = true;
                c.name = a[0].text;
                break;
            case "type":
                auto a = args(cl, 1);
                check(!hasType, "type");
                hasType = true;
                c.type = parseType(a[0]);
                break;
            case "cost":
                auto a = args(cl, 1);
                check(!hasCost, "cost");
                hasCost = true;
                c.cost = intOf(a[0]);
                check(c.cost >= 0, "negative cost");
                break;
            case "body":
                auto a = args(cl, 2);
                check(!hasBody, "body");
                hasBody = true;
                c.edge = intOf(a[0]);
                c.core = intOf(a[1]);
                check(c.edge >= 0 && c.core >= 0, "negative body");
                break;
            case "tags":
                check(!hasTags, "tags");
                hasTags = true;
                foreach (t; cl.items[1 .. $])
                {
                    c.tags ~= symOf(t);
                    c.tagIds ~= db.internTag(t.text);
                }
                break;
            case "keywords":
                check(!hasKeywords, "keywords");
                hasKeywords = true;
                foreach (k; cl.items[1 .. $])
                    c.keywords ~= parseKwSpec(k);
                break;
            case "text":
                auto a = args(cl, 1);
                check(!c.hasText && a[0].isStr, "text");
                c.hasText = true;
                c.text = a[0].text;
                break;
            case "resolve":
                check(!hasResolve, "resolve");
                hasResolve = true;
                resolveAb = parseAbility(cl, 1, AbilKind.resolve);
                break;
            case "on":
                check(cl.items.length >= 2, "on");
                auto ab = parseAbility(cl, 2, AbilKind.on);
                ab.event = parseEvent(cl.items[1]);
                ons ~= ab;
                break;
            case "act":
                acts ~= parseAbility(cl, 1, AbilKind.act);
                break;
            case "aura":
                check(cl.items.length >= 2, "aura");
                auto ab = new Ability;
                ab.kind = AbilKind.aura;
                foreach (s; cl.items[1 .. $])
                {
                    ab.statics ~= parseStatic(s);
                    ab.bodyRaw ~= s;
                }
                foreach (st; ab.statics)
                    ab.deps |= staticDeps(st);
                auras ~= ab;
                break;
            default:
                bad("unknown clause");
            }
        }
        check(hasName && hasType && hasCost, "missing required clause");
        check((c.type == CardType.unit) == hasBody, "body clause");
        check((c.type == CardType.rite) == hasResolve, "resolve clause");

        foreach (k; c.keywords)
        {
            final switch (c.type)
            {
            case CardType.unit:
                check(k.kind != Keyword.swift, "swift on a unit");
                break;
            case CardType.rite:
                check(k.kind == Keyword.swift, "keyword on a rite");
                break;
            case CardType.relic:
                bad("keyword on a relic");
                break;
            }
        }

        if (hasResolve)
            c.abilities ~= resolveAb;
        foreach (a; ons)
        {
            c.abilities ~= a;
            c.eventMask |= 1u << a.event;
        }
        c.abilities ~= acts;
        c.abilities ~= auras;

        c.index = cast(int) db.cards.length;
        db.cards ~= c;
        db.byId[c.id] = c.index;
    }

    /// Resolve `summon`/`conjure` card references once all cards are known.
    void resolveReferences() @safe
    {
        foreach (r; refs)
        {
            auto t = r.effect.cardId in db.byId;
            check(t !is null, "unknown card reference");
            r.effect.cardIdx = *t;
            if (r.isSummon)
                check(db.cards[*t].type != CardType.rite, "summon of a rite");
        }
    }
}

// ------------------------------------------------------ aura dependency bits

private uint filterDeps(Filter f) @safe pure nothrow
{
    switch (f.kind)
    {
    case FilterKind.wounded:
        return Dep.wounds;
    case FilterKind.ready:
    case FilterKind.exhausted:
        return Dep.ready;
    case FilterKind.settling:
        return Dep.turn;
    case FilterKind.attacking:
    case FilterKind.blocking:
        return Dep.combat;
    case FilterKind.not:
        return filterDeps(f.inner);
    default:
        return 0;
    }
}

private uint selDeps(Sel s) @safe pure nothrow
{
    if (s is null)
        return 0;
    uint d = s.kind == SelKind.cards ? Dep.zones : 0;
    foreach (f; s.filters)
        d |= filterDeps(f);
    return d | selDeps(s.inner);
}

private uint amtDeps(Amt a) @safe pure nothrow
{
    if (a is null)
        return 0;
    final switch (a.kind)
    {
    case AmtKind.constant:
        return 0;
    case AmtKind.count:
    case AmtKind.edge:
    case AmtKind.core:
        return selDeps(a.sel);
    case AmtKind.hand:
    case AmtKind.ash:
    case AmtKind.vault:
        return Dep.zones | selDeps(a.sel);
    case AmtKind.wounds:
        return Dep.wounds | selDeps(a.sel);
    }
}

private uint condDeps(Cond c) @safe pure nothrow
{
    uint d = selDeps(c.sel);
    final switch (c.kind)
    {
    case CondKind.count:
    case CondKind.and:
    case CondKind.or:
    case CondKind.not:
        break;
    case CondKind.spire:
        d |= Dep.spire;
        break;
    case CondKind.ember:
        d |= Dep.ember;
        break;
    case CondKind.hand:
    case CondKind.ash:
    case CondKind.vault:
        d |= Dep.zones;
        break;
    case CondKind.myturn:
        d |= Dep.turn;
        break;
    }
    foreach (s; c.subs)
        d |= condDeps(s);
    return d;
}

private uint staticDeps(Static s) @safe pure nothrow
{
    uint d = amtDeps(s.a) | amtDeps(s.b) | selDeps(s.sel);
    if (s.cond !is null)
        d |= condDeps(s.cond);
    foreach (c; s.subs)
        d |= staticDeps(c);
    return d;
}
