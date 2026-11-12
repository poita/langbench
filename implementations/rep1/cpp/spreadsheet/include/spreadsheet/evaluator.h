// Formula evaluation.
#pragma once

#include "spreadsheet/cell_ref.h"
#include "spreadsheet/formula.h"
#include "spreadsheet/value.h"

namespace spreadsheet {

/// Source of cell values for the evaluator. Must return the *stored* value of
/// a cell (an empty Value for an empty cell); it must never evaluate on demand.
class CellLookup {
 public:
  virtual ~CellLookup() = default;
  virtual const Value& value_at(CellRef ref) const = 0;
};

/// Evaluates a formula against the current cell values. The result is never
/// Value::Kind::Empty: an empty result becomes the number 0.
Value evaluate(const Formula& formula, const CellLookup& cells);

}  // namespace spreadsheet
