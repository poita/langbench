// Package datalog implements a Datalog engine with stratified negation and
// integer/symbol comparisons.
//
// A program is parsed with [Parse], which interns every predicate and constant
// and renumbers the constants so that their ids follow the total order of the
// language (all integers, numerically, before all identifiers, bytewise).
// [Program.Solve] checks that the program is safe and stratifiable and then
// computes its perfect model bottom-up with semi-naive evaluation over
// hash-indexed relations. The resulting [Model] answers the program's queries
// ([Model.Answers]) and can be inspected directly ([Model.Relation]).
//
// Syntax summary:
//
//	edge(1, 2). edge(2, 3).              % facts
//	path(X, Y) :- edge(X, Y).            % rules
//	path(X, Z) :- edge(X, Y), path(Y, Z).
//	lonely(X) :- node(X), not edge(X, _), X != root.
//	?- path(1, X).                       % queries
//
// Variables start with an upper-case letter, constants are integers or
// lower-case identifiers, and "_" is an anonymous variable. Comparisons
// (<, <=, >, >=, =, !=) never bind variables.
package datalog
