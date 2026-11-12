/**
 * Card database: converts the s-expressions of a database file into typed
 * cards and validates them (SPEC.md sections 5.2-5.4).
 */
module cardgame.database;

import std.conv : to;
import std.algorithm : canFind;
import cardgame.model;
import cardgame.sexpr;

/// Raised for any problem that makes a database invalid.
class DatabaseException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        super(msg, file, line);
    }
}

/// An immutable collection of validated cards.
final class Database
{
    private Card[string] byId;
    /// Cards in file order.
    Card[] ordered;

    /// The card with this id, or null.
    Card find(string id) { auto p = id in byId; return p ? *p : null; }

    /// Number of cards defined.
    size_t length() const { return byId.length; }

    package void add(Card c) { byId[c.id] = c; ordered ~= c; }
}

/// Parse and validate database text; throws `DatabaseException` when invalid.
Database parseDatabase(string src)
{
    SExpr[] forms;
    try
        forms = parseSExprs(src);
    catch (SExprException e)
        throw new DatabaseException(e.msg);
    auto db = new Database;
    Parser p;
    foreach (f; forms)
    {
        auto c = p.parseCard(f);
        if (db.find(c.id) !is null) throw new DatabaseException("duplicate card id " ~ c.id);
        db.add(c);
    }
    foreach (ref r; p.refs)
    {
        auto c = db.find(r.id);
        if (c is null) throw new DatabaseException("unknown card " ~ r.id);
        if (r.summon && c.type == CardType.rite)
            throw new DatabaseException("summon of a rite " ~ r.id);
    }
    return db;
}

/// Whether `s` has the shape of a card id: three capitals, a dash, three digits.
bool isCardId(string s) pure nothrow @safe @nogc
{
    if (s.length != 7 || s[3] != '-') return false;
    foreach (i; [0, 1, 2]) if (s[i] < 'A' || s[i] > 'Z') return false;
    foreach (i; [4, 5, 6]) if (s[i] < '0' || s[i] > '9') return false;
    return true;
}

private struct CardRef { string id; bool summon; }

private void fail(string m, string file = __FILE__, size_t line = __LINE__) @safe
{
    throw new DatabaseException(m, file, line);
}

private struct Parser
{
    CardRef[] refs;

    // ---- helpers

    static const(SExpr)[] args(in SExpr e, string name, size_t lo, size_t hi)
    {
        if (!e.isList || e.items.length == 0 || !e.items[0].isSym(name)) fail("expected (" ~ name ~ ")");
        auto a = e.items[1 .. $];
        if (a.length < lo || a.length > hi) fail("bad arity for " ~ name);
        return a;
    }

    static long intArg(in SExpr e)
    {
        if (!e.isInt) fail("integer expected");
        return e.num;
    }

    static Cmp parseCmp(in SExpr e)
    {
        if (!e.isSymbol) fail("comparator expected");
        switch (e.text)
        {
        case "le": return Cmp.le;
        case "lt": return Cmp.lt;
        case "eq": return Cmp.eq;
        case "ge": return Cmp.ge;
        case "gt": return Cmp.gt;
        case "ne": return Cmp.ne;
        default: fail("bad comparator");
        }
        assert(0);
    }

    static Scope parseScope(in SExpr e)
    {
        if (e.isSym("yours")) return Scope.yours;
        if (e.isSym("theirs")) return Scope.theirs;
        if (e.isSym("all")) return Scope.all;
        fail("bad scope");
        assert(0);
    }

    static Kw parseKeywordName(in SExpr e)
    {
        Kw k;
        if (!e.isSymbol || !keywordFromName(e.text, k)) fail("unknown keyword");
        return k;
    }

    static KwSpec parseKwSpec(in SExpr e)
    {
        KwSpec s;
        if (e.isSymbol)
        {
            s.kw = parseKeywordName(e);
            if (s.kw == Kw.plating) fail("plating needs a value");
            return s;
        }
        auto a = args(e, "plating", 1, 1);
        s.kw = Kw.plating;
        s.value = cast(int) intArg(a[0]);
        if (a[0].num != s.value) fail("plating value out of range");
        return s;
    }

