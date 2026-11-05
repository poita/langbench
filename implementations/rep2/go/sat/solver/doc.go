// Package solver implements a conflict-driven clause-learning (CDCL) SAT
// solver in the MiniSat tradition: two watched literals, first-UIP clause
// learning with local minimisation, VSIDS branching on an indexed heap, phase
// saving, Luby restarts and periodic learnt-clause reduction.
//
// Literals in the public API are non-zero DIMACS integers: k means variable
// k is true, -k that it is false. Variables are numbered from 1.
//
//	s := solver.New(3)
//	s.AddClause(1, -2)
//	s.AddClause(2, 3)
//	if s.Solve() == solver.Sat {
//		fmt.Println(s.Model()) // e.g. [false false true]
//	}
//
// The search is fully deterministic: the same clauses added in the same order
// always yield the same model.
package solver
