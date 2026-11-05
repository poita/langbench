/**
 * Rubik's cube solver library.
 *
 * Modules:
 * $(UL
 *   $(LI $(MREF rubiks, moves): faces, move tokens, parsing and formatting)
 *   $(LI $(MREF rubiks, facelet): the 54-sticker model from the specification)
 *   $(LI $(MREF rubiks, cubie): corner/edge permutation and orientation, moves)
 *   $(LI $(MREF rubiks, coord): phase coordinates and ranking helpers)
 *   $(LI $(MREF rubiks, movetables): per-component move tables)
 *   $(LI $(MREF rubiks, phases): the phase coordinate spaces and distance-table BFS)
 *   $(LI $(MREF rubiks, solver): the `Solver` class)
 * )
 *
 * Importing `rubiks` gives the everyday API: `Move`, `parseMoves`,
 * `formatMoves`, `CubieCube`, `FaceletCube` and `Solver`.
 *
 * ---
 * import rubiks;
 * auto solver = new Solver;                       // builds tables once
 * auto solution = solver.solve("R U R' U' F2");   // Move[]
 * writeln(formatMoves(solution));
 * ---
 */
module rubiks;

public import rubiks.cubie;
public import rubiks.facelet;
public import rubiks.moves;
public import rubiks.solver;