    static CardType parseType(in SExpr e)
    {
        if (e.isSym("unit")) return CardType.unit;
        if (e.isSym("rite")) return CardType.rite;
        if (e.isSym("relic")) return CardType.relic;
        fail("bad type");
        assert(0);
    }

    // ---- filters

    Filter parseFilter(in SExpr e)
    {
        if (!e.isList || e.items.length == 0 || !e.items[0].isSymbol) fail("filter expected");
        auto f = new Filter;
        auto h = e.items[0].text;
        switch (h)
        {
        case "kw": case "no-kw":
            f.kind = h == "kw" ? Filter.Kind.kw : Filter.Kind.noKw;
            f.kw = parseKeywordName(args(e, h, 1, 1)[0]);
            break;
        case "tag":
            auto a = args(e, h, 1, 1);
            if (!a[0].isSymbol) fail("tag symbol expected");
            f.kind = Filter.Kind.tag; f.tag = a[0].text;
            break;
        case "type":
            f.kind = Filter.Kind.type; f.type = parseType(args(e, h, 1, 1)[0]);
            break;
        case "cost": case "edge": case "core":
            auto a = args(e, h, 2, 2);
            f.kind = h == "cost" ? Filter.Kind.cost : h == "edge" ? Filter.Kind.edge : Filter.Kind.core;
            f.cmp = parseCmp(a[0]); f.n = intArg(a[1]);
            break;
        case "wounded": args(e, h, 0, 0); f.kind = Filter.Kind.wounded; break;
        case "ready": args(e, h, 0, 0); f.kind = Filter.Kind.ready; break;
        case "exhausted": args(e, h, 0, 0); f.kind = Filter.Kind.exhausted; break;
        case "settling": args(e, h, 0, 0); f.kind = Filter.Kind.settling; break;
        case "attacking": args(e, h, 0, 0); f.kind = Filter.Kind.attacking; break;
        case "blocking": args(e, h, 0, 0); f.kind = Filter.Kind.blocking; break;
        case "mine": args(e, h, 0, 0); f.kind = Filter.Kind.mine; break;
        case "enemy": args(e, h, 0, 0); f.kind = Filter.Kind.enemy; break;
        case "other": args(e, h, 0, 0); f.kind = Filter.Kind.other; break;
        case "not":
            f.kind = Filter.Kind.not; f.inner = parseFilter(args(e, h, 1, 1)[0]);
            break;
        default: fail("unknown filter " ~ h);
        }
        return f;
    }

    Filter[] parseFilters(in SExpr[] es)
    {
        Filter[] r;
        foreach (ref e; es) r ~= parseFilter(e);
        return r;
    }

    // ---- selectors

    static int parseTargetNo(in SExpr e)
    {
        auto a = args(e, "t", 1, 1);
        immutable n = intArg(a[0]);
        if (n < 1 || n > int.max) fail("bad target number");
        return cast(int) n;
    }

    Selector parseSel(in SExpr e)
    {
        auto s = new Selector;
        if (e.isSymbol)
        {
            switch (e.text)
            {
            case "self": s.kind = Selector.Kind.self; return s;
            case "it": s.kind = Selector.Kind.it; return s;
            case "that": s.kind = Selector.Kind.that; return s;
            default: fail("bad selector");
            }
        }
        if (!e.isList || e.items.length == 0 || !e.items[0].isSymbol) fail("selector expected");
        switch (e.items[0].text)
        {
        case "t": s.kind = Selector.Kind.target; s.n = parseTargetNo(e); break;
        case "units": case "relics": case "random-unit":
            auto a = args(e, e.items[0].text, 1, size_t.max);
            s.kind = e.items[0].text == "units" ? Selector.Kind.units
                   : e.items[0].text == "relics" ? Selector.Kind.relics : Selector.Kind.randomUnit;
            s.scope_ = parseScope(a[0]);
            s.filters = parseFilters(a[1 .. $]);
            break;
        case "cards":
            auto a = args(e, "cards", 2, size_t.max);
            s.kind = Selector.Kind.cards;
            if (a[0].isSym("hand")) s.zone = Zone.hand;
            else if (a[0].isSym("ash")) s.zone = Zone.ash;
            else if (a[0].isSym("vault")) s.zone = Zone.vault;
            else if (a[0].isSym("rift")) s.zone = Zone.rift;
            else fail("bad zone");
            s.scope_ = parseScope(a[1]);
            s.filters = parseFilters(a[2 .. $]);
            break;
        default: fail("bad selector");
        }
        return s;
    }

