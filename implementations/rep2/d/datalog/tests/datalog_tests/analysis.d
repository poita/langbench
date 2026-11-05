module datalog_tests.analysis;

import datalog.analysis;
import datalog.parser;

private Analysis check(string src) { return analyze(parseProgram(src)); }

unittest // safe programs
{
    assert(check("p(a). q(X) :- p(X), not r(X), X != b.").status == Status.ok);
    assert(check("p(X) :- q(X, _).").status == Status.ok);
    assert(check("").status == Status.ok);
}

unittest // unsafe programs
{
    assert(check("p(X).").status == Status.unsafeRule);
    assert(check("p(X) :- q(Y).").status == Status.unsafeRule);
    assert(check("p(X) :- q(X), not r(Y).").status == Status.unsafeRule);
    assert(check("p(X) :- q(X), not r(_).").status == Status.unsafeRule);
    assert(check("p(Y) :- q(X), X = Y.").status == Status.unsafeRule);
    assert(check("p(X) :- q(X), Y = 5.").status == Status.unsafeRule);
    assert(check("p(_) :- q(X).").status == Status.unsafeRule);
}

unittest // stratification
{
    assert(check("win(X) :- e(X, Y), not win(Y).").status == Status.notStratifiable);
    assert(check("a(X) :- b(X). b(X) :- c(X), not a(X).").status == Status.notStratifiable);
    assert(check("a(X) :- c(X), not b(X). b(X) :- c(X).").status == Status.ok);
    // negative edge between components, positive cycle elsewhere
    assert(check("a(X) :- b(X). b(X) :- a(X). c(X) :- d(X), not a(X).").status == Status.ok);
}

unittest // components come dependencies-first and recursion is detected
{
    auto prog = parseProgram("e(1,2). p(X,Y) :- e(X,Y). p(X,Z) :- p(X,Y), e(Y,Z). s(X) :- e(X,_), not p(X,X).");
    auto an = analyze(prog);
    assert(an.status == Status.ok);
    size_t compOf(string name)
    {
        foreach (i, c; an.components)
            foreach (p; c.preds)
                if (prog.predicates[p].name == name) return i;
        assert(0);
    }
    assert(compOf("e") < compOf("p"));
    assert(compOf("p") < compOf("s"));
    assert(an.components[compOf("p")].recursive);
    assert(!an.components[compOf("s")].recursive);
    assert(an.components[compOf("p")].rules.length == 2);
}
