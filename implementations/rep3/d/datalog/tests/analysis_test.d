module analysis_test;

import datalog;

private bool safe(string s) { auto p = parseProgram(s); return isSafe(p); }

private bool stratifiable(string s)
{
    auto p = parseProgram(s);
    Stratification st;
    return stratify(p, st);
}

unittest // safety
{
    assert(safe("p(X) :- q(X)."));
    assert(safe("p(a)."));
    assert(safe("p(X) :- q(X, _), not r(X), X < 5."));
    assert(!safe("p(X)."));
    assert(!safe("p(X) :- q(Y)."));
    assert(!safe("p(X) :- q(X), not r(Y)."));
    assert(!safe("p(X) :- q(X), not r(_)."));
    assert(!safe("p(Y) :- q(X), X = Y."));
    assert(!safe("p(X) :- q(X), Y = 5."));
    assert(!safe("p(_) :- q(X)."));
}

unittest // stratification
{
    assert(stratifiable("a(X) :- b(X). b(X) :- a(X)."));
    assert(stratifiable("a(X) :- b(X), not c(X). c(X) :- d(X)."));
    assert(!stratifiable("w(X) :- e(X, Y), not w(Y)."));
    assert(!stratifiable("a(X) :- e(X), not b(X). b(X) :- e(X), a(X)."));
}

unittest // components come in dependency order and recursion is detected
{
    auto p = parseProgram("path(X,Y) :- edge(X,Y). path(X,Z) :- edge(X,Y), path(Y,Z). "
                        ~ "top(X) :- path(X, _).");
    Stratification st;
    assert(stratify(p, st));
    uint idOf(string n)
    {
        foreach (i, ref q; p.predicates) if (q.name == n) return cast(uint) i;
        assert(0);
    }
    assert(st.componentOf[idOf("edge")] < st.componentOf[idOf("path")]);
    assert(st.componentOf[idOf("path")] < st.componentOf[idOf("top")]);
    assert(st.recursive[st.componentOf[idOf("path")]]);
    assert(!st.recursive[st.componentOf[idOf("top")]]);
}