    PSel parsePSel(in SExpr e)
    {
        auto p = new PSel;
        if (e.isSymbol)
        {
            switch (e.text)
            {
            case "you": p.kind = PSel.Kind.you; return p;
            case "foe": p.kind = PSel.Kind.foe; return p;
            case "both": p.kind = PSel.Kind.both; return p;
            default: fail("bad player selector");
            }
        }
        if (e.head == "t") { p.kind = PSel.Kind.target; p.n = parseTargetNo(e); return p; }
        if (e.head == "owner-of")
        {
            p.kind = PSel.Kind.ownerOf;
            p.inner = parseSel(args(e, "owner-of", 1, 1)[0]);
            return p;
        }
        fail("bad player selector");
        assert(0);
    }

    DSel parseDSel(in SExpr e)
    {
        auto d = new DSel;
        if (e.isSym("you") || e.isSym("foe") || e.isSym("both") || e.head == "owner-of")
        {
            d.kind = DSel.Kind.player; d.player = parsePSel(e);
        }
        else if (e.head == "t")
        {
            d.kind = DSel.Kind.target; d.n = parseTargetNo(e);
        }
        else
        {
            d.kind = DSel.Kind.object; d.object = parseSel(e);
        }
        return d;
    }

    // ---- amounts and conditions

    Amount parseAmount(in SExpr e)
    {
        auto a = new Amount;
        if (e.isInt) { a.kind = Amount.Kind.literal; a.value = e.num; return a; }
        if (!e.isList || e.items.length == 0 || !e.items[0].isSymbol) fail("amount expected");
        auto h = e.items[0].text;
        auto x = args(e, h, 1, 1);
        switch (h)
        {
        case "count": a.kind = Amount.Kind.count; a.sel = parseSel(x[0]); break;
        case "hand": a.kind = Amount.Kind.hand; a.psel = parsePSel(x[0]); break;
        case "ash": a.kind = Amount.Kind.ash; a.psel = parsePSel(x[0]); break;
        case "vault": a.kind = Amount.Kind.vault; a.psel = parsePSel(x[0]); break;
        case "edge": a.kind = Amount.Kind.edge; a.sel = parseSel(x[0]); break;
        case "core": a.kind = Amount.Kind.core; a.sel = parseSel(x[0]); break;
        case "wounds": a.kind = Amount.Kind.wounds; a.sel = parseSel(x[0]); break;
        default: fail("bad amount");
        }
        return a;
    }

    Cond parseCond(in SExpr e)
    {
        if (!e.isList || e.items.length == 0 || !e.items[0].isSymbol) fail("condition expected");
        auto c = new Cond;
        auto h = e.items[0].text;
        switch (h)
        {
        case "count":
            auto a = args(e, h, 3, 3);
            c.kind = Cond.Kind.count; c.sel = parseSel(a[0]);
            c.cmp = parseCmp(a[1]); c.value = intArg(a[2]);
            break;
        case "spire": case "hand": case "ash": case "vault": case "ember":
            auto a = args(e, h, 3, 3);
            c.kind = h == "spire" ? Cond.Kind.spire : h == "hand" ? Cond.Kind.hand
                   : h == "ash" ? Cond.Kind.ash : h == "vault" ? Cond.Kind.vault : Cond.Kind.ember;
            c.psel = parsePSel(a[0]); c.cmp = parseCmp(a[1]); c.value = intArg(a[2]);
            break;
        case "myturn": args(e, h, 0, 0); c.kind = Cond.Kind.myturn; break;
        case "and": case "or":
            c.kind = h == "and" ? Cond.Kind.and : Cond.Kind.or;
            foreach (ref x; e.items[1 .. $]) c.subs ~= parseCond(x);
            break;
        case "not":
            c.kind = Cond.Kind.not; c.subs ~= parseCond(args(e, h, 1, 1)[0]);
            break;
        default: fail("bad condition");
        }
        return c;
    }

