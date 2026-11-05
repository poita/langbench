/**
 * Evaluation of selectors, filters, amounts and conditions (SPEC 6.3-6.7),
 * and target legality and enumeration (SPEC 12).
 */
module cardgame.eval;

import std.algorithm : sort;

import cardgame.cards;
import cardgame.derive;
import cardgame.game;

/// Evaluation context: who is asking, and what `it`, `that` and `(t n)` mean.
struct Ctx
{
    int ctrl;
    int src;
    Entry entry;
    Subject it;
    int[] thatStack;
    /// True while evaluating an aura static: `(edge s)` and `(core s)` use base values.
    bool inAura;
}

/// Test one filter against an object.
bool filterMatch(Game g, Filter f, int oid, ref Ctx c)
{
    auto card = g.cardOf(oid);
    final switch (f.kind)
    {
    case FilterKind.kw:
        return card.hasKeyword(f.kw);
    case FilterKind.noKw:
        return !card.hasKeyword(f.kw);
    case FilterKind.tag:
        foreach (t; card.tagIds)
            if (t == f.tag)
                return true;
        return false;
    case FilterKind.type:
        return card.type == f.type;
    case FilterKind.cost:
        return compare(f.cmp, card.cost, f.n);
    case FilterKind.edge:
        return compare(f.cmp, g.baseEdge(oid), f.n);
    case FilterKind.core:
        return compare(f.cmp, g.baseCore(oid), f.n);
    case FilterKind.wounded:
        return g.onField(oid) && g.objs[oid].wounds > 0;
    case FilterKind.ready:
        return g.onField(oid) && !g.objs[oid].exhausted;
    case FilterKind.exhausted:
        return g.onField(oid) && g.objs[oid].exhausted;
    case FilterKind.settling:
        return g.isSettling(oid);
    case FilterKind.attacking:
        return g.onField(oid) && g.objs[oid].attacking;
    case FilterKind.blocking:
        return g.onField(oid) && g.objs[oid].blocking;
    case FilterKind.mine:
        return g.ctl(oid) == c.ctrl;
    case FilterKind.enemy:
        return g.ctl(oid) != c.ctrl;
    case FilterKind.other:
        return oid != c.src;
    case FilterKind.not:
        return !filterMatch(g, f.inner, oid, c);
    }
}

/// Do all filters hold?
bool filtersMatch(Game g, Filter[] fs, int oid, ref Ctx c)
{
    foreach (f; fs)
        if (!filterMatch(g, f, oid, c))
            return false;
    return true;
}

private bool scopeOk(ScopeKind s, int who, int ctrl) @safe pure nothrow @nogc
{
    final switch (s)
    {
    case ScopeKind.yours:
        return who == ctrl;
    case ScopeKind.theirs:
        return who != ctrl;
    case ScopeKind.all:
        return true;
    }
}

/// Sort object ids into canonical order.
void sortCanon(Game g, int[] ids)
{
    ids.sort!((a, b) => g.canonLess(a, b));
}

/// Objects on the Field matching a `units`/`relics` selector, in canonical order.
private void fieldMatches(Game g, Sel s, CardType t, ref Ctx c, ref int[] result)
{
    foreach (oid; g.field)
    {
        if (g.cardOf(oid).type != t)
            continue;
        if (!scopeOk(s.scp, g.ctl(oid), c.ctrl))
            continue;
        if (!filtersMatch(g, s.filters, oid, c))
            continue;
        result ~= oid;
    }
}

