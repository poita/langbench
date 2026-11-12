// Semi-naive bottom-up evaluation of stratified Datalog.
#pragma once

#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "datalog/analysis.h"
#include "datalog/ast.h"
#include "datalog/relation.h"

namespace datalog {

using Tuple = std::vector<Constant>;

/// The perfect model of a program.
class Model {
 public:
  /// All tuples matching the query atom, in ascending tuple order. Constants
  /// must be equal to the tuple's component; a variable that occurs several
  /// times must match the same constant everywhere; `_` matches anything.
  /// A predicate that does not exist has no tuples.
  std::vector<Tuple> query(const Atom& atom);

  /// Number of tuples in a predicate (0 if it does not exist).
  std::size_t size(const std::string& predicate, std::size_t arity) const;

  /// Answers a query in the textual form of the CLI: one `p(a, b)` line per
  /// matching tuple followed by `-- N`.
  std::string answer(const Query& query);

 private:
  friend Model evaluate(const Program& program);

  std::vector<Constant> constants_;  // sorted; Value == index
  std::map<PredicateKey, std::unique_ptr<Relation>> relations_;
};

/// Checks safety and stratification, then computes the perfect model.
/// Throws ProgramError if the program is unsafe or not stratifiable.
Model evaluate(const Program& program);

/// Parses `source`, evaluates it and answers its queries in order. Returns
/// "error\n" if the program is unsafe or not stratifiable. Throws ParseError
/// on malformed input.
std::string run_program(const std::string& source);

}  // namespace datalog
