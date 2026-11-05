/**
 * sat: a conflict-driven clause-learning (CDCL) SAT solver.
 *
 * Importing `sat` pulls in the whole public API:
 *
 * $(UL
 *   $(LI `sat.solver`: the $(D Solver) class and $(D solve) convenience function)
 *   $(LI `sat.dimacs`: DIMACS CNF parsing into a $(D Cnf))
 *   $(LI `sat.output`: rendering of results in the CLI's output format)
 *   $(LI `sat.types`, `sat.heap`, `sat.luby`: building blocks)
 * )
 */
module sat;

public import sat.types;
public import sat.luby;
public import sat.heap;
public import sat.dimacs;
public import sat.solver;
public import sat.output;
