// Reading DIMACS CNF files and writing solver answers.
#pragma once

#include <iosfwd>
#include <stdexcept>
#include <string>
#include <vector>

#include "sat/solver.hpp"

namespace sat {

/// Thrown by the parser on input that is not valid DIMACS CNF.
class ParseError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// A parsed formula: clauses are lists of non-zero DIMACS integers.
struct Cnf {
  int numVars = 0;
  std::vector<std::vector<int>> clauses;
};

/// Parse DIMACS CNF text. Handles comment lines anywhere, clauses spanning
/// lines or sharing a line, empty clauses, and a missing final newline.
/// Throws ParseError on malformed input.
Cnf parseDimacs(std::istream& in);
Cnf parseDimacs(const std::string& text);

/// Load every clause of `cnf` into `solver` (creating all `cnf.numVars`
/// variables, even those that occur in no clause). Returns false if the
/// formula was found unsatisfiable while loading.
bool loadInto(Solver& solver, const Cnf& cnf);

/// Write the answer in the format "SAT\n<l1> ... <lV> 0\n" or "UNSAT\n".
/// `model` (indexed by variable, 0-based) is only used for Result::Sat.
void writeResult(std::ostream& out, Result result, const std::vector<bool>& model);

}  // namespace sat
