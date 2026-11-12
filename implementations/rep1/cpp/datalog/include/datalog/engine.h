// The Datalog engine: analysis + evaluation + querying.
#pragma once

#include <vector>

#include "datalog/ast.h"
#include "datalog/predicates.h"
#include "datalog/relation.h"
#include "datalog/value.h"

namespace datalog {

/// A tuple of constants.
using Tuple = std::vector<Constant>;

/// Computes the stratified model of a program and answers queries on it.
class Engine {
 public:
  /// Checks `program` (safety, then stratification) and computes its model
  /// by semi-naive evaluation. Throws ProgramError if the program is unsafe
  /// or not stratifiable. The queries inside `program` are ignored here;
  /// use query() or Program::queries with it.
  explicit Engine(const Program& program);

  /// All tuples of the model matching the pattern `query`, in ascending
  /// tuple order. A constant must equal the tuple's component; a variable
  /// occurring several times must match the same constant everywhere; `_` and
  /// single variables match anything. Unknown predicates yield no tuples.
  std::vector<Tuple> query(const Atom& query) const;

  /// Number of tuples of predicate `name`/`arity` in the model.
  std::size_t size(const std::string& name, std::size_t arity) const;

 private:
  PredicateTable preds_;
  ValueEncoder encoder_;
  std::vector<Relation> relations_;
};

}  // namespace datalog
