// Package sat implements a conflict-driven clause-learning (CDCL) SAT solver
// in the style of MiniSat.
//
// The solver decides the satisfiability of propositional formulas in
// conjunctive normal form. It uses two watched literals per clause for unit
// propagation, first-UIP conflict analysis with local clause minimisation,
// VSIDS branching with phase saving, Luby restarts and activity-based
// deletion of learnt clauses.
//
// Typical use:
//
//	s := sat.NewSolver()
//	a, b := s.NewVar(), s.NewVar()
//	s.AddClause(sat.MkLit(a, false), sat.MkLit(b, false)) // a ∨ b
//	s.AddClause(sat.MkLit(a, true))                       // ¬a
//	if s.Solve() == sat.Satisfiable {
//		fmt.Println(s.Model()) // [false true]
//	}
//
// Variables are numbered from 0. Literals can also be built from DIMACS-style
// integers with [FromDIMACS]. A Solver is not safe for concurrent use.
package sat
