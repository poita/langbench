/**
 * A CDCL SAT solver for formulas in DIMACS CNF.
 *
 * Importing `sat` gives the whole public API:
 *
 * $(UL
 *   $(LI `sat.dimacs`: parse DIMACS text into a $(D Cnf) and render a result.)
 *   $(LI `sat.solver`: the $(D Solver) class (incremental clause addition, `solve`).)
 *   $(LI `sat.types`: literal and tri-state value types.)
 *   $(LI `sat.model`: check an assignment against a formula.)
 * )
 *
 * Example:
 * ---
 * import sat;
 * auto cnf = parseDimacs("p cnf 2 2\n1 2 0\n-1 0\n");
 * auto res = solveCnf(cnf);
 * assert(res.satisfiable);
 * assert(satisfies(cnf, res.model));
 * ---
 */
module sat;

public import sat.types;
public import sat.dimacs;
public import sat.solver;
public import sat.model;
