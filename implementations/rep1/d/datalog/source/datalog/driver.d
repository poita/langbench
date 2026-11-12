/// Text-in, text-out entry point used by the command-line tool.
module datalog.driver;

import std.array : appender;

import datalog.ast;
import datalog.engine;
import datalog.parser;
import datalog.symbols;

/// Appends the answer to one query in the output format: one `p(v1, ..., vn)`
/// line per tuple, then `-- N`.
void formatAnswer(Sink)(ref Sink sink, const Program program, ref const Query query,
    const Constant[][] tuples)
{
    immutable name = program.predicates[query.atom.predicate].name;
    foreach (tuple; tuples)
    {
        sink.put(name);
        sink.put('(');
        foreach (i, c; tuple)
        {
            if (i)
                sink.put(", ");
            if (c.isInteger)
            {
                import std.conv : to;

                sink.put(c.number.to!string);
            }
            else
                sink.put(c.name);
        }
        sink.put(")\n");
    }
    sink.put("-- ");
    {
        import std.conv : to;

        sink.put(tuples.length.to!string);
    }
    sink.put('\n');
}

/// Parses and evaluates `source` and returns the output for all its queries.
///
/// Throws `ParseException`, `UnsafeRuleException` or `StratificationException`
/// if the program is malformed, unsafe or not stratifiable.
string solve(string source)
{
    auto program = parseProgram(source);
    auto model = new Model(program);
    auto output = appender!string;
    foreach (ref query; program.queries)
        formatAnswer(output, program, query, model.answer(query));
    return output[];
}

unittest
{
    import std.exception : assertThrown;
    import datalog.errors;

    // Example 1 of the specification: transitive closure.
    assert(solve(`
        edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
        path(X, Y) :- edge(X, Y).
        path(X, Z) :- edge(X, Y), path(Y, Z).
        ?- path(1, X).
        ?- path(4, X).
        ?- path(X, X).
    `) == "path(1, 1)\npath(1, 2)\npath(1, 3)\npath(1, 4)\n-- 4\n-- 0\n"
        ~ "path(1, 1)\npath(2, 2)\npath(3, 3)\n-- 3\n");

    // Example 2: negation, comparisons, mixed constants.
    assert(solve(`
        % nodes and links
        node(a). node(b). node(c). node(5). node(-2).
        link(a, b). link(b, 5). link(5, 5).
        reach(X, Y) :- link(X, Y).
        reach(X, Z) :- reach(X, Y), link(Y, Z).
        sink(X) :- node(X), not hasout(X).
        hasout(X) :- link(X, _).
        small(X) :- node(X), X < a.
        ?- sink(X).
        ?- small(X).
        ?- reach(a, X).
        ?- reach(X, X).
    `) == "sink(-2)\nsink(c)\n-- 2\nsmall(-2)\nsmall(5)\n-- 2\n"
        ~ "reach(a, 5)\nreach(a, b)\n-- 2\nreach(5, 5)\n-- 1\n");

    // Example 3: errors.
    assertThrown!StratificationException(solve("edge(1, 2). win(X) :- edge(X, Y), not win(Y). ?- win(X)."));
    assertThrown!UnsafeRuleException(solve("q(1). ?- q(X). p(X) :- q(Y). ?- p(X)."));
}

unittest
{
    // No queries: no output. Unknown predicate: empty answer.
    assert(solve("") == "");
    assert(solve("p(1).") == "");
    assert(solve("?- nothing(X).") == "-- 0\n");
    // Queries come out in input order whatever the position of the facts.
    assert(solve("?- p(X). p(2). ?- p(2). p(1).") == "p(1)\np(2)\n-- 2\np(2)\n-- 1\n");
    // Repeated variables in a query, anonymous variables.
    assert(solve("e(1,1). e(1,2). e(2,2). ?- e(X, X). ?- e(_, _). ?- e(1, _).")
            == "e(1, 1)\ne(2, 2)\n-- 2\ne(1, 1)\ne(1, 2)\ne(2, 2)\n-- 3\ne(1, 1)\ne(1, 2)\n-- 2\n");
}

unittest
{
    // Non-linear recursion: tuples from different rounds must combine in every position.
    auto text = "link(1,2). link(2,3). link(3,4). link(4,5). link(5,6). link(6,7). link(7,8)."
        ~ "link(X, Z) :- link(X, Y), link(Y, Z). ?- link(X, Y).";
    auto out_ = solve(text);
    assert(out_.length > 0);
    import std.algorithm : count;

    assert(out_.count('\n') == 28 + 1 + 0); // C(8,2) = 28 pairs plus the "-- 28" line
    assert(out_[$ - 6 .. $] == "-- 28\n");
}

unittest
{
    // Mutual recursion across two predicates, with a stratum of negation above it.
    auto out_ = solve(`
        num(0). num(1). num(2). num(3). num(4).
        succ(0, 1). succ(1, 2). succ(2, 3). succ(3, 4).
        even(0).
        even(Y) :- odd(X), succ(X, Y).
        odd(Y) :- even(X), succ(X, Y).
        neither(X) :- num(X), not even(X), not odd(X).
        ?- even(X).
        ?- odd(X).
        ?- neither(X).
    `);
    assert(out_ == "even(0)\neven(2)\neven(4)\n-- 3\nodd(1)\nodd(3)\n-- 2\n-- 0\n");
}

unittest
{
    // Comparisons use the total order: integers below identifiers.
    assert(solve("v(5). v(a). v(b). v(-1). lt(X, Y) :- v(X), v(Y), X < Y. ?- lt(b, X). ?- lt(X, a).")
            == "-- 0\nlt(-1, a)\nlt(5, a)\n-- 2\n");
    // `=` and `!=` between an integer and an identifier.
    assert(solve("v(1). v(one). ne(X, Y) :- v(X), v(Y), X != Y. eq(X, Y) :- v(X), v(Y), X = Y. "
            ~ "?- ne(X, Y). ?- eq(X, Y).")
            == "ne(1, one)\nne(one, 1)\n-- 2\neq(1, 1)\neq(one, one)\n-- 2\n");
    // A rule with no positive atom but constant-only conditions.
    assert(solve("q(1). p(a) :- not q(2). r(a) :- not q(1). ?- p(X). ?- r(X).") == "p(a)\n-- 1\n-- 0\n");
}

unittest
{
    // Rules whose body repeats a variable inside one atom, and constants in atoms.
    assert(solve("e(1,1). e(1,2). e(2,3). e(3,3). loop(X) :- e(X, X). from1(Y) :- e(1, Y). "
            ~ "?- loop(X). ?- from1(X).") == "loop(1)\nloop(3)\n-- 2\nfrom1(1)\nfrom1(2)\n-- 2\n");
}
