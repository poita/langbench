// The spreadsheet: cell storage plus incremental recalculation.
#pragma once

#include <memory>
#include <string_view>
#include <utility>
#include <vector>

#include "spreadsheet/cell_ref.h"
#include "spreadsheet/value.h"

namespace spreadsheet {

/// An in-memory sheet of numbers, strings and formulas.
///
/// Every mutation recalculates eagerly: only the edited cell and the cells
/// that transitively read it are revisited (a dependency graph, Tarjan's
/// strongly-connected components to find cycles, evaluation in dependency
/// order). After each call returns, every formula cell holds the value its
/// formula yields against the current sheet. Cells on a reference cycle hold
/// #CYCLE!.
class Sheet {
 public:
  Sheet();
  ~Sheet();
  Sheet(Sheet&&) noexcept;
  Sheet& operator=(Sheet&&) noexcept;
  Sheet(const Sheet&) = delete;
  Sheet& operator=(const Sheet&) = delete;

  /// Stores a number / string literal in the cell.
  void set_number(CellRef ref, double value);
  void set_string(CellRef ref, std::string_view text);

  /// Stores a formula. `expression` is the text after the leading `=`.
  /// Throws ParseError (leaving the sheet unchanged) on a syntax error.
  void set_formula(CellRef ref, std::string_view expression);

  /// Sets a cell from command-line style content: `=...` is a formula,
  /// `"..."` a string literal, anything else a number literal such as `-4.50`.
  /// Throws ParseError (leaving the sheet unchanged) for malformed content.
  void set_content(CellRef ref, std::string_view content);

  /// Makes the cell empty.
  void clear(CellRef ref);

  /// The cell's current value (an empty Value for an empty cell).
  const Value& value(CellRef ref) const;

  /// The cell's displayed text ("" for an empty cell).
  std::string display(CellRef ref) const;

  /// Every non-empty cell with its value, in row-major order.
  std::vector<std::pair<CellRef, Value>> cells() const;

  /// Number of non-empty cells.
  std::size_t size() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace spreadsheet
