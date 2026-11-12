/// Bottom-up semi-naive evaluation of a stratified program.
///
/// Every rule is compiled once into a *join plan* (an indexed nested-loop join
/// over its positive atoms; negations and comparisons are tested as soon as
/// their variables are bound). Components of the predicate dependency graph are
/// evaluated in topological order. Inside a component, round 0 runs every rule
/// on the relations as they are; each later round runs, for every rule and
/// every positive atom of the component, a variant that reads that atom from
/// the previous round's new tuples (the delta), the atoms before it from the
/// older tuples only and the atoms after it from everything that existed at the
/// start of the round. So each derivation is made exactly once.
module datalog.eval;

import datalog.analysis : Stratification;
import datalog.ast;
import datalog.relation;

/// The computed model: one relation per predicate, over ranked constants.
final class Model
{
    /// The evaluated program.
    const Program program;
    /// Relation of each predicate (indexed by `PredId`).
    Relation[] relations;
    private SymbolId[] symbolOfRank;
    private Value[] rankOfSymbol;

    private this(const Program program) @safe
    {
        this.program = program;
    }

    /// Ranks of constants: a `Value` is the position of a symbol in the total
    /// order.
    private void rank() @safe
    {
        symbolOfRank = program.symbols.sortedIds();
        rankOfSymbol = new Value[symbolOfRank.length];
        foreach (r, s; symbolOfRank)
            rankOfSymbol[s] = cast(Value) r;
    }

    /// Text of a value, as printed in answers.
    string text(Value v) const @safe
    {
        return program.symbols.text(symbolOfRank[v]);
    }

    /// Formats a tuple of predicate `pred` as `name(v1, v2, ...)`.
    string format(PredId pred, scope const(Value)[] tuple) const @safe
    {
        string s = program.predicates[pred].name ~ "(";
        foreach (i, v; tuple)
        {
            if (i)
                s ~= ", ";
            s ~= text(v);
        }
        return s ~ ")";
    }

    /// All tuples matching the query atom, in ascending tuple order.
    ///
    /// A constant matches itself; a variable that occurs several times must
    /// take the same value at each occurrence.
    const(Value)[][] answer(ref const Query query) const @safe
    {
        import std.algorithm.sorting : sort;

        auto rel = relations[query.atom.pred];
        auto args = query.atom.args;
        auto binding = new Value[query.numVars];
        auto seen = new bool[query.numVars];
        const(Value)[][] result;
        foreach (uint id; 0 .. rel.length)
        {
            auto t = rel.tuple(id);
            seen[] = false;
            bool ok = true;
            foreach (i, a; args)
            {
                if (!a.isVariable)
                    ok = t[i] == rankOfSymbol[a.id];
                else if (seen[a.id])
                    ok = t[i] == binding[a.id];
                else
                {
                    seen[a.id] = true;
                    binding[a.id] = t[i];
                }
                if (!ok)
                    break;
            }
            if (ok)
                result ~= t;
        }
        result.sort!((a, b) => a < b);
        return result;
    }
}

/// Computes the perfect model of a program that passed `checkSafety` and
/// `stratify`.
Model evaluate(const Program program, const Stratification strat) @safe
{
    auto model = new Model(program);
    model.rank();
    foreach (ref info; program.predicates)
        model.relations ~= new Relation(info.arity);

    // Facts first: they are just tuples of the relations.
    Value[] buf;
    foreach (ref rule; program.rules)
        if (rule.body.length == 0)
        {
            buf.length = rule.head.args.length;
            foreach (i, t; rule.head.args)
                buf[i] = model.rankOfSymbol[t.id];
            model.relations[rule.head.pred].insert(buf);
        }
    foreach (r; model.relations)
        r.flush();

    auto rulesOf = new const(Rule)[][strat.components.length];
    foreach (ref rule; program.rules)
        if (rule.body.length != 0)
            rulesOf[strat.componentOf[rule.head.pred]] ~= rule;

    foreach (c, comp; strat.components)
        if (rulesOf[c].length)
            evalComponent(model, strat, cast(uint) c, rulesOf[c]);
    return model;
}

private:

/// A term compiled for the executor: a constant value or a variable slot.
struct Slot
{
    bool isConst;
    Value v;

    Value get(const(Value)[] env) const @safe pure nothrow @nogc
    {
        return isConst ? v : env[v];
    }
}

enum OpKind : ubyte
{
    assign, /// bind the slot to the column
    checkConst, /// column must equal the constant
    checkSlot /// column must equal the slot's value
}

struct PosOp
{
    OpKind kind;
    Value arg;
}

enum Access : ubyte
{
    delta, /// scan the delta range of the relation
    scan, /// scan all visible tuples (nothing bound)
    index, /// probe a hash index on the bound columns
    lookup /// every column bound: membership test
}