/// Objects yielded by an object selector, appended to `result` in canonical order.
void selObjs(Game g, Sel s, ref Ctx c, ref int[] result)
{
    final switch (s.kind)
    {
    case SelKind.self:
        result ~= c.src;
        break;
    case SelKind.it:
        if (c.it.kind == 1)
            result ~= c.it.id;
        break;
    case SelKind.that:
        if (c.thatStack.length)
            result ~= c.thatStack[$ - 1];
        break;
    case SelKind.target:
        if (c.entry !is null && s.n >= 1 && s.n <= c.entry.targets.length)
        {
            auto t = c.entry.targets[s.n - 1];
            if (t.kind == 1 && !c.entry.removed[s.n - 1])
                result ~= t.id;
        }
        break;
    case SelKind.units:
        fieldMatches(g, s, CardType.unit, c, result);
        break;
    case SelKind.relics:
        fieldMatches(g, s, CardType.relic, c, result);
        break;
    case SelKind.cards:
        {
            immutable start = result.length;
            foreach (p; 0 .. 2)
            {
                if (!scopeOk(s.scp, p, c.ctrl))
                    continue;
                const(int)[] zone;
                final switch (s.zone)
                {
                case ZoneKind.hand:
                    zone = g.hand[p];
                    break;
                case ZoneKind.ash:
                    zone = g.ash[p];
                    break;
                case ZoneKind.vault:
                    zone = g.vault[p];
                    break;
                case ZoneKind.rift:
                    zone = g.rift[p];
                    break;
                case ZoneKind.none:
                case ZoneKind.field:
                case ZoneKind.chain:
                    break;
                }
                foreach (oid; zone)
                    if (filtersMatch(g, s.filters, oid, c))
                        result ~= oid;
            }
            sortCanon(g, result[start .. $]);
            break;
        }
    case SelKind.randomUnit:
        {
            int[] list;
            fieldMatches(g, s, CardType.unit, c, list);
            if (list.length)
                result ~= list[cast(size_t) g.rng.below(list.length)];
            break;
        }
    case SelKind.you:
    case SelKind.foe:
    case SelKind.both:
    case SelKind.ownerOf:
        break;
    }
}

/// Players yielded by a player selector, as a bit mask (bit 0 = A, bit 1 = B).
uint playerMask(Game g, Sel s, ref Ctx c)
{
    final switch (s.kind)
    {
    case SelKind.you:
        return 1u << c.ctrl;
    case SelKind.foe:
        return 1u << (1 - c.ctrl);
    case SelKind.both:
        return 3;
    case SelKind.target:
        if (c.entry !is null && s.n >= 1 && s.n <= c.entry.targets.length)
        {
            auto t = c.entry.targets[s.n - 1];
            if (t.kind == 0 && !c.entry.removed[s.n - 1])
                return 1u << t.id;
        }
        return 0;
    case SelKind.ownerOf:
        {
            if (s.inner.kind == SelKind.target)
            {
                immutable m = playerMask(g, s.inner, c);
                if (m)
                    return m;
            }
            int[] objs;
            selObjs(g, s.inner, c, objs);
            uint m = 0;
            foreach (o; objs)
                m |= 1u << g.objs[o].owner;
            return m;
        }
    case SelKind.self:
    case SelKind.it:
    case SelKind.that:
    case SelKind.units:
    case SelKind.relics:
    case SelKind.cards:
    case SelKind.randomUnit:
        return 0;
    }
}

/// Things yielded by a damage selector, in ascending target-key order.
Target[] selTargets(Game g, Sel s, ref Ctx c)
{
    Target[] r;
    switch (s.kind)
    {
    case SelKind.you:
    case SelKind.foe:
    case SelKind.both:
    case SelKind.ownerOf:
        immutable m = playerMask(g, s, c);
        foreach (p; 0 .. 2)
            if (m & (1u << p))
                r ~= Target.player(p);
        break;
    case SelKind.target:
        if (c.entry !is null && s.n >= 1 && s.n <= c.entry.targets.length)
        {
            auto t = c.entry.targets[s.n - 1];
            if (t.kind != 2 && !c.entry.removed[s.n - 1])
                r ~= t;
        }
        break;
    case SelKind.it:
        if (c.it.kind == 2)
            r ~= Target.player(c.it.id);
        else if (c.it.kind == 1)
            r ~= Target.object(c.it.id);
        break;
    default:
        int[] objs;
        selObjs(g, s, c, objs);
        foreach (o; objs)
            r ~= Target.object(o);
        break;
    }
    return r;
}

