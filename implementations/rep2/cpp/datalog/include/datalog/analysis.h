// Static checks: safety and stratification.
#pragma once

#include <stdexcept>
#include <string>
#include <vector>

#include "datalog/ast.h"

namespace datalog {

/// Thrown when a program is unsafe or not stratifiable.
class ProgramError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// A predicate: name together with arity (`r/1` and `r/2` are different).
struct PredicateKey {
  std::string name;
  std::size_t arity = 0;
  friend bool operator==(const PredicateKey&, const PredicateKey&) = default;
  friend auto operator<=>(const PredicateKey&, const PredicateKey&) = default;
};

PredicateKey key_of(const Atom& atom);

/// True if every variable in the head, in a negated atom or in a comparison
/// also occurs in a positive body atom (and `_` occurs in none of the former).
bool is_safe(const Rule& rule);

/// Throws ProgramError if any rule is unsafe.
void check_safety(const Program& program);

/// Strongly connected components of the predicate dependency graph, in an
/// order in which they can be evaluated (dependencies first). Contains every
/// predicate that occurs in a rule head or body. Throws ProgramError if a
/// negative dependency lies on a cycle.
std::vector<std::vector<PredicateKey>> stratify(const Program& program);

}  // namespace datalog
