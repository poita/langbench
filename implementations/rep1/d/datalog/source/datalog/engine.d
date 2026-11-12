/// Bottom-up semi-naive evaluation of stratified programs.
module datalog.engine;

import std.algorithm.sorting : sort;

import datalog.analysis;
import datalog.ast;
import datalog.exec;
import datalog.plan;
import datalog.relation;
import datalog.symbols;

/// The perfect model of a stratified Datalog program.
///
/// Construction checks the program for safety and stratifiability (throwing
/// `UnsafeRuleException` / `StratificationException`) and then computes every
/// relation. Queries are answered from the finished model with `answer`.
final class Model
{
    private Program program_;
    private Relation[] relations;
    private uint[] rank; // constant id -> rank
    private Constant[] byRank; // rank -> constant

    /// Evaluates `program`.
    this(Program program)
    {
        program_ = program;
        checkSafety(program);
        auto strata = stratify(program);

        auto ids = program.symbols.ranks;
        rank = ids;
        byRank = new Constant[ids.length];
        foreach (id, r; ids)
            byRank[r] = program.symbols[cast(uint) id];

        foreach (ref p; program.predicates)
            relations ~= new Relation(p.arity);

        loadFacts();
        foreach (ref s; strata)
            evaluateStratum(s);
    }

    /// The program this model was computed from.
    inout(Program) program() inout @safe pure nothrow @nogc
    {
        return program_;
    }

    private void loadFacts()
    {
        uint[] tuple;
        foreach (ref rule; program_.rules)
        {
            if (rule.body.length)
                continue;
            tuple.length = 0;
            foreach (t; rule.head.args)
                tuple ~= rank[t.id];
            relations[rule.head.predicate].insert(tuple);
        }
    }

    private void evaluateStratum(ref const Stratum stratum)
    {
        if (stratum.rules.length == 0)
            return;
        auto inStratum = new bool[relations.length];
        foreach (p; stratum.predicates)
            inStratum[p] = true;

        // Plans: every rule once, plus one variant per recursive atom.
        JoinPlan[] initial;
        JoinPlan[] variants;
        foreach (ruleNo; stratum.rules)
        {
            ref const rule = program_.rules[ruleNo];
            initial ~= compileRule(program_, rule, -1, inStratum, rank, relations);
            if (!stratum.recursive)
                continue;
            foreach (li, ref lit; rule.body)
                if (lit.kind == LiteralKind.positive && inStratum[lit.atom.predicate])
                    variants ~= compileRule(program_, rule, cast(int) li, inStratum, rank, relations);
        }

        Executor ex;
        ex.relations = relations;
        ex.windowStart = new size_t[relations.length];
        ex.windowEnd = new size_t[relations.length];

        void syncAll()
        {
            foreach (r; relations)
                r.syncIndexes();
        }

        // First pass: all rules over everything that exists now.
        syncAll();
        foreach (p, r; relations)
            ex.windowEnd[p] = r.count;
        foreach (ref plan; initial)
            ex.run(plan);

        if (!stratum.recursive)
            return;

        // Rounds: the rows added by the previous pass are the delta.
        while (true)
        {
            bool any = false;
            foreach (p; stratum.predicates)
            {
                ex.windowStart[p] = ex.windowEnd[p];
                ex.windowEnd[p] = relations[p].count;
                any = any || ex.windowEnd[p] > ex.windowStart[p];
            }
            if (!any)
                break;
            syncAll();
            foreach (ref plan; variants)
                ex.run(plan);
        }
    }

    /// Number of tuples in `name/arity`'s relation (0 if the predicate is unknown).
    size_t size(string name, uint arity) const
    {
        foreach (i, ref p; program_.predicates)
            if (p.name == name && p.arity == arity)
                return relations[i].count;
        return 0;
    }

    /// The tuples matching `query`, in ascending tuple order.
    ///
    /// A query matches a tuple when each constant of the query equals the
    /// tuple's component and each variable occurring several times in the
    /// query is bound to the same value everywhere.
    Constant[][] answer(ref const Query query)
    {
        auto rel = relations[query.atom.predicate];
        immutable arity = rel.arity;

        // For every column: constant rank, or the first column holding the same variable.
        auto isConst = new bool[arity];
        auto want = new uint[arity];
        auto sameAs = new int[arity];
        sameAs[] = -1;
        int[uint] firstColumn;
        foreach (c, t; query.atom.args)
        {
            if (t.kind == TermKind.constant)
            {
                isConst[c] = true;
                want[c] = rank[t.id];
            }
            else if (auto p = t.id in firstColumn)
                sameAs[c] = *p;
            else
                firstColumn[t.id] = cast(int) c;
        }

        size_t[] matches;
        foreach (r; 0 .. rel.count)
        {
            auto row = rel.row(r);
            bool ok = true;
            foreach (c; 0 .. arity)
            {
                if ((isConst[c] && row[c] != want[c]) || (sameAs[c] >= 0 && row[c] != row[sameAs[c]]))
                {
                    ok = false;
                    break;
                }
            }
            if (ok)
                matches ~= r;
        }
        matches.sort!((a, b) => rel.row(a) < rel.row(b));

        auto result = new Constant[][matches.length];
        foreach (i, r; matches)
        {
            auto tuple = new Constant[arity];
            foreach (c, v; rel.row(r))
                tuple[c] = byRank[v];
            result[i] = tuple;
        }
        return result;
    }
}
