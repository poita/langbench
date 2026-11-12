// Edit scripts: representation, rendering and parsing of the text format.
#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>
#include <vector>

#include "mdiff/lines.hpp"

namespace mdiff {

enum class EditKind : char {
  Keep = ' ',    ///< line of A also present in B
  Delete = '-',  ///< line of A removed
  Insert = '+',  ///< line of B added
};

/// One step of an edit script. `index` is a 0-based line number in A for
/// Keep and Delete, and in B for Insert.
struct Edit {
  EditKind kind;
  std::size_t index;
};

using EditScript = std::vector<Edit>;

/// Number of Delete and Insert edits.
std::size_t script_cost(const EditScript& script);

/// Renders the script in the textual format: one line per edit, tag character
/// followed by the line text, each terminated by '\n'. (No count line.)
std::string render_script(const EditScript& script, const Lines& a, const Lines& b);

/// Thrown for malformed or inconsistent scripts.
class ScriptError : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

/// A parsed script line: its tag and the text after the tag.
struct ScriptLine {
  EditKind kind;
  Line text;
};

/// Parses one textual script line (tag + content). Throws ScriptError if the
/// line is empty or its tag is not one of ' ', '-', '+'.
ScriptLine parse_script_line(Line line);

}  // namespace mdiff
