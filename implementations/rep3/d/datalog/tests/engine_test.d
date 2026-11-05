module engine_test;

import datalog;

private string run(string s)
{
    return solve(s).output;
}

unittest // transitive closure (spec example 1)
{
    assert(run("edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).\n"
             ~ "path(X, Y) :- edge(X, Y).\n"
             ~ "path(X, Z) :- edge(X, Y), path(Y, Z).\n"
             ~ "?- path(1, X). ?- path(4, X). ?- path(X, X).")
        == "path(1, 1)\npath(1, 2)\npath(1, 3)\npath(1, 4)\n-- 4\n-- 0\n"
         ~ "path(1, 1)\npath(2, 2)\npath(3, 3)\n-- 3\n");
}

unittest // negation, comparisons, mixed constants (spec example 2)
{
    assert(run("node(a). node(b). node(c). node(5). node(-2).\n"
             ~ "link(a, b). link(b, 5). link(5, 5).\n"
             ~ "reach(X, Y) :- link(X, Y).\n"
             ~ "reach(X, Z) :- reach(X, Y), link(Y, Z).\n"
             ~ "sink(X) :- node(X), not hasout(X).\n"
             ~ "hasout(X) :- link(X, _).\n"
             ~ "small(X) :- node(X), X < a.\n"
             ~ "?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X).")
        == "sink(-2)\nsink(c)\n-- 2\nsmall(-2)\nsmall(5)\n-- 2\n"
         ~ "reach(a, 5)\nreach(a, b)\n-- 2\nreach(5, 5)\n-- 1\n");
}

unittest // errors
{
    auto r = solve("edge(1, 2).\nwin(X) :- edge(X, Y), not win(Y).\n?- win(X).");
    assert(!r.ok && r.output == "error\n");
    r = solve("q(1).\n?- q(X).\np(X) :- q(Y).\n?- p(X).");
    assert(!r.ok && r.output == "error\n");
}

unittest // non-linear recursion
{
    assert(run("l(1,2). l(2,3). l(3,4). l(4,5).\n"
             ~ "l(X,Z) :- l(X,Y), l(Y,Z).\n?- l(1, X).")
        == "l(1, 2)\nl(1, 3)\nl(1, 4)\nl(1, 5)\n-- 4\n");
}

unittest // mutual recursion
{
    assert(run("zero(0). s(0,1). s(1,2). s(2,3).\n"
             ~ "even(X) :- zero(X). even(Y) :- odd(X), s(X,Y). odd(Y) :- even(X), s(X,Y).\n"
             ~ "?- even(X).")
        == "even(0)\neven(2)\n-- 2\n");
}

unittest // repeated variables, anonymous variables, same name different arity
{
    assert(run("e(1,1). e(1,2). e(2,2). r(1).\n"
             ~ "loop(X) :- e(X, X).\n?- loop(X). ?- e(Y, Y). ?- e(_, _). ?- r(X, Y).")
        == "loop(1)\nloop(2)\n-- 2\ne(1, 1)\ne(2, 2)\n-- 2\n"
         ~ "e(1, 1)\ne(1, 2)\ne(2, 2)\n-- 3\n-- 0\n");
}

unittest // ground comparisons and bodies without positive atoms
{
    assert(run("p(1) :- 1 < 2. q(1) :- 2 < 1. ?- p(X). ?- q(X).") == "p(1)\n-- 1\n-- 0\n");
    assert(run("a(1). b(X) :- a(X), not a(2). ?- b(X).") == "b(1)\n-- 1\n");
}

unittest // comparisons use the total order
{
    assert(run("v(a). v(5). v(b). t(X, Y) :- v(X), v(Y), X < Y. ?- t(X, Y).")
        == "t(5, a)\nt(5, b)\nt(a, b)\n-- 3\n");
    assert(run("v(a). v(5). n(X, Y) :- v(X), v(Y), X != Y, X >= Y. ?- n(X, Y).")
        == "n(a, 5)\n-- 1\n");
}

unittest // empty program, program without queries
{
    assert(run("") == "");
    assert(run("% only a comment\n") == "");
    assert(run("p(1). q(X) :- p(X).") == "");
    assert(run("p(X).") == "error\n");
}

unittest // queries are answered in order, after the whole program is read
{
    assert(run("?- p(X). p(1). ?- p(2). p(2).") == "p(1)\np(2)\n-- 2\np(2)\n-- 1\n");
}

unittest // plans: delta variant of a rule with two recursive atoms and a filter
{
    auto p = parseProgram("a(X,Z) :- a(X,Y), a(Y,Z), X != Z.");
    auto rel = new Relation[p.predicates.length];
    foreach (i, ref q; p.predicates) rel[i] = new Relation(q.arity);
    auto plan = compilePlan(p.rules[0], rel, 1);
    assert(plan.steps.length == 2);
    assert(plan.steps[0].isDelta && plan.steps[0].kind == StepKind.scan);
    assert(plan.steps[1].kind == StepKind.lookup);
    assert(plan.steps[1].filters.length == 1);
}
