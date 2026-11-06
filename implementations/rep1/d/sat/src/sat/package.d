/**
 * A MiniSat-style conflict-driven clause-learning (CDCL) SAT solver.
 *
 * Importing `sat` pulls in the whole public API:
 *
 * $(UL
 *   $(LI `sat.solver`: the `Solver` itself and the `Result` enum.)
 *   $(LI `sat.dimacs`: DIMACS CNF parsing (`parseDimacs`, `Cnf`) and
 *       result formatting (`formatResult`).)
 *   $(LI `sat.heap`: the indexed VSIDS priority queue (`VarHeap`).)
 *   $(LI `sat.luby`: the Luby restart sequence.)
 *   $(LI `sat.types`: literal encoding helpers.)
 * )
 */
module sat;

public import sat.types;
public import sat.luby;
public import sat.heap;
public import sat.dimacs;
public import sat.solver;
