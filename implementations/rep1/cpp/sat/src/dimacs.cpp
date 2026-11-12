#include "sat/dimacs.hpp"

#include <algorithm>
#include <cstdlib>
#include <istream>
#include <limits>
#include <ostream>
#include <sstream>

namespace sat {

namespace {

bool isBlank(char c) { return c == ' ' || c == '\t' || c == '\r'; }

// Parse a decimal integer token; throws ParseError if it is not one.
long long parseInt(const std::string& tok) {
  std::size_t i = 0;
  bool neg = false;
  if (i < tok.size() && (tok[i] == '-' || tok[i] == '+')) neg = tok[i++] == '-';
  if (i == tok.size()) throw ParseError("invalid integer '" + tok + "'");
  long long v = 0;
  for (; i < tok.size(); ++i) {
    if (tok[i] < '0' || tok[i] > '9') throw ParseError("invalid integer '" + tok + "'");
    v = v * 10 + (tok[i] - '0');
    if (v > std::numeric_limits<int>::max()) throw ParseError("integer too large '" + tok + "'");
  }
  return neg ? -v : v;
}

// Split a line on blanks.
std::vector<std::string> tokens(const std::string& line) {
  std::vector<std::string> out;
  std::size_t i = 0;
  while (i < line.size()) {
    while (i < line.size() && isBlank(line[i])) ++i;
    std::size_t start = i;
    while (i < line.size() && !isBlank(line[i])) ++i;
    if (i > start) out.push_back(line.substr(start, i - start));
  }
  return out;
}

}  // namespace

Cnf parseDimacs(std::istream& in) {
  Cnf cnf;
  bool haveHeader = false;
  long long declaredClauses = 0;
  std::vector<int> current;
  std::string line;

  while (std::getline(in, line)) {
    std::size_t first = 0;
    while (first < line.size() && isBlank(line[first])) ++first;
    if (first == line.size() || line[first] == 'c') continue;

    if (line[first] == 'p') {
      if (haveHeader) throw ParseError("duplicate header");
      auto t = tokens(line);
      if (t.size() != 4 || t[0] != "p" || t[1] != "cnf") throw ParseError("malformed header");
      long long v = parseInt(t[2]), c = parseInt(t[3]);
      if (v < 0 || c < 0) throw ParseError("negative count in header");
      cnf.numVars = static_cast<int>(v);
      declaredClauses = c;
      cnf.clauses.reserve(static_cast<std::size_t>(std::min<long long>(c, 1 << 20)));
      haveHeader = true;
      continue;
    }

    if (!haveHeader) throw ParseError("clause data before header");
    for (const std::string& tok : tokens(line)) {
      long long lit = parseInt(tok);
      if (lit == 0) {
        cnf.clauses.push_back(std::move(current));
        current.clear();
      } else {
        long long var = lit < 0 ? -lit : lit;
        if (var > cnf.numVars) throw ParseError("literal " + tok + " out of range");
        current.push_back(static_cast<int>(lit));
      }
    }
  }

  if (!haveHeader) throw ParseError("missing header");
  if (!current.empty()) throw ParseError("last clause is not terminated by 0");
  if (static_cast<long long>(cnf.clauses.size()) != declaredClauses)
    throw ParseError("clause count does not match header");
  return cnf;
}

Cnf parseDimacs(const std::string& text) {
  std::istringstream in(text);
  return parseDimacs(in);
}

bool loadInto(Solver& solver, const Cnf& cnf) {
  solver.reserveVars(cnf.numVars);
  bool ok = true;
  for (const auto& clause : cnf.clauses) {
    std::vector<Lit> lits;
    lits.reserve(clause.size());
    for (int d : clause) lits.push_back(Lit::fromDimacs(d));
    ok = solver.addClause(std::move(lits)) && ok;
  }
  return ok;
}

void writeResult(std::ostream& out, Result result, const std::vector<bool>& model) {
  if (result == Result::Unsat) {
    out << "UNSAT\n";
    return;
  }
  std::string line;
  for (std::size_t v = 0; v < model.size(); ++v) {
    if (!model[v]) line += '-';
    line += std::to_string(v + 1);
    line += ' ';
  }
  line += "0\n";
  out << "SAT\n" << line;
}

}  // namespace sat
