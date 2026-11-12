/**
 * Rubik's cube solver library.
 *
 * Import `rubiks` to get everything:
 *
 * $(UL
 *   $(LI `rubiks.move` - moves and their notation,)
 *   $(LI `rubiks.facelets` - the sticker model from the specification,)
 *   $(LI `rubiks.cubie` - the cubie-level cube,)
 *   $(LI `rubiks.coords` - coordinates and move tables,)
 *   $(LI `rubiks.phase` - one phase of the algorithm,)
 *   $(LI `rubiks.solver` - the four-phase solver,)
 *   $(LI `rubiks.io` - the line-based text format of the CLI.)
 * )
 */
module rubiks;

public import rubiks.move;
public import rubiks.facelets;
public import rubiks.cubie;
public import rubiks.coords;
public import rubiks.phase;
public import rubiks.solver;
public import rubiks.io;
