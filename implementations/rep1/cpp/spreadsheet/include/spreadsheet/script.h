// Line-oriented command interpreter (the engine behind the CLI).
#pragma once

#include <iosfwd>
#include <string_view>

#include "spreadsheet/sheet.h"

namespace spreadsheet {

/// Executes commands against a sheet:
///
///   set <CELL> <content>   replace a cell's content
///   get <CELL>             print the cell's displayed value
///   clear <CELL>           empty the cell
///   dump                   print every non-empty cell as "<CELL> <value>",
///                          in row-major order
///
/// Output lines are terminated by '\n'.
class CommandProcessor {
 public:
  explicit CommandProcessor(Sheet& sheet) : sheet_(sheet) {}

  /// Executes one command line (without its line terminator), writing any
  /// result to `out`. Returns false (and executes nothing) if the line is not
  /// a well-formed command.
  bool execute(std::string_view line, std::ostream& out);

  /// Executes every line of `in`. Malformed lines are reported on `err` and
  /// skipped. Returns the number of malformed lines.
  std::size_t run(std::istream& in, std::ostream& out, std::ostream& err);

 private:
  Sheet& sheet_;
};

}  // namespace spreadsheet
