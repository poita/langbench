// Package sat is a small conflict-driven clause-learning (CDCL) SAT solver
// for propositional formulas in conjunctive normal form.
//
// The solver is MiniSat-style: two watched literals, first-UIP clause
// learning with local clause minimisation, VSIDS branching on an indexed
// binary heap, phase saving, Luby restarts and activity-based learnt-clause
// reduction. The search is fully deterministic: the same clauses added in
// the same order always give the same decisions, learnt clauses and model.
//
// Literals follow the DIMACS convention: variables are numbered from 1, the
// literal k means "variable k is true" and -k means "variable k is false".
// 0 is never a literal.
//
// Typical use:
//
//	s := sat.NewSolver(3)
//	s.AddClause(1, -2)
//	s.AddClause(2, 3)
//	if s.Solve() == sat.Satisfiable {
//		fmt.Println(s.Model()) // Model()[i] is the value of variable i+1
//	}
//
// Formulas in DIMACS files are read with ParseDIMACS and can be solved in one
// step with Solve; WriteResult prints the answer in the competition-style
// "SAT / UNSAT" format used by the accompanying command-line tool.
package sat
