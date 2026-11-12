//! End-to-end tests through `datalog::run`, covering the language semantics.

use datalog::{run, Error};

fn out(src: &str) -> String {
    run(src).unwrap_or_else(|e| panic!("{e}"))
}

#[test]
fn transitive_closure() {
    let src = "edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
        path(X, Y) :- edge(X, Y).
        path(X, Z) :- edge(X, Y), path(Y, Z).
        ?- path(1, X). ?- path(4, X). ?- path(X, X).";
    assert_eq!(
        out(src),
        "path(1, 1)\npath(1, 2)\npath(1, 3)\npath(1, 4)\n-- 4\n-- 0\npath(1, 1)\npath(2, 2)\npath(3, 3)\n-- 3\n"
    );
}

#[test]
fn negation_comparisons_and_mixed_constants() {
    let src = "% nodes and links
        node(a). node(b). node(c). node(5). node(-2).
        link(a, b). link(b, 5). link(5, 5).
        reach(X, Y) :- link(X, Y).
        reach(X, Z) :- reach(X, Y), link(Y, Z).
        sink(X) :- node(X), not hasout(X).
        hasout(X) :- link(X, _).
        small(X) :- node(X), X < a.
        ?- sink(X). ?- small(X). ?- reach(a, X). ?- reach(X, X).";
    assert_eq!(
        out(src),
        "sink(-2)\nsink(c)\n-- 2\nsmall(-2)\nsmall(5)\n-- 2\nreach(a, 5)\nreach(a, b)\n-- 2\nreach(5, 5)\n-- 1\n"
    );
}

#[test]
fn unstratifiable_and_unsafe_are_semantic_errors() {
    let e = run("edge(1, 2). win(X) :- edge(X, Y), not win(Y). ?- win(X).").unwrap_err();
    assert!(matches!(e, Error::NotStratifiable { .. }));
    let e = run("q(1). ?- q(X). p(X) :- q(Y). ?- p(X).").unwrap_err();
    assert!(matches!(e, Error::UnsafeRule { .. }));
    assert!(e.is_semantic());
    assert!(!run("p(").unwrap_err().is_semantic());
}

#[test]
fn no_queries_no_output() {
    assert_eq!(out(""), "");
    assert_eq!(out("% only a comment\n"), "");
    assert_eq!(out("p(1). q(X) :- p(X)."), "");
}

#[test]
fn queries_see_the_whole_program() {
    assert_eq!(out("?- p(X). p(1)."), "p(1)\n-- 1\n");
}

#[test]
fn unknown_predicates_and_arities_are_empty() {
    assert_eq!(out("r(1). ?- r(X, Y). ?- nothing(X)."), "-- 0\n-- 0\n");
    assert_eq!(out("r(1). r(1, 2). ?- r(X). ?- r(X, Y)."), "r(1)\n-- 1\nr(1, 2)\n-- 1\n");
    assert_eq!(out("p(X) :- q(X), not r(X). q(1). ?- p(X)."), "p(1)\n-- 1\n");
}

#[test]
fn ordering_of_constants() {
    let src = "c(b). c(a_b). c(aa). c(a). c(a0). c(a_). c(10). c(-3). c(2). c(0). ?- c(X).";
    assert_eq!(
        out(src),
        "c(-3)\nc(0)\nc(2)\nc(10)\nc(a)\nc(a0)\nc(a_)\nc(a_b)\nc(aa)\nc(b)\n-- 10\n"
    );
}

#[test]
fn comparison_operators() {
    let src = "n(1). n(2). n(3). n(x).
        lt(X, Y) :- n(X), n(Y), X < Y.
        le(X, Y) :- n(X), n(Y), X <= Y.
        ne(X, Y) :- n(X), n(Y), X != Y, X >= Y.
        eq(X, Y) :- n(X), n(Y), X = Y, Y > 2.
        ?- lt(2, X). ?- le(X, 1). ?- ne(x, X). ?- eq(X, Y).";
    assert_eq!(
        out(src),
        "lt(2, 3)\nlt(2, x)\n-- 2\nle(1, 1)\n-- 1\nne(x, 1)\nne(x, 2)\nne(x, 3)\n-- 3\neq(3, 3)\neq(x, x)\n-- 2\n"
    );
}

