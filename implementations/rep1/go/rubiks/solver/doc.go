// Package solver finds solutions for 3x3x3 Rubik's cubes using
// Thistlethwaite's four-phase algorithm.
//
// The cube is moved through a chain of subgroups
//
//	G0 = <U D L R F B>  ->  G1 = <U D L R F2 B2>  ->  G2 = <U D L2 R2 F2 B2>
//	   ->  G3 = <U2 D2 L2 R2 F2 B2>  ->  solved
//
// Each phase has a small integer coordinate identifying the cube's coset in
// the next subgroup. Exact distance tables (one byte per coordinate value, filled
// by breadth-first search from the goal) are built once, and a solution is
// found by greedy descent in each table, so every phase is solved optimally
// and a solution has at most 7 + 10 + 13 + 15 = 45 moves.
//
// A [Solver] builds its tables lazily on first use (about a tenth of a
// second) and is then safe for concurrent use by multiple goroutines.
package solver