/// Which tuples a non-delta step may see.
enum Vis : ubyte
{
    full, /// everything that existed when the round started
    old /// only tuples that existed before the current delta
}

struct Check
{
    bool negated;
    CmpOp op;
    Slot l, r; /// comparison operands
    Relation rel; /// negated atom
    Slot[] args;
}

struct Step
{
    Access access;
    Vis vis;
    Relation rel;
    Index idx;
    Slot[] key; /// bound columns in ascending column order
    PosOp[] ops; /// one per column
    Check[] post; /// tests that become possible after this step
}

struct Plan
{
    Relation head;
    Slot[] headArgs;
    uint numVars;
    Check[] pre; /// tests on constants only
    Step[] steps;
}

/// Compiles `rule`; `deltaPos` is the body position read as delta (or -1).
/// Atoms in the component before `deltaPos` only see old tuples.
Plan compile(Model model, const Stratification strat, uint comp, ref const Rule rule, int deltaPos) @safe
{
    Plan plan;
    plan.head = model.relations[rule.head.pred];
    plan.numVars = rule.numVars;

    Slot slotOf(Term t)
    {
        return t.isVariable ? Slot(false, t.id) : Slot(true, model.rankOfSymbol[t.id]);
    }

    foreach (t; rule.head.args)
        plan.headArgs ~= slotOf(t);

    auto bound = new bool[rule.numVars];
    bool slotBound(Slot s) { return s.isConst || bound[s.v]; }

    // Pending tests: negations and comparisons.
    struct Pending
    {
        Check check;
        Slot[] slots;
        bool placed;
    }

    Pending[] pending;
    size_t[] atoms; // body positions of positive atoms
    foreach (i, ref lit; rule.body)
        final switch (lit.kind)
        {
        case LiteralKind.positive:
            atoms ~= i;
            break;
        case LiteralKind.negative:
            {
                Check c;
                c.negated = true;
                c.rel = model.relations[lit.atom.pred];
                foreach (t; lit.atom.args)
                    c.args ~= slotOf(t);
                pending ~= Pending(c, c.args, false);
                break;
            }
        case LiteralKind.comparison:
            {
                Check c;
                c.op = lit.op;
                c.l = slotOf(lit.lhs);
                c.r = slotOf(lit.rhs);
                pending ~= Pending(c, [c.l, c.r], false);
                break;
            }
        }

    // Moves every pending test whose variables are all bound into `into`.
    void place(ref Check[] into)
    {
        foreach (ref p; pending)
        {
            if (p.placed)
                continue;
            bool ready = true;
            foreach (s; p.slots)
                ready = ready && slotBound(s);
            if (ready)
            {
                into ~= p.check;
                p.placed = true;
            }
        }
    }

    place(plan.pre);

    auto used = new bool[rule.body.length];
    foreach (round; 0 .. atoms.length)
    {
        // Pick the next atom: the delta atom first, then the one with the most
        // bound arguments (ties: body order).
        int best = -1;
        int bestScore = -1;
        foreach (i; atoms)
        {
            if (used[i])
                continue;
            int score;
            if (cast(int) i == deltaPos)
                score = int.max;
            else
            {
                score = 0;
                foreach (t; rule.body[i].atom.args)
                    if (!t.isVariable || bound[t.id])
                        ++score;
            }
            if (score > bestScore)
            {
                bestScore = score;
                best = cast(int) i;
            }
        }
        used[best] = true;
        auto atom = rule.body[best].atom;

        Step st;
        st.rel = model.relations[atom.pred];
        uint keyMask;
        auto seenHere = new bool[rule.numVars];
        foreach (col, t; atom.args)
        {
            if (!t.isVariable)
            {
                st.ops ~= PosOp(OpKind.checkConst, model.rankOfSymbol[t.id]);
                st.key ~= slotOf(t);
                keyMask |= 1u << col;
            }
            else if (bound[t.id])
            {
                st.ops ~= PosOp(OpKind.checkSlot, t.id);
                st.key ~= slotOf(t);
                keyMask |= 1u << col;
            }
            else if (seenHere[t.id])
                st.ops ~= PosOp(OpKind.checkSlot, t.id);
            else
            {
                st.ops ~= PosOp(OpKind.assign, t.id);
                seenHere[t.id] = true;
            }
        }
        foreach (t; atom.args)
            if (t.isVariable)
                bound[t.id] = true;

        if (best == deltaPos)
        {
            st.access = Access.delta;
            st.key = null;
        }
        else
        {
            if (keyMask == 0)
                st.access = Access.scan;
            else if (st.key.length == atom.args.length)
                st.access = Access.lookup;
            else
            {
                st.access = Access.index;
                st.idx = st.rel.index(keyMask);
            }
            bool inComp = strat.componentOf[atom.pred] == comp;
            st.vis = (deltaPos >= 0 && inComp && best < deltaPos) ? Vis.old : Vis.full;
        }
        place(st.post);
        plan.steps ~= st;
    }
    return plan;
}

