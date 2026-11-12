//! End-to-end tests through the public API (`datalog::run`).

use datalog::{evaluate, run, Constant, Error, Program};

fn out(src: &str) -> String {
    run(src).unwrap()
}

#[test]
fn transitive_closure() {
    let src = "edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
               path(X, Y) :- edge(X, Y).
               path(X, Z) :- edge(X, Y), path(Y, Z).
               ?- path(1, X). ?- path(4, X). ?- path(X, X).";
    assert_eq!(
        out(src),
        "path(1, 1)\npath(1, 2)\npath(1, 3)\npath(1, 4)\n-- 4\n-- 0\n\
         path(1, 1)\npath(2, 2)\npath(3, 3)\n-- 3\n"
    );
}

#[test]
fn negation_comparisons_mixed_constants() {
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
        "sink(-2)\nsink(c)\n-- 2\nsmall(-2)\nsmall(5)\n-- 2\n\
         reach(a, 5)\nreach(a, b)\n-- 2\nreach(5, 5)\n-- 1\n"
    );
}

#[test]
fn unstratifiable_and_unsafe_programs() {
    assert!(matches!(
        run("edge(1, 2). win(X) :- edge(X, Y), not win(Y). ?- win(X)."),
        Err(Error::Unstratifiable { .. })
    ));
    assert!(matches!(
        run("q(1). ?- q(X). p(X) :- q(Y). ?- p(X)."),
        Err(Error::Unsafe { .. })
    ));
}

#[test]
fn nonlinear_recursion_combines_every_position() {
    let src = "link(1, 2). link(2, 3). link(3, 4). link(4, 5). link(5, 6).
               link(X, Z) :- link(X, Y), link(Y, Z).
               ?- link(1, X).";
    assert_eq!(out(src).lines().last(), Some("-- 5"));
}

#[test]
fn mutual_recursion() {
    let src = "s(0, 1). s(1, 2). s(2, 3). s(3, 4). even(0).
               odd(X) :- even(Y), s(Y, X).
               even(X) :- odd(Y), s(Y, X).
               ?- even(X). ?- odd(X).";
    assert_eq!(out(src), "even(0)\neven(2)\neven(4)\n-- 3\nodd(1)\nodd(3)\n-- 2\n");
}

#[test]
fn facts_in_recursive_predicates_seed_the_delta() {
    let src = "p(1, 2). p(2, 3). e(3, 4).
               p(X, Z) :- p(X, Y), e(Y, Z).
               ?- p(X, Y).";
    assert_eq!(out(src), "p(1, 2)\np(2, 3)\np(2, 4)\n-- 3\n");
}

#[test]
fn query_with_repeated_variable_and_unknown_predicate() {
    let src = "e(1, 1). e(1, 2). e(2, 2).
               ?- e(X, X). ?- nothing(X). ?- e(7, _).";
    assert_eq!(out(src), "e(1, 1)\ne(2, 2)\n-- 2\n-- 0\n-- 0\n");
}

#[test]
fn same_name_different_arity() {
    assert_eq!(out("r(1). ?- r(X). ?- r(X, Y)."), "r(1)\n-- 1\n-- 0\n");
}

#[test]
fn comparison_semantics() {
    let src = "v(a). v(b). v(3). v(-1).
               lt(X, Y) :- v(X), v(Y), X < Y.
               ne(X) :- v(X), X != a, X >= 3.
               ?- lt(b, a). ?- lt(-1, 3). ?- ne(X).";
    assert_eq!(out(src), "-- 0\nlt(-1, 3)\n-- 1\nne(3)\nne(b)\n-- 2\n");
}

#[test]
fn empty_and_query_free_programs() {
    assert_eq!(out(""), "");
    assert_eq!(out("% only a comment\n"), "");
    assert_eq!(out("p(1). q(X) :- p(X)."), "");
    assert_eq!(run("p(X)."), Err(Error::Unsafe { line: 1 }));
}

#[test]
fn library_api_exposes_the_model() {
    let program = Program::parse("e(1, b). e(1, a).").unwrap();
    let model = evaluate(&program).unwrap();
    assert_eq!(
        model.tuples("e", 2),
        vec![
            vec![Constant::Int(1), Constant::from("a")],
            vec![Constant::Int(1), Constant::from("b")],
        ]
    );
    assert!(model.tuples("e", 3).is_empty());
}

#[test]
fn stratified_negation_over_recursion() {
    let src = "e(1, 2). e(2, 3). n(1). n(2). n(3). n(4).
               r(X, Y) :- e(X, Y).
               r(X, Z) :- r(X, Y), e(Y, Z).
               unreach(X) :- n(X), not r(1, X), X != 1.
               ?- unreach(X).";
    assert_eq!(out(src), "unreach(4)\n-- 1\n");
}
