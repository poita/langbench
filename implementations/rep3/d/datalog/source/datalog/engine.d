/**
 * Bottom-up semi-naive evaluation of a stratified program.
 *
 * Components of the predicate dependency graph are evaluated in topological
 * order. A recursive component runs one full round and then delta rounds: every
 * rule gets one variant per body atom of the component, scanning that atom over
 * the tuples appended in the previous round and reading all other atoms from the
 * round-start snapshot. Derived tuples are buffered while a plan runs and
 * inserted right after it, so no relation grows during a join.
 */
module datalog.engine;

import std.array : Appender;

import datalog.analysis;
import datalog.ast;
import datalog.plan;
import datalog.relation;

/// The computed model: one relation of integer tuples per predicate.
struct Database
{
    /// Indexed by predicate id of the `Program` it was created for.
    Relation[] relations;

    /// Creates empty relations for every predicate of `program`.
    this(const ref Program program)
    {
        relations = new Relation[program.predicates.length];
        foreach (i, ref p; program.predicates)
            relations[i] = new Relation(p.arity);
    }
}

/**
 * Computes the perfect model of `program` (which must be safe, with
 * stratification `strat`) and returns it.
 */
Database evaluate(const ref Program program, const ref Stratification strat)
{
    auto db = Database(program);

    // Facts go straight into their relations.
    uint[] tmp;
    foreach (ref r; program.rules)
    {
        if (!r.isFact) continue;
        tmp.length = r.head.args.length;
        foreach (i, t; r.head.args)
            tmp[i] = t.id;
        db.relations[r.head.predicate].insert(tmp);
    }

    auto exec = new Executor(db.relations.length);
    foreach (c, comp; strat.components)
    {
        const(Rule)[] rules;
        foreach (ref r; program.rules)
            if (!r.isFact && strat.componentOf[r.head.predicate] == c)
                rules ~= r;
        if (rules.length == 0) continue;
        evaluateComponent(rules, cast(uint) c, strat, db, exec);
    }
    return db;
}

private void evaluateComponent(const(Rule)[] rules, uint comp, const ref Stratification strat,
                               ref Database db, Executor exec)
{
    const npreds = db.relations.length;
    Plan[] full;
    struct Variant { Plan plan; uint deltaPred; }
    Variant[] variants;
    foreach (ref r; rules)
    {
        full ~= compilePlan(r, db.relations, -1);
        if (!strat.recursive[comp]) continue;
        foreach (i, ref l; r.body)
            if (l.kind == LiteralKind.positive && strat.componentOf[l.atom.predicate] == comp)
                variants ~= Variant(compilePlan(r, db.relations, cast(int) i), l.atom.predicate);
    }

    auto hi = new uint[npreds];
    foreach (p; 0 .. npreds)
        hi[p] = db.relations[p].length;
    auto prevStart = hi.dup;

    // Round 0: every rule, full plan.
    foreach (ref p; full)
        exec.run(p, hi, 0, 0);
    if (!strat.recursive[comp]) return;

    while (true)
    {
        foreach (p; 0 .. npreds)
            hi[p] = db.relations[p].length;
        bool any;
        foreach (p; strat.components[comp])
            if (hi[p] > prevStart[p]) any = true;
        if (!any) break;
        auto lo = prevStart.dup;
        foreach (ref v; variants)
        {
            if (hi[v.deltaPred] > lo[v.deltaPred])
                exec.run(v.plan, hi, lo[v.deltaPred], hi[v.deltaPred]);
        }
        prevStart[] = hi[];
    }
}

/// Runs plans: a recursive nested-loop join over the steps of a plan.
private final class Executor
{
    private Plan* plan;
    private const(uint)[] hi;
    private uint deltaLo, deltaHi;
    private uint[] slots = new uint[64];
    private uint[] scratch = new uint[64];
    private uint[] keyBuf = new uint[64];
    private Appender!(uint[]) buffer;

    this(size_t) {}

    /**
     * Runs `p` with relation sizes `hi` (the round-start snapshot) and delta
     * range `[lo, dhi)`, then inserts the derived tuples.
     */
    void run(ref Plan p, const(uint)[] hi_, uint lo, uint dhi)
    {
        foreach (ix; p.indexes)
            ix.update();
        plan = &p;
        hi = hi_;
        deltaLo = lo;
        deltaHi = dhi;
        if (slots.length < p.numVars)
            slots.length = p.numVars;
        buffer.clear();
        if (passes(p.pre))
            go(0);
        const arity = p.headArgs.length;
        auto data = buffer.data;
        auto rel = p.headRelation;
        for (size_t i = 0; i < data.length; i += arity)
            rel.insert(data[i .. i + arity]);
    }

    private uint value(in Arg a) const
    {
        return a.kind == ArgKind.constant ? a.value : slots[a.value];
    }

    private bool passes(const Filter[] filters)
    {
        foreach (ref f; filters)
        {
            if (f.isNegation)
            {
                foreach (i, a; f.args)
                    scratch[i] = value(a);
                if (f.relation.contains(scratch[0 .. f.args.length]))
                    return false;
            }
            else if (!compare(f.op, value(f.lhs), value(f.rhs)))
                return false;
        }
        return true;
    }

    private void emit()
    {
        const n = plan.headArgs.length;
        foreach (i, a; plan.headArgs)
            scratch[i] = value(a);
        const t = scratch[0 .. n];
        if (!plan.headRelation.contains(t))
            buffer.put(t);
    }

    private void go(size_t si)
    {
        if (si == plan.steps.length)
        {
            emit();
            return;
        }
        const st = &plan.steps[si];
        final switch (st.kind)
        {
        case StepKind.scan:
        {
            uint lo = 0, h = hi[st.predicate];
            if (st.isDelta) { lo = deltaLo; h = deltaHi; }
            for (uint p = lo; p < h; p++)
                visit(st, si, st.relation[p]);
            break;
        }
        case StepKind.lookup:
        {
            foreach (i, c; st.keyColumns)
                keyBuf[i] = value(st.args[c]);
            const h = hi[st.predicate];
            const nx = st.index.next;
            for (uint p = st.index.find(keyBuf[0 .. st.keyColumns.length]); p < h; p = nx[p])
                visit(st, si, st.relation[p]);
            break;
        }
        case StepKind.probe:
        {
            foreach (i, a; st.args)
                scratch[i] = value(a);
            if (st.relation.contains(scratch[0 .. st.args.length]) && passes(st.filters))
                go(si + 1);
            break;
        }
        }
    }

    private void visit(const Step* st, size_t si, const(uint)[] t)
    {
        foreach (i, a; st.args)
        {
            final switch (a.kind)
            {
            case ArgKind.constant:
                if (t[i] != a.value) return;
                break;
            case ArgKind.bound:
            case ArgKind.check:
                if (t[i] != slots[a.value]) return;
                break;
            case ArgKind.bind:
                slots[a.value] = t[i];
                break;
            }
        }
        if (passes(st.filters))
            go(si + 1);
    }
}