    // ---- effects

    Effect[] parseEffectList(in SExpr[] es)
    {
        Effect[] r;
        foreach (ref e; es) r ~= parseEffect(e);
        return r;
    }

    Effect[] parseBody(in SExpr e)
    {
        if (!e.isList) fail("effect list expected");
        foreach (ref x; e.items) if (!x.isList) fail("effect list expected");
        return parseEffectList(e.items);
    }

    Effect parseEffect(in SExpr e)
    {
        if (!e.isList || e.items.length == 0 || !e.items[0].isSymbol) fail("effect expected");
        auto f = new Effect;
        f.raw = cast(SExpr) e;
        auto h = e.items[0].text;
        switch (h)
        {
        case "damage":
            auto a = args(e, h, 2, 2);
            f.kind = Effect.Kind.damage; f.amt = parseAmount(a[0]); f.dsel = parseDSel(a[1]);
            break;
        case "destroy": case "sacrifice": case "exile": case "bounce": case "swapstats":
        case "strip": case "control": case "ready": case "exhaust": case "doom":
        case "reanimate": case "recall":
            auto a = args(e, h, 1, 1);
            f.kind = h == "destroy" ? Effect.Kind.destroy : h == "sacrifice" ? Effect.Kind.sacrifice
                : h == "exile" ? Effect.Kind.exile : h == "bounce" ? Effect.Kind.bounce
                : h == "swapstats" ? Effect.Kind.swapstats : h == "strip" ? Effect.Kind.strip
                : h == "control" ? Effect.Kind.control : h == "ready" ? Effect.Kind.ready
                : h == "exhaust" ? Effect.Kind.exhaust : h == "doom" ? Effect.Kind.doom
                : h == "reanimate" ? Effect.Kind.reanimate : Effect.Kind.recall;
            f.sel = parseSel(a[0]);
            break;
        case "draw": case "discard": case "mill": case "spire": case "ember": case "cap": case "shield":
            auto a = args(e, h, 2, 2);
            f.kind = h == "draw" ? Effect.Kind.draw : h == "discard" ? Effect.Kind.discard
                : h == "mill" ? Effect.Kind.mill : h == "spire" ? Effect.Kind.spire
                : h == "ember" ? Effect.Kind.ember : h == "cap" ? Effect.Kind.cap : Effect.Kind.shield;
            f.amt = parseAmount(a[0]); f.psel = parsePSel(a[1]);
            break;
        case "modify": case "setbody":
            auto a = args(e, h, 3, 3);
            f.kind = h == "modify" ? Effect.Kind.modify : Effect.Kind.setbody;
            f.amt = parseAmount(a[0]); f.amt2 = parseAmount(a[1]); f.sel = parseSel(a[2]);
            break;
        case "grant":
            auto a = args(e, h, 2, 2);
            f.kind = Effect.Kind.grant; f.kw = parseKwSpec(a[0]); f.sel = parseSel(a[1]);
            break;
        case "counters": case "ward":
            auto a = args(e, h, 2, 2);
            f.kind = h == "counters" ? Effect.Kind.counters : Effect.Kind.ward;
            f.amt = parseAmount(a[0]); f.sel = parseSel(a[1]);
            break;
        case "summon": case "conjure":
            auto a = args(e, h, 3, 3);
            f.kind = h == "summon" ? Effect.Kind.summon : Effect.Kind.conjure;
            if (!a[0].isSymbol || !isCardId(a[0].text)) fail("card id expected");
            f.cardId = a[0].text;
            refs ~= CardRef(f.cardId, h == "summon");
            f.amt = parseAmount(a[1]); f.psel = parsePSel(a[2]);
            break;
        case "negate":
            auto a = args(e, h, 1, 1);
            f.kind = Effect.Kind.negate; f.sel = parseSel(a[0]);
            if (f.sel.kind != Selector.Kind.target) fail("negate needs (t n)");
            break;
        case "dig":
            auto a = args(e, h, 3, 3);
            f.kind = Effect.Kind.dig; f.digCount = intArg(a[0]);
            if (!a[1].isList) fail("filter list expected");
            f.digFilters = parseFilters(a[1].items);
            f.psel = parsePSel(a[2]);
            break;
        case "delay":
            auto a = args(e, h, 1, size_t.max);
            f.kind = Effect.Kind.delay;
            if (!a[0].isSymbol) fail("delay timing expected");
            bool found;
            foreach (i, n; whenNames) if (n == a[0].text) { f.when = cast(When) i; found = true; }
            if (!found) fail("bad delay timing");
            f.body_ = parseEffectList(a[1 .. $]);
            break;
        case "if":
            auto a = args(e, h, 2, 3);
            f.kind = Effect.Kind.if_; f.cond = parseCond(a[0]);
            f.body_ = parseBody(a[1]);
            if (a.length == 3) f.elseBody = parseBody(a[2]);
            break;
        case "each":
            auto a = args(e, h, 1, size_t.max);
            f.kind = Effect.Kind.each; f.sel = parseSel(a[0]);
            f.body_ = parseEffectList(a[1 .. $]);
            break;
        case "repeat":
            auto a = args(e, h, 1, size_t.max);
            f.kind = Effect.Kind.repeat; f.amt = parseAmount(a[0]);
            f.body_ = parseEffectList(a[1 .. $]);
            break;
        case "nothing": args(e, h, 0, 0); f.kind = Effect.Kind.nothing; break;
        default: fail("unknown effect " ~ h);
        }
        return f;
    }

