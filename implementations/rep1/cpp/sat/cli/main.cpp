// Command-line tool: reads DIMACS CNF on stdin, prints SAT + model or UNSAT.
#include <iostream>

#include "sat/dimacs.hpp"
#include "sat/solver.hpp"

int main() {
  std::ios::sync_with_stdio(false);
  try {
    sat::Cnf cnf = sat::parseDimacs(std::cin);
    sat::Solver solver;
    sat::loadInto(solver, cnf);
    sat::Result r = solver.solve();
    sat::writeResult(std::cout, r, solver.model());
  } catch (const sat::ParseError& e) {
    std::cerr << "sat: " << e.what() << "\n";
    return 2;
  }
  return 0;
}
