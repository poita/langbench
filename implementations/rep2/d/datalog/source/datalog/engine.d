/// Bottom-up semi-naive evaluation of a stratified program.
module datalog.engine;

import datalog.analysis;
import datalog.ast;
import datalog.errors : ProgramError;
import datalog.plan;
import datalog.relation;

/// The computed model: one relation per predicate.
final class Database
{
    /// Indexed by `PredId`.
    Relation[] relations;
    /// The program this database was computed from.
    const(Program)* program;

    /// Compute the perfect model of `prog`.
    ///
    /// Throws: `ProgramError` if the program is unsafe or not stratifiable.
    static Database evaluate(ref const Program prog)
    {
        auto an = analyze(prog);
        final switch (an.status)
        {
        case Status.ok: break;
        case Status.unsafeRule: throw new ProgramError("unsafe rule");
        case Status.notStratifiable: throw new ProgramError("program is not stratifiable");
        }
        auto db = new Database;
        db.program = &prog;
        foreach (ref p; prog.predicates) db.relations ~= new Relation(p.arity);
        foreach (ref r; prog.rules)
            if (r.isFact)
            {
                uint[maxArity] t;
                foreach (i, a; r.head.args) t[i] = a.id;
                db.relations[r.head.pred].insert(t[0 .. r.head.args.length]);
            }
        auto ex = new Executor(db.relations);
        foreach (ref c; an.components)
            ex.evaluateComponent(prog, c);
        return db;
    }
}

private final class Executor
{
    Relation[] rels;
    uint[] limit;          // per predicate: end of the visible snapshot
    uint[] deltaLo;        // per predicate: start of the delta range
    uint[] env;            // variable slots of the running plan
    uint[] buffer;         // derived head tuples awaiting insertion
    size_t bufferLen;
    Plan* plan;
    Relation headRel;
    uint headArity;

    this(Relation[] rels)
    {
        this.rels = rels;
        limit = new uint[rels.length];
        deltaLo = new uint[rels.length];
    }

    void snapshot()
    {
        foreach (i, r; rels) limit[i] = cast(uint) r.length;
    }

    void evaluateComponent(ref const Program prog, ref const Component comp)
    {
        if (comp.rules.length == 0) return;
        Plan[] full;
        Plan[] deltas;
        auto inComp = new bool[prog.predicates.length];
        foreach (p; comp.preds) inComp[p] = true;
        foreach (ri; comp.rules)
        {
            ref const rule = prog.rules[ri];
            full ~= compilePlan(rule);
            if (comp.recursive)
                foreach (li, ref l; rule.body)
                    if (l.kind == LiteralKind.positive && inComp[l.atom.pred])
                        deltas ~= compilePlan(rule, cast(int) li);
        }
        foreach (ref p; full) prepare(p);
        foreach (ref p; deltas) prepare(p);

        snapshot();
        foreach (ref p; full) run(p, 0, 0);
        if (!comp.recursive) return;

        foreach (p; comp.preds) deltaLo[p] = limit[p];
        while (true)
        {
            snapshot();
            bool any = false;
            foreach (p; comp.preds)
                if (deltaLo[p] < limit[p]) { any = true; break; }
            if (!any) break;
            foreach (ref p; deltas)
            {
                immutable dp = p.steps[0].pred;
                if (deltaLo[dp] < limit[dp])
                    run(p, deltaLo[dp], limit[dp]);
            }
            foreach (p; comp.preds) deltaLo[p] = limit[p];
        }
    }

    /// Resolve and create the indexes a plan needs.
    void prepare(ref Plan p)
    {
        foreach (ref s; p.steps)
            if (s.kind == StepKind.lookup)
                s.index = rels[s.pred].index(s.keyMask);
    }

    /// Run one plan, then insert the tuples it derived.
    void run(ref Plan p, uint dLo, uint dHi)
    {
        foreach (ref s; p.steps)
            if (s.index !is null) s.index.update();
        plan = &p;
        headRel = rels[p.head];
        headArity = headRel.arity;
        if (env.length < p.numSlots) env.length = p.numSlots;
        bufferLen = 0;
        this.dLo = dLo;
        this.dHi = dHi;
        if (passes(p.preFilters))
            join(0);
        immutable a = headArity;
        foreach (i; 0 .. bufferLen / a)
            headRel.insert(buffer[i * a .. (i + 1) * a]);
    }

    uint dLo, dHi;

    pragma(inline, true) uint value(in ArgSrc a) const
    {
        return a.isConst ? a.v : env[a.v];
    }

    bool passes(in Filter[] fs)
    {
        foreach (ref f; fs)
        {
            if (f.negated)
            {
                uint[maxArity] t = void;
                foreach (i, ref a; f.args) t[i] = value(a);
                if (rels[f.pred].contains(t[0 .. f.args.length])) return false;
            }
            else if (!compare(f.op, value(f.lhs), value(f.rhs)))
                return false;
        }
        return true;
    }

    /// Bind variables from `t`, verify checks and filters.
    pragma(inline, true) bool accept(Step* s, const(uint)* t)
    {
        foreach (ref b; s.binds) env[b.slot] = t[b.pos];
        foreach (ref c; s.checks)
            if (t[c.pos] != value(c.src)) return false;
        return s.filters.length == 0 || passes(s.filters);
    }

    void join(size_t i)
    {
        if (i == plan.steps.length)
        {
            emit();
            return;
        }
        Step* s = &plan.steps[i];
        Relation rel = rels[s.pred];
        immutable ar = rel.arity;
        final switch (s.kind)
        {
        case StepKind.deltaScan:
            foreach (pos; dLo .. dHi)
                if (accept(s, rel.data.ptr + cast(size_t) pos * ar))
                    join(i + 1);
            break;
        case StepKind.scan:
            foreach (pos; 0 .. limit[s.pred])
                if (accept(s, rel.data.ptr + cast(size_t) pos * ar))
                    join(i + 1);
            break;
        case StepKind.lookup:
            uint[maxArity] key = void;
            foreach (j, ref a; s.key) key[j] = value(a);
            immutable hi = limit[s.pred];
            auto ix = s.index;
            for (uint pos = ix.find(key.ptr); pos < hi; pos = ix.next(pos))
                if (accept(s, rel.data.ptr + cast(size_t) pos * ar))
                    join(i + 1);
            break;
        case StepKind.probe:
            uint[maxArity] key = void;
            foreach (j, ref a; s.key) key[j] = value(a);
            if (rel.containsPtr(key.ptr) && (s.filters.length == 0 || passes(s.filters)))
                join(i + 1);
            break;
        }
    }

    void emit()
    {
        uint[maxArity] t = void;
        immutable a = headArity;
        foreach (j, ref h; plan.headArgs) t[j] = value(h);
        if (headRel.containsPtr(t.ptr)) return;
        if (bufferLen + a > buffer.length)
            buffer.length = buffer.length * 2 + 64;
        buffer[bufferLen .. bufferLen + a] = t[0 .. a];
        bufferLen += a;
    }
}