    // ---- statics

    Static parseStatic(in SExpr e)
    {
        if (!e.isList || e.items.length == 0 || !e.items[0].isSymbol) fail("static expected");
        auto s = new Static;
        auto h = e.items[0].text;
        switch (h)
        {
        case "modify": case "setbody":
            auto a = args(e, h, 3, 3);
            s.kind = h == "modify" ? Static.Kind.modify : Static.Kind.setbody;
            s.amt = parseAmount(a[0]); s.amt2 = parseAmount(a[1]); s.sel = parseSel(a[2]);
            break;
        case "swapstats":
            s.kind = Static.Kind.swapstats; s.sel = parseSel(args(e, h, 1, 1)[0]);
            break;
        case "grant":
            auto a = args(e, h, 2, 2);
            s.kind = Static.Kind.grant; s.kw = parseKwSpec(a[0]); s.sel = parseSel(a[1]);
            break;
        case "cheaper":
            auto a = args(e, h, 1, size_t.max);
            s.kind = Static.Kind.cheaper; s.cheaperBy = intArg(a[0]);
            foreach (ref x; a[1 .. $])
            {
                auto f = parseFilter(x);
                if (f.kind != Filter.Kind.type && f.kind != Filter.Kind.tag && f.kind != Filter.Kind.cost)
                    fail("bad card filter");
                s.cardFilters ~= f;
            }
            break;
        case "when":
            auto a = args(e, h, 1, size_t.max);
            s.kind = Static.Kind.when; s.cond = parseCond(a[0]);
            foreach (ref x; a[1 .. $]) s.inner ~= parseStatic(x);
            break;
        default: fail("bad static");
        }
        return s;
    }

    // ---- abilities

    TSpec parseTSpec(in SExpr e)
    {
        if (!e.isList || e.items.length == 0 || !e.items[0].isSymbol) fail("tspec expected");
        auto t = new TSpec;
        auto h = e.items[0].text;
        switch (h)
        {
        case "unit": t.kind = TSpec.Kind.unit; t.filters = parseFilters(e.items[1 .. $]); break;
        case "relic": t.kind = TSpec.Kind.relic; t.filters = parseFilters(e.items[1 .. $]); break;
        case "any": t.kind = TSpec.Kind.any; t.filters = parseFilters(e.items[1 .. $]); break;
        case "ashcard": t.kind = TSpec.Kind.ashcard; t.filters = parseFilters(e.items[1 .. $]); break;
        case "player": args(e, h, 0, 0); t.kind = TSpec.Kind.player; break;
        case "chained": args(e, h, 0, 0); t.kind = TSpec.Kind.chained; break;
        default: fail("bad target spec");
        }
        return t;
    }

