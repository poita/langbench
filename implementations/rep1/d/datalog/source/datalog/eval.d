/// Semi-naive bottom-up evaluation of a stratified program.
module datalog.eval;

import std.algorithm.comparison : max;
import std.array : Appender;

import datalog.analysis;
import datalog.ast;
import datalog.plan;
import datalog.relation;

/// The computed perfect model: one relation per predicate.
final class Model
{
    /// The program this model was computed from.
    Program program;
    /// `relations[p]` holds the tuples of predicate `p`.
    Relation[] relations;

    this(Program program) @safe
    {
        this.program = program;
        foreach (ref p; program.predicates)
            relations ~= new Relation(p.arity);
    }
}

/// Check safety and stratifiability of `program`, then compute its stratified model.
///
/// Throws `UnsafeRuleException` or `StratificationException` when the program is
/// rejected. The program must have been produced by `parseProgram` (canonical constants).
Model evaluate(Program program) @safe
{
    assert(program.isCanonical, "program constants must be canonicalised");
    checkSafety(program);
    auto strat = stratify(program);

    auto model = new Model(program);
    size_t maxVars = 0;
    uint[][] rulesByHead;
    rulesByHead.length = program.predicates.length;

    foreach (i, ref rule; program.rules)
    {
        maxVars = max(maxVars, rule.numVars);
        if (rule.isFact)
        {
            auto tuple = new Value[rule.head.args.length];
            foreach (j, t; rule.head.args)
                tuple[j] = t.id;
            model.relations[rule.head.pred].insert(tuple);
        }
        else
            rulesByHead[rule.head.pred] ~= cast(uint) i;
    }

    auto engine = Engine(model, maxVars);
    foreach (ci, comp; strat.components)
    {
        const(uint)[] ruleIds;
        foreach (p; comp)
            ruleIds ~= rulesByHead[p];
        if (ruleIds.length)
            engine.evaluateComponent(strat, cast(uint) ci, ruleIds);
    }
    return model;
}

private struct Engine
{
    Model model;
    Value[] env;
    Value[] scratch;
    Appender!(Value[]) derived;
    size_t[] lo, hi; /// per-predicate scan ranges for the current round

    this(Model model, size_t maxVars) @safe
    {
        this.model = model;
        env = new Value[maxVars + 1];
        scratch = new Value[64];
        lo = new size_t[model.relations.length];
        hi = new size_t[model.relations.length];
    }

    void evaluateComponent(ref const Stratification strat, uint component, const(uint)[] ruleIds) @safe
    {
        auto program = model.program;
        auto relations = model.relations;

        Plan[] fullPlans;
        Plan[] deltaPlans;
        bool recursive = false;
        foreach (ri; ruleIds)
        {
            ref rule = program.rules[ri];
            fullPlans ~= compilePlan(program, rule, -1, relations);
            foreach (li, ref lit; rule.body)
                if (lit.kind == LiteralKind.positive
                    && strat.componentOf[lit.atom.pred] == component)
                {
                    recursive = true;
                    deltaPlans ~= compilePlan(program, rule, cast(int) li, relations);
                }
        }

        // Round 0: every rule, full plan, against the snapshot of all relations.
        snapshot();
        foreach (ref plan; fullPlans)
            run(plan);
        if (!recursive)
            return;

        // Semi-naive rounds: each delta is the range appended by the previous round.
        while (true)
        {
            lo[] = hi[];
            snapshot();
            bool grew = false;
            foreach (p; strat.components[component])
                if (hi[p] != lo[p])
                    grew = true;
            if (!grew)
                break;
            foreach (ref plan; deltaPlans)
            {
                // Plans put the delta atom first.
                if (lo[plan.steps[0].pred] == hi[plan.steps[0].pred])
                    continue;
                run(plan);
            }
        }
    }

    void snapshot() @safe
    {
        foreach (i, rel; model.relations)
            hi[i] = rel.length;
    }

    void run(ref Plan plan) @trusted
    {
        foreach (idx; plan.indexes)
            idx.update();
        derived.clear();
        if (!passAll(plan.initial))
            return;
        if (plan.steps.length == 0)
            emit(plan);
        else
            exec(plan, 0);

        auto head = model.relations[plan.headPred];
        immutable arity = head.arity;
        auto buf = derived.data;
        for (size_t i = 0; i < buf.length; i += arity)
            head.insert(buf[i .. i + arity]);
    }

private:
    Value valueOf(Term t) const pure nothrow @nogc @safe
    {
        return t.isVariable ? env[t.id] : t.id;
    }

    bool passAll(const(Filter)[] filters) @safe
    {
        foreach (ref f; filters)
            if (!passes(f))
                return false;
        return true;
    }

    bool passes(ref const Filter f) @safe
    {
        if (f.negated)
        {
            foreach (j, t; f.args)
                scratch[j] = valueOf(t);
            return !model.relations[f.pred].contains(scratch[0 .. f.args.length]);
        }
        immutable a = valueOf(f.lhs), b = valueOf(f.rhs);
        final switch (f.op)
        {
        case CmpOp.lt:
            return a < b;
        case CmpOp.le:
            return a <= b;
        case CmpOp.gt:
            return a > b;
        case CmpOp.ge:
            return a >= b;
        case CmpOp.eq:
            return a == b;
        case CmpOp.ne:
            return a != b;
        }
    }

    bool matchTuple(const(ArgOp)[] ops, const(Value)[] tuple) @safe
    {
        foreach (ref op; ops)
        {
            immutable v = tuple[op.pos];
            final switch (op.kind)
            {
            case OpKind.constant:
                if (v != op.val)
                    return false;
                break;
            case OpKind.variable:
                if (v != env[op.val])
                    return false;
                break;
            case OpKind.bind:
                env[op.val] = v;
                break;
            }
        }
        return true;
    }

    void emit(ref const Plan plan) @safe
    {
        immutable n = plan.head.length;
        foreach (j, t; plan.head)
            scratch[j] = valueOf(t);
        auto tuple = scratch[0 .. n];
        if (!model.relations[plan.headPred].contains(tuple))
            derived.put(tuple);
    }

    void exec(ref const Plan plan, size_t level) @safe
    {
        if (level == plan.steps.length)
        {
            emit(plan);
            return;
        }
        ref step = plan.steps[level];
        auto rel = model.relations[step.pred];
        final switch (step.kind)
        {
        case StepKind.probe:
            foreach (j, ref op; step.keyOps)
                scratch[j] = op.kind == OpKind.constant ? op.val : env[op.val];
            if (rel.contains(scratch[0 .. step.keyOps.length]) && passAll(step.after))
                exec(plan, level + 1);
            break;
        case StepKind.scan:
            immutable from = step.isDelta ? lo[step.pred] : 0;
            immutable to = hi[step.pred];
            foreach (p; from .. to)
                if (matchTuple(step.matchOps, rel[p]) && passAll(step.after))
                    exec(plan, level + 1);
            break;
        case StepKind.lookup:
            Value[6] key = void;
            foreach (j, ref op; step.keyOps)
                key[j] = op.kind == OpKind.constant ? op.val : env[op.val];
            immutable limit = hi[step.pred];
            auto next = step.index.next;
            for (uint p = step.index.first(key[0 .. step.keyOps.length]); p < limit; p = next[p])
                if (matchTuple(step.matchOps, rel[p]) && passAll(step.after))
                    exec(plan, level + 1);
            break;
        }
    }
}
