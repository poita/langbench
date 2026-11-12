/**
 * A small CDCL SAT solver for formulas in conjunctive normal form.
 *
 * Import this package to get the whole public API:
 *
 * $(UL
 *   $(LI $(MODULE sat.dimacs): parsing DIMACS CNF text and formatting answers,)
 *   $(LI $(MODULE sat.solver): the $(D Solver) class and the one-call $(D solve) helper,)
 *   $(LI $(MODULE sat.types): the literal encoding,)
 *   $(LI $(MODULE sat.order): the VSIDS variable-order heap,)
 *   $(LI $(MODULE sat.luby): the Luby restart sequence,)
 *   $(LI $(MODULE sat.vec): a small growable array.)
 * )
 */
module sat;

public import sat.dimacs;
public import sat.luby;
public import sat.order;
public import sat.solver;
public import sat.types;
public import sat.vec;
