// Package solver solves a 3x3x3 Rubik's cube with Thistlethwaite's
// four-phase algorithm.
//
// The cube is moved through a chain of nested subgroups
//
//	G0 = <U,D,L,R,F,B>  >  G1 = <U,D,L,R,F2,B2>  >  G2 = <U,D,L2,R2,F2,B2>
//	   >  G3 = <U2,D2,L2,R2,F2,B2>  >  G4 = {1}
//
// and in each phase a coordinate identifies the coset of the next subgroup
// that the cube lies in:
//
//	phase 1: orientation of 11 edges                              2,048 values
//	phase 2: orientation of 7 corners x E-slice edge positions    2,187 x 495
//	phase 3: corner permutation class mod the 96 half-turn
//	         corner permutations x M-slice edge positions         420 x 70
//	phase 4: half-turn corner permutation x permutation of each
//	         edge slice                                           96 x 24^3
//
// New builds one exact distance table per phase by breadth-first search from
// the goal; solving a cube is then a greedy descent through the tables, so
// every phase is optimal and a solution has at most 7+10+13+15 = 45 moves.
package solver