    CostItem parseCostItem(in SExpr e)
    {
        if (!e.isList || e.items.length == 0 || !e.items[0].isSymbol) fail("cost item expected");
        CostItem c;
        auto h = e.items[0].text;
        switch (h)
        {
        case "ember": c.kind = CostItem.Kind.ember; c.n = intArg(args(e, h, 1, 1)[0]); break;
        case "spire": c.kind = CostItem.Kind.spire; c.n = intArg(args(e, h, 1, 1)[0]); break;
        case "discard": c.kind = CostItem.Kind.discard; c.n = intArg(args(e, h, 1, 1)[0]); break;
        case "counters": c.kind = CostItem.Kind.counters; c.n = intArg(args(e, h, 1, 1)[0]); break;
        case "exhaust": args(e, h, 0, 0); c.kind = CostItem.Kind.exhaust; break;
        case "sacself": args(e, h, 0, 0); c.kind = CostItem.Kind.sacself; break;
        case "once": args(e, h, 0, 0); c.kind = CostItem.Kind.once; break;
        default: fail("bad cost item");
        }
        return c;
    }

    /// Parse the parts following the head (and event) of a resolve/on/act clause.
    Ability parseAbility(AbilityKind kind, in SExpr[] parts)
    {
        auto ab = new Ability;
        ab.kind = kind;
        bool seenEffect;
        foreach (ref p; parts)
        {
            if (p.head == "cost")
            {
                if (kind != AbilityKind.act || ab.hasCost || seenEffect) fail("misplaced cost");
                ab.hasCost = true; ab.costClause = cast(SExpr) p;
                foreach (ref ci; p.items[1 .. $]) ab.costs ~= parseCostItem(ci);
            }
            else if (p.head == "targets")
            {
                if (ab.hasTargets || seenEffect) fail("misplaced targets");
                if (p.items.length < 2) fail("empty targets");
                ab.hasTargets = true; ab.targetsClause = cast(SExpr) p;
                foreach (ref t; p.items[1 .. $]) ab.targets ~= parseTSpec(t);
            }
            else
            {
                seenEffect = true;
                ab.effects ~= parseEffect(p);
                ab.rawParts ~= cast(SExpr) p;
            }
        }
        if (kind == AbilityKind.act && !ab.hasCost) fail("act without cost");
        if (ab.effects.length == 0) fail("ability without effects");
        return ab;
    }

    // ---- cards

