/// Unit tests that compare the engine with a deliberately naive reference
/// evaluator on randomly generated stratified programs.
module datalog.crosscheck;

version (unittest)  :

import std.algorithm : canFind, sort;
import std.array : appender;
import std.conv : to;
import std.format : format;
import std.random : Random, uniform;

import datalog.ast;
import datalog.driver;
import datalog.engine;
import datalog.parser;
import datalog.symbols;

/// Generates a random program. Predicates `p0 .. p3` (arity 1 or 2) live at
/// levels 0..3; positive atoms may use any predicate of the head's level or
/// lower, negated atoms only strictly lower ones, so the program is always
/// stratifiable (and safe by construction).
private string randomProgram(ref Random rng)
{
    enum levels = 4;
    immutable arities = [1u, 2, 2, 1];
    auto s = appender!string;
    string[] consts = ["0", "1", "2", "-1", "a", "b"];

    string term(uint[] vars)
    {
        return uniform(0, 4, rng) == 0 ? consts[uniform(0, consts.length, rng)] : ["X", "Y", "Z"][vars[uniform(0, vars.length, rng)]];
    }

    string atom(int pred, uint[] vars)
    {
        string r = "p" ~ pred.to!string ~ "(";
        foreach (i; 0 .. arities[pred])
            r ~= (i ? ", " : "") ~ term(vars);
        return r ~ ")";
    }

    foreach (pred; 0 .. levels)
        foreach (_; 0 .. uniform(0, 5, rng))
        {
            string f = "p" ~ pred.to!string ~ "(";
            foreach (i; 0 .. arities[pred])
                f ~= (i ? ", " : "") ~ consts[uniform(0, consts.length, rng)];
            s ~= f ~ ").\n";
        }
    foreach (pred; 1 .. levels)
        foreach (_; 0 .. uniform(1, 4, rng))
        {
            // Body: 1-3 positive atoms over variables X,Y,Z (indices 0..2), then filters.
            string body_;
            bool[3] used;
            foreach (k; 0 .. uniform(1, 4, rng))
            {
                int bp = uniform(0, pred + 1, rng);
                string a = "p" ~ bp.to!string ~ "(";
                foreach (i; 0 .. arities[bp])
                {
                    if (i)
                        a ~= ", ";
                    if (uniform(0, 6, rng) == 0)
                        a ~= consts[uniform(0, consts.length, rng)];
                    else
                    {
                        auto v = uniform(0, 3, rng);
                        used[v] = true;
                        a ~= "XYZ"[v .. v + 1];
                    }
                }
                body_ ~= (k ? ", " : "") ~ a ~ ")";
            }
            uint[] vars;
            foreach (v; 0 .. 3)
                if (used[v])
                    vars ~= v;
            if (vars.length == 0)
                continue;
            if (uniform(0, 2, rng) == 0)
                body_ ~= ", not " ~ atom(uniform(0, pred, rng), vars);
            if (uniform(0, 3, rng) == 0)
                body_ ~= ", " ~ term(vars) ~ " " ~ ["<", "<=", ">", ">=", "=", "!="][uniform(0, 6, rng)]
                    ~ " " ~ term(vars);
            s ~= atom(pred, vars) ~ " :- " ~ body_ ~ ".\n";
        }
    foreach (pred; 0 .. levels)
        s ~= "?- p" ~ pred.to!string ~ (arities[pred] == 1 ? "(X).\n" : "(X, Y).\n");
    return s[];
}

/// Naive evaluation: recompute everything from scratch until nothing changes.
/// Predicate `pN` is at level N, so evaluating levels in order is a stratification.
private Constant[][][] referenceModel(Program prog)
{
    alias Tuple = Constant[];
    auto sym = prog.symbols;
    immutable n = prog.predicates.length;
    // Tuples are keyed by their text, which is unique per constant (ints print as digits, names are letters).
    string key(const Tuple t)
    {
        string k;
        foreach (c; t)
            k ~= c.toString ~ ",";
        return k;
    }

    bool[string][] keys = new bool[string][n];
    Tuple[][] rows = new Tuple[][n];
    bool add(uint p, Tuple t)
    {
        auto k = key(t);
        if (k in keys[p])
            return false;
        keys[p][k] = true;
        rows[p] ~= t;
        return true;
    }

    foreach (ref r; prog.rules)
        if (r.body.length == 0)
        {
            Tuple t;
            foreach (a; r.head.args)
                t ~= sym[a.id];
            add(r.head.predicate, t);
        }

    // Level of predicate = digit after the 'p'.
    foreach (level; 0 .. 4)
    {
        bool changed = true;
        while (changed)
        {
            changed = false;
            foreach (ref r; prog.rules)
            {
                if (r.body.length == 0 || prog.predicates[r.head.predicate].name[1] - '0' != level)
                    continue;
                // Enumerate all assignments of the rule's variables over all constants.
                auto vals = new Constant[r.numVars];
                bool recurse(size_t v)
                {
                    bool any = false;
                    if (v == r.numVars)
                    {
                        Constant val(Term t) { return t.kind == TermKind.constant ? sym[t.id] : vals[t.id]; }

                        foreach (ref lit; r.body)
                        {
                            final switch (lit.kind)
                            {
                            case LiteralKind.positive:
                            case LiteralKind.negated:
                                Tuple t;
                                foreach (a; lit.atom.args)
                                    t ~= val(a);
                                immutable has = (key(t) in keys[lit.atom.predicate]) !is null;
                                if (has != (lit.kind == LiteralKind.positive))
                                    return false;
                                break;
                            case LiteralKind.comparison:
                                immutable c = val(lit.lhs).opCmp(val(lit.rhs));
                                final switch (lit.op)
                                {
                                case CmpOp.lt: if (!(c < 0)) return false; break;
                                case CmpOp.le: if (!(c <= 0)) return false; break;
                                case CmpOp.gt: if (!(c > 0)) return false; break;
                                case CmpOp.ge: if (!(c >= 0)) return false; break;
                                case CmpOp.eq: if (!(c == 0)) return false; break;
                                case CmpOp.ne: if (!(c != 0)) return false; break;
                                }
                                break;
                            }
                        }
                        Tuple h;
                        foreach (a; r.head.args)
                            h ~= val(a);
                        return add(r.head.predicate, h);
                    }
                    foreach (id; 0 .. sym.length)
                    {
                        vals[v] = sym[cast(uint) id];
                        any = recurse(v + 1) || any;
                    }
                    return any;
                }

                changed = recurse(0) || changed;
            }
        }
    }
    return rows.map!(r => r).array;
}

import std.algorithm : map;
import std.array : array;

unittest
{
    auto rng = Random(12345);
    size_t derivedTuples; // guards against generating only trivial programs
    foreach (iteration; 0 .. 300)
    {
        auto text = randomProgram(rng);
        auto prog = parseProgram(text);
        auto model = new Model(prog);
        auto ref_ = referenceModel(prog);

        foreach (ref q; prog.queries)
        {
            // The queries are `?- pN(X)` / `?- pN(X, Y)`: all tuples of the predicate.
            auto expected = ref_[q.atom.predicate].dup;
            expected.sort!((a, b) {
                foreach (i; 0 .. a.length)
                {
                    immutable c = a[i].opCmp(b[i]);
                    if (c)
                        return c < 0;
                }
                return false;
            });
            auto got = model.answer(q);
            derivedTuples += got.length;
            assert(got == expected, format("mismatch on program:\n%s\nquery p%s: got %s, expected %s",
                    text, prog.predicates[q.atom.predicate].name, got, expected));
        }
    }
    assert(derivedTuples > 1000);
}
