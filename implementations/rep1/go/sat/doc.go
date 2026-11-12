// Package sat is a conflict-driven clause-learning (CDCL) SAT solver in the
// style of MiniSat.
//
// A [Solver] is built by adding clauses over integer literals using the
// DIMACS convention: variable k (k >= 1) is the literal k, its negation is
// -k, and 0 is never a literal. After all clauses are added, [Solver.Solve]
// decides satisfiability and, for satisfiable formulas, [Solver.Model]
// returns a satisfying assignment.
//
// The solver implements two-watched-literal unit propagation, first-UIP
// clause learning with local clause minimisation, VSIDS branching with phase
// saving, Luby restarts and activity-based deletion of learnt clauses.
//
//	s := sat.New()
//	s.AddClause(1, -2)
//	s.AddClause(2, 3)
//	if s.Solve() == sat.Satisfiable {
//		fmt.Println(s.Model()) // e.g. [false false true]
//	}
//
// A Solver is not safe for concurrent use.
package sat
