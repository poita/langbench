// DIMACS CNF reading and result writing.
#pragma once

#include <istream>
#include <ostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "sat/types.hpp"

namespace sat {

class Solver;

/// A formula as read from a DIMACS file. Literals are DIMACS integers
/// (non-zero; `k` means variable k true, `-k` false; 1 <= |k| <= num_vars).
struct Cnf {
    int num_vars = 0;
    std::vector<std::vector<int>> clauses;
};

/// Thrown by the parser on input that is not valid DIMACS CNF.
class ParseError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

/// Parses DIMACS CNF text. Accepts comments anywhere, blank lines, clauses
/// spanning lines and several clauses per line. Runs in O(input size).
/// Throws ParseError for a missing/duplicate header, literals outside
/// 1..num_vars, a clause that is not terminated by 0, or a wrong clause count.
Cnf parse_dimacs(std::string_view text);

/// Reads the whole stream and parses it with parse_dimacs(string_view).
Cnf parse_dimacs(std::istream& in);

/// Creates the variables of `cnf` in `solver` (which should be empty) and adds
/// every clause. Returns false if the solver already detected the formula to
/// be unsatisfiable while adding clauses.
bool load(Solver& solver, const Cnf& cnf);

/// True if `model` (indexed by 0-based variable) satisfies every clause of `cnf`.
bool satisfies(const Cnf& cnf, const std::vector<bool>& model);

/// Writes the answer in the competition-style format used by the CLI:
/// "UNSAT\n", or "SAT\n" followed by one line `l1 ... lV 0`, where li is i if
/// variable i is true and -i otherwise. `model` is ignored for Unsat.
void write_result(std::ostream& out, Result result, const std::vector<bool>& model);

}  // namespace sat