#[test]
fn ground_comparisons_and_negations_without_positive_atoms() {
    assert_eq!(out("p(a) :- 1 < 2. q(a) :- 2 < 1. r(a) :- not s(b). ?- p(X). ?- q(X). ?- r(X)."),
        "p(a)\n-- 1\n-- 0\nr(a)\n-- 1\n");
}

#[test]
fn query_patterns() {
    let src = "t(1, 1, 2). t(1, 2, 2). t(3, 3, 3).
        ?- t(X, X, _). ?- t(_, Y, Y). ?- t(1, _, _). ?- t(_, _, _). ?- t(X, Y, X).";
    assert_eq!(
        out(src),
        "t(1, 1, 2)\nt(3, 3, 3)\n-- 2\nt(1, 2, 2)\nt(3, 3, 3)\n-- 2\nt(1, 1, 2)\nt(1, 2, 2)\n-- 2\n\
         t(1, 1, 2)\nt(1, 2, 2)\nt(3, 3, 3)\n-- 3\nt(3, 3, 3)\n-- 1\n"
    );
}

#[test]
fn repeated_variable_in_body_atom() {
    assert_eq!(out("e(1,1). e(1,2). e(2,2). loop(X) :- e(X, X). ?- loop(X)."), "loop(1)\nloop(2)\n-- 2\n");
}

#[test]
fn non_linear_recursion() {
    let mut src = String::new();
    for i in 0..30 {
        src.push_str(&format!("link({i}, {}). ", i + 1));
    }
    src.push_str("link(X, Z) :- link(X, Y), link(Y, Z). ?- link(X, Y).");
    let o = out(&src);
    assert!(o.ends_with("-- 465\n"), "{}", &o[o.len().saturating_sub(40)..]); // C(31, 2)
}

#[test]
fn mutual_recursion() {
    let src = "num(0). succ(0, 1). succ(1, 2). succ(2, 3). succ(3, 4).
        even(0).
        odd(Y) :- even(X), succ(X, Y).
        even(Y) :- odd(X), succ(X, Y).
        ?- even(X). ?- odd(X).";
    assert_eq!(out(src), "even(0)\neven(2)\neven(4)\n-- 3\nodd(1)\nodd(3)\n-- 2\n");
}

#[test]
fn facts_for_a_recursive_predicate_and_two_deltas_in_one_body() {
    // Both `r` atoms are recursive; derivations need the delta in either slot.
    let src = "r(1, 2). r(3, 4). r(2, 3). r(X, Z) :- r(X, Y), r(Y, Z). ?- r(1, X).";
    assert_eq!(out(src), "r(1, 2)\nr(1, 3)\nr(1, 4)\n-- 3\n");
}

#[test]
fn stratified_negation_over_recursion() {
    let src = "edge(a, b). edge(b, c). node(a). node(b). node(c). node(d).
        reach(X, Y) :- edge(X, Y).
        reach(X, Z) :- reach(X, Y), edge(Y, Z).
        unreach(X, Y) :- node(X), node(Y), not reach(X, Y), X != Y.
        ?- unreach(a, X). ?- unreach(d, X).";
    assert_eq!(
        out(src),
        "unreach(a, d)\n-- 1\nunreach(d, a)\nunreach(d, b)\nunreach(d, c)\n-- 3\n"
    );
}

#[test]
fn comments_and_layout() {
    assert_eq!(out("p(1).%c\r\n?-\tp(X).p(2)."), "p(1)\np(2)\n-- 2\n");
}

#[test]
fn error_wins_over_queries() {
    assert!(run("p(1). ?- p(X). q(X) :- not p(X).").is_err());
    assert!(run("p(X) :- q(X), not p(X).").is_err());
    assert!(run("p(1) :- not p(1).").is_err());
    assert!(run("p(_).").is_err());
    assert!(run("p(1). q(X) :- p(X), X < Y.").is_err());
}
