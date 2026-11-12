// Formula syntax tree.
#pragma once

#include <memory>
#include <string>
#include <vector>

#include "spreadsheet/cell_ref.h"

namespace spreadsheet {

enum class BinaryOp { Add, Sub, Mul, Div, Concat, Eq, Ne, Lt, Gt, Le, Ge };
enum class AggregateFn { Sum, Min, Max, Avg, Count };

/// One node of a parsed formula.
struct Expr {
  enum class Kind {
    Number,     // `number`
    String,     // `text`
    Ref,        // `ref`
    Range,      // `range`; only appears as a direct argument of an aggregate
    Negate,     // args[0]
    Binary,     // `op`; args[0], args[1]
    If,         // args[0] ? args[1] : args[2]
    Aggregate,  // `fn`; args (expressions and ranges)
  };

  Kind kind = Kind::Number;
  double number = 0;
  std::string text;
  CellRef ref;
  CellRange range;
  BinaryOp op = BinaryOp::Add;
  AggregateFn fn = AggregateFn::Sum;
  std::vector<std::unique_ptr<Expr>> args;
};

/// A parsed formula: the syntax tree with resolved references.
///
/// A formula containing any invalid reference (e.g. `AAA1`, `A0`) has
/// `has_invalid_reference() == true`; it always evaluates to #REF! and
/// reports no dependencies.
class Formula {
 public:
  Formula(std::unique_ptr<Expr> root, bool has_invalid_reference)
      : root_(std::move(root)), invalid_ref_(has_invalid_reference) {}

  const Expr& root() const { return *root_; }
  bool has_invalid_reference() const { return invalid_ref_; }

  /// Every cell the formula depends on: all valid references plus every cell
  /// covered by a range, deduplicated and sorted in row-major order. Empty
  /// when the formula has an invalid reference.
  std::vector<CellRef> dependencies() const;

 private:
  std::unique_ptr<Expr> root_;
  bool invalid_ref_;
};

}  // namespace spreadsheet
