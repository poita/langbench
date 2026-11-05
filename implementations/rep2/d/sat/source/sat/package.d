/**
 * `sat` — a CDCL SAT solver library.
 *
 * $(UL
 *   $(LI $(MREF sat.solver): the solver itself ($(D Solver), $(D SolveResult)))
 *   $(LI $(MREF sat.dimacs): DIMACS parsing and result formatting)
 *   $(LI $(MREF sat.heap): the VSIDS variable heap)
 *   $(LI $(MREF sat.types): literal encoding helpers)
 * )
 */
module sat;

public import sat.dimacs;
public import sat.heap;
public import sat.solver;
public import sat.types;