private long sumHandLike(Game g, AmtKind k, uint mask)
{
    long total = 0;
    foreach (p; 0 .. 2)
        if (mask & (1u << p))
        {
            final switch (k)
            {
            case AmtKind.hand:
                total += g.hand[p].length;
                break;
            case AmtKind.ash:
                total += g.ash[p].length;
                break;
            case AmtKind.vault:
                total += g.vault[p].length;
                break;
            case AmtKind.constant:
            case AmtKind.count:
            case AmtKind.edge:
            case AmtKind.core:
            case AmtKind.wounds:
                break;
            }
        }
    return total;
}

/// Evaluate an amount.
long amtVal(Game g, Amt a, ref Ctx c)
{
    final switch (a.kind)
    {
    case AmtKind.constant:
        return a.value;
    case AmtKind.count:
        {
            int[] objs;
            selObjs(g, a.sel, c, objs);
            return objs.length;
        }
    case AmtKind.hand:
    case AmtKind.ash:
    case AmtKind.vault:
        return sumHandLike(g, a.kind, playerMask(g, a.sel, c));
    case AmtKind.edge:
    case AmtKind.core:
    case AmtKind.wounds:
        {
            int[] objs;
            selObjs(g, a.sel, c, objs);
            long total = 0;
            foreach (o; objs)
            {
                if (a.kind == AmtKind.wounds)
                    total += g.onField(o) ? g.objs[o].wounds : 0;
                else if (a.kind == AmtKind.edge)
                    total += c.inAura ? g.baseEdge(o) : g.edgeOf(o);
                else
                    total += c.inAura ? g.baseCore(o) : g.coreOf(o);
            }
            return total;
        }
    }
}

/// Evaluate a condition.
bool condVal(Game g, Cond cd, ref Ctx c)
{
    final switch (cd.kind)
    {
    case CondKind.count:
        {
            int[] objs;
            selObjs(g, cd.sel, c, objs);
            return compare(cd.cmp, objs.length, cd.n);
        }
    case CondKind.spire:
        {
            immutable m = playerMask(g, cd.sel, c);
            long t = 0;
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    t += g.spire[p];
            return compare(cd.cmp, t, cd.n);
        }
    case CondKind.ember:
        {
            immutable m = playerMask(g, cd.sel, c);
            long t = 0;
            foreach (p; 0 .. 2)
                if (m & (1u << p))
                    t += g.ember[p];
            return compare(cd.cmp, t, cd.n);
        }
    case CondKind.hand:
        return compare(cd.cmp, sumHandLike(g, AmtKind.hand, playerMask(g, cd.sel, c)), cd.n);
    case CondKind.ash:
        return compare(cd.cmp, sumHandLike(g, AmtKind.ash, playerMask(g, cd.sel, c)), cd.n);
    case CondKind.vault:
        return compare(cd.cmp, sumHandLike(g, AmtKind.vault, playerMask(g, cd.sel, c)), cd.n);
    case CondKind.myturn:
        return g.active == c.ctrl;
    case CondKind.and:
        foreach (s; cd.subs)
            if (!condVal(g, s, c))
                return false;
        return true;
    case CondKind.or:
        foreach (s; cd.subs)
            if (condVal(g, s, c))
                return true;
        return false;
    case CondKind.not:
        return !condVal(g, cd.subs[0], c);
    }
}

// ----------------------------------------------------------------- targeting

private bool unitLegal(Game g, TSpec ts, int oid, int ctrl, int src)
{
    if (!g.onField(oid) || g.cardOf(oid).type != CardType.unit)
        return false;
    auto c = Ctx(ctrl, src);
    if (!filtersMatch(g, ts.filters, oid, c))
        return false;
    if (g.hasKw(oid, Keyword.spectral) && g.ctl(oid) != ctrl)
        return false;
    return true;
}