bool compare(CmpOp op, Value a, Value b) @safe pure nothrow @nogc
{
    final switch (op)
    {
    case CmpOp.lt: return a < b;
    case CmpOp.le: return a <= b;
    case CmpOp.gt: return a > b;
    case CmpOp.ge: return a >= b;
    case CmpOp.eq: return a == b;
    case CmpOp.ne: return a != b;
    }
}

/// Runs plans: a recursive nested-loop join over the steps of a plan.
struct Executor
{
    Value[] env;
    Value[] tmp;
    Plan* plan;

    void run(ref Plan p) @trusted
    {
        plan = &p;
        env.length = p.numVars;
        if (tmp.length < 8)
            tmp.length = 8;
        foreach (ref c; p.pre)
            if (!passes(c))
                return;
        exec(0);
    }

    bool passes(ref const Check c) @safe
    {
        if (!c.negated)
            return compare(c.op, c.l.get(env), c.r.get(env));
        if (tmp.length < c.args.length)
            tmp.length = c.args.length;
        foreach (i, s; c.args)
            tmp[i] = s.get(env);
        return c.rel.find(tmp[0 .. c.args.length]) == none;
    }

    bool postOk(ref const Step s) @safe
    {
        foreach (ref c; s.post)
            if (!passes(c))
                return false;
        return true;
    }

    void exec(size_t i) @safe
    {
        if (i == plan.steps.length)
        {
            emit();
            return;
        }
        auto s = &plan.steps[i];
        auto rel = s.rel;
        final switch (s.access)
        {
        case Access.delta:
            foreach (id; rel.deltaStart .. rel.deltaEnd)
                tryTuple(i, s, id);
            break;
        case Access.scan:
            foreach (id; 0 .. limit(s))
                tryTuple(i, s, id);
            break;
        case Access.index:
            {
                ulong h = hashStart;
                foreach (k; s.key)
                    h = hashStep(h, k.get(env));
                auto lim = limit(s);
                for (auto id = s.idx.first(h); id != none; id = s.idx.next(id))
                    if (id < lim)
                        tryTuple(i, s, id);
                break;
            }
        case Access.lookup:
            {
                foreach (j, k; s.key)
                    tmp[j] = k.get(env);
                auto id = rel.find(tmp[0 .. s.key.length]);
                if (id != none && id < limit(s) && postOk(*s))
                    exec(i + 1);
                break;
            }
        }
    }

    uint limit(const Step* s) const @safe
    {
        return s.vis == Vis.old ? s.rel.deltaStart : s.rel.indexedLength;
    }

    void tryTuple(size_t i, const Step* s, uint id) @safe
    {
        auto t = s.rel.tuple(id);
        foreach (col, op; s.ops)
        {
            final switch (op.kind)
            {
            case OpKind.assign:
                env[op.arg] = t[col];
                break;
            case OpKind.checkConst:
                if (t[col] != op.arg)
                    return;
                break;
            case OpKind.checkSlot:
                if (t[col] != env[op.arg])
                    return;
                break;
            }
        }
        if (postOk(*s))
            exec(i + 1);
    }

    void emit() @safe
    {
        auto n = plan.headArgs.length;
        if (tmp.length < n)
            tmp.length = n;
        // `tmp` may be reused by tests, but none is running now.
        foreach (j, s; plan.headArgs)
            tmp[j] = s.get(env);
        plan.head.insert(tmp[0 .. n]);
    }
}

void evalComponent(Model model, const Stratification strat, uint comp, const(Rule)[] rules) @safe
{
    auto members = strat.components[comp];

    Plan[] first;
    Plan[] variants;
    foreach (ref rule; rules)
    {
        first ~= compile(model, strat, comp, rule, -1);
        foreach (i, ref lit; rule.body)
            if (lit.kind == LiteralKind.positive && strat.componentOf[lit.atom.pred] == comp)
                variants ~= compile(model, strat, comp, rule, cast(int) i);
    }

    Executor ex;
    auto prev = new uint[members.length];
    foreach (k, p; members)
        prev[k] = model.relations[p].length;

    foreach (ref p; first)
        ex.run(p);

    // Each iteration turns the tuples added by the previous round into the delta.
    while (variants.length)
    {
        bool any = false;
        foreach (k, p; members)
        {
            auto r = model.relations[p];
            r.deltaStart = prev[k];
            r.deltaEnd = r.length;
            prev[k] = r.length;
            r.flush();
            any = any || r.deltaStart != r.deltaEnd;
        }
        if (!any)
            break;
        foreach (ref p; variants)
            ex.run(p);
    }
    foreach (p; members)
        model.relations[p].flush();
}