    Card parseCard(in SExpr e)
    {
        if (!e.isList || e.items.length < 2 || !e.items[0].isSym("card")) fail("card expected");
        if (!e.items[1].isSymbol || !isCardId(e.items[1].text)) fail("bad card id");
        auto c = new Card;
        c.id = e.items[1].text;
        bool hasName, hasType, hasCost, hasBody, hasTags, hasKw, hasText;
        Ability resolve;
        Ability[] ons, acts, auras;
        foreach (ref cl; e.items[2 .. $])
        {
            auto h = cl.head;
            if (h is null) fail("clause expected");
            switch (h)
            {
            case "name":
                auto a = args(cl, h, 1, 1);
                if (hasName || !a[0].isString) fail("bad name");
                hasName = true; c.name = a[0].text; break;
            case "type":
                auto a = args(cl, h, 1, 1);
                if (hasType) fail("duplicate type");
                hasType = true; c.type = parseType(a[0]); break;
            case "cost":
                auto a = args(cl, h, 1, 1);
                if (hasCost) fail("duplicate cost");
                hasCost = true; c.cost = intArg(a[0]);
                if (c.cost < 0) fail("negative cost");
                break;
            case "body":
                auto a = args(cl, h, 2, 2);
                if (hasBody) fail("duplicate body");
                hasBody = true; c.edge = intArg(a[0]); c.core = intArg(a[1]);
                if (c.edge < 0 || c.core < 0) fail("negative body");
                break;
            case "tags":
                if (hasTags) fail("duplicate tags");
                hasTags = true;
                foreach (ref t; cl.items[1 .. $])
                {
                    if (!t.isSymbol) fail("tag symbol expected");
                    c.tags ~= t.text;
                }
                break;
            case "keywords":
                if (hasKw) fail("duplicate keywords");
                hasKw = true;
                foreach (ref k; cl.items[1 .. $]) c.keywords ~= parseKwSpec(k);
                break;
            case "text":
                auto a = args(cl, h, 1, 1);
                if (hasText || !a[0].isString) fail("bad text");
                hasText = true; c.text = a[0].text; break;
            case "resolve":
                if (resolve !is null) fail("duplicate resolve");
                resolve = parseAbility(AbilityKind.resolve, cl.items[1 .. $]);
                break;
            case "on":
                if (cl.items.length < 2 || !cl.items[1].isSymbol) fail("event expected");
                Event ev;
                bool found;
                foreach (i, n; eventNames) if (n == cl.items[1].text) { ev = cast(Event) i; found = true; }
                if (!found) fail("unknown event");
                auto ab = parseAbility(AbilityKind.on, cl.items[2 .. $]);
                ab.event = ev;
                ons ~= ab;
                break;
            case "act":
                acts ~= parseAbility(AbilityKind.act, cl.items[1 .. $]);
                break;
            case "aura":
                auto ab = new Ability;
                ab.kind = AbilityKind.aura;
                if (cl.items.length < 2) fail("empty aura");
                foreach (ref s; cl.items[1 .. $])
                {
                    ab.statics ~= parseStatic(s);
                    ab.rawParts ~= cast(SExpr) s;
                }
                auras ~= ab;
                break;
            default: fail("unknown clause " ~ h);
            }
        }
        if (!hasName || !hasType || !hasCost) fail("missing required clause");
        if (c.type == CardType.unit && !hasBody) fail("unit without body");
        if (c.type != CardType.unit && hasBody) fail("body on a non-unit");
        if (c.type == CardType.rite && resolve is null) fail("rite without resolve");
        if (c.type != CardType.rite && resolve !is null) fail("resolve on a non-rite");
        foreach (k; c.keywords)
        {
            immutable ok = k.kw == Kw.swift ? c.type == CardType.rite : c.type == CardType.unit;
            if (!ok) fail("keyword not legal on this card type");
            c.kwMask |= 1u << k.kw;
        }
        if (resolve !is null) c.abilities ~= resolve;
        c.abilities ~= ons;
        c.abilities ~= acts;
        c.abilities ~= auras;
        foreach (i, ab; c.abilities) ab.index = cast(int) i + 1;
        return c;
    }
}

unittest
{
    import std.exception : assertThrown;
    auto db = parseDatabase(`
        (card AAA-001 (name "One") (type unit) (cost 1) (body 2 3) (tags x y)
          (keywords vanguard (plating 2))
          (on arrive (targets (unit (enemy))) (damage 1 (t 1)))
          (act (cost (ember 1) (exhaust)) (draw 1 you))
          (aura (when (myturn) (modify 1 1 (units yours)))))
        (card AAA-002 (name "Two") (type rite) (cost 0) (resolve (nothing)))`);
    assert(db.length == 2);
    auto c = db.find("AAA-001");
    assert(c.abilities.length == 3);
    assert(c.abilities[0].kind == AbilityKind.on);
    assert(c.abilities[1].kind == AbilityKind.act && c.abilities[1].index == 2);
    assert(c.hasKeyword(Kw.plating) && !c.hasKeyword(Kw.venom));
    assertThrown!DatabaseException(parseDatabase(`(card AAA-001 (name "x") (type rite) (cost 1))`));
    assertThrown!DatabaseException(parseDatabase(
        `(card AAA-001 (name "x") (type rite) (cost 1) (resolve (summon AAA-001 1 you)))`));
    assertThrown!DatabaseException(parseDatabase(
        `(card AAA-001 (name "x") (type rite) (cost 1) (resolve (if (myturn) (draw 1 you))))`));
    assert(parseDatabase("").length == 0);
}
