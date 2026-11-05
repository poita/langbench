// Package datalog implements a Datalog engine with stratified negation.
//
// A program is a sequence of facts, rules and queries:
//
//	edge(1, 2). edge(2, 3).
//	path(X, Y) :- edge(X, Y).
//	path(X, Z) :- edge(X, Y), path(Y, Z).
//	?- path(1, X).
//
// Constants are integers or lower-case identifiers, variables start with an
// upper-case letter, and "_" is an anonymous variable. Rule bodies may contain
// positive atoms, negated atoms ("not p(X)") and comparisons
// (<, <=, >, >=, =, !=).
//
// The pipeline is split by responsibility:
//
//   - lexer.go, parser.go and ast.go turn source text into a [Program], with
//     every constant interned and renumbered so that integer id order equals
//     the constant order (integers numerically, then identifiers bytewise);
//   - check.go verifies rule safety and computes the strongly connected
//     components of the predicate dependency graph, rejecting programs with
//     unsafe rules ([ErrUnsafe]) or negation inside a recursive cycle
//     ([ErrNotStratifiable]);
//   - relation.go provides append-only tuple stores with a hash set and
//     lazily built, incrementally extended hash indexes;
//   - plan.go compiles each rule into a join plan;
//   - eval.go runs the plans bottom-up, component by component, using
//     semi-naive evaluation for recursive components, and returns a [Model];
//   - query.go answers queries against the model and formats the results.
//
// The one-call entry point is [Solve]; [Parse], [Evaluate] and [Model] expose
// the individual stages.
package datalog