/// Is `t` a legal target for `ts` of an ability controlled by `ctrl` with source `src`?
/// `announcing` is the cid of the entry being announced or resolved (0 for none).
bool targetLegal(Game g, TSpec ts, Target t, int ctrl, int src, int announcing)
{
    final switch (ts.kind)
    {
    case TKind.unit:
        return t.kind == 1 && unitLegal(g, ts, t.id, ctrl, src);
    case TKind.relic:
        {
            if (t.kind != 1 || !g.onField(t.id) || g.cardOf(t.id).type != CardType.relic)
                return false;
            auto c = Ctx(ctrl, src);
            return filtersMatch(g, ts.filters, t.id, c);
        }
    case TKind.any:
        if (t.kind == 0)
            return true;
        return t.kind == 1 && unitLegal(g, ts, t.id, ctrl, src);
    case TKind.player:
        return t.kind == 0;
    case TKind.chained:
        if (t.kind != 2 || t.id == announcing)
            return false;
        foreach (e; g.chain)
            if (e.cid == t.id)
                return true;
        return false;
    case TKind.ashcard:
        {
            if (t.kind != 1 || !g.exists(t.id) || g.objs[t.id].zone != ZoneKind.ash)
                return false;
            auto c = Ctx(ctrl, src);
            return filtersMatch(g, ts.filters, t.id, c);
        }
    }
}

/// Candidate targets of one specification in ascending target-key order.
Target[] candidates(Game g, TSpec ts, int ctrl, int src, int announcing)
{
    Target[] r;
    final switch (ts.kind)
    {
    case TKind.unit:
    case TKind.relic:
        foreach (oid; g.field)
            if (targetLegal(g, ts, Target.object(oid), ctrl, src, announcing))
                r ~= Target.object(oid);
        break;
    case TKind.any:
        r ~= Target.player(0);
        r ~= Target.player(1);
        foreach (oid; g.field)
            if (targetLegal(g, ts, Target.object(oid), ctrl, src, announcing))
                r ~= Target.object(oid);
        break;
    case TKind.player:
        r ~= Target.player(0);
        r ~= Target.player(1);
        break;
    case TKind.chained:
        {
            int[] cids;
            foreach (e; g.chain)
                if (e.cid != announcing)
                    cids ~= e.cid;
            cids.sort();
            foreach (cid; cids)
                r ~= Target.chain(cid);
            break;
        }
    case TKind.ashcard:
        {
            int[] ids;
            foreach (p; 0 .. 2)
                foreach (oid; g.ash[p])
                    if (targetLegal(g, ts, Target.object(oid), ctrl, src, announcing))
                        ids ~= oid;
            sortCanon(g, ids);
            foreach (oid; ids)
                r ~= Target.object(oid);
            break;
        }
    }
    return r;
}

/// Enumerate every tuple of distinct legal targets, in lexicographic key order.
Target[][] targetTuples(Game g, TSpec[] specs, int ctrl, int src, int announcing)
{
    Target[][] lists;
    foreach (s; specs)
        lists ~= candidates(g, s, ctrl, src, announcing);
    Target[][] result;
    Target[] cur;

    void rec(size_t i)
    {
        if (i == lists.length)
        {
            result ~= cur.dup;
            return;
        }
        foreach (t; lists[i])
        {
            bool dup = false;
            foreach (u; cur)
                if (u == t)
                {
                    dup = true;
                    break;
                }
            if (dup)
                continue;
            cur ~= t;
            rec(i + 1);
            cur.length = cur.length - 1;
        }
    }

    rec(0);
    return result;
}

/// Pick the automatic targets of a trigger (SPEC 13.4); false if some spec has no candidate.
bool autoTargets(Game g, TSpec[] specs, int ctrl, int src, ref Target[] chosen)
{
    chosen.length = 0;
    foreach (s; specs)
    {
        auto cands = candidates(g, s, ctrl, src, 0);
        bool found = false;
        foreach (t; cands)
        {
            bool dup = false;
            foreach (u; chosen)
                if (u == t)
                {
                    dup = true;
                    break;
                }
            if (!dup)
            {
                chosen ~= t;
                found = true;
                break;
            }
        }
        if (!found)
            return false;
    }
    return true;
}
