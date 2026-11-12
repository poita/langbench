// Solve a scramble given on the command line, e.g.  ./rubiks_example "R U F' D2"
#include <iostream>

#include "rubiks/rubiks.hpp"

int main(int argc, char** argv) {
  auto scramble = rubiks::parseMoves(argc > 1 ? argv[1] : "R U R' U'");
  if (!scramble) {
    std::cerr << "bad scramble\n";
    return 1;
  }
  rubiks::Solver solver;  // builds the pruning tables once
  rubiks::Solution s = solver.solve(*scramble);
  std::cout << rubiks::toString(s.moves) << "  (" << s.moves.size() << " moves)\n";
}
