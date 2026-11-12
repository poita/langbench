// Command-line front end: reads DIMACS CNF on stdin, prints SAT/UNSAT (and a
// model) on stdout.
#include <iostream>

#include "sat/dimacs.hpp"
#include "sat/solver.hpp"

int main() {
    std::ios::sync_with_stdio(false);
    try {
        sat::Cnf cnf = sat::parse_dimacs(std::cin);
        sat::Solver solver;
        sat::Result result = sat::load(solver, cnf) ? solver.solve() : sat::Result::Unsat;
        sat::write_result(std::cout, result, result == sat::Result::Sat ? solver.model() : std::vector<bool>{});
    } catch (const sat::ParseError& e) {
        std::cerr << "sat: parse error: " << e.what() << '\n';
        return 2;
    }
    return 0;
}
