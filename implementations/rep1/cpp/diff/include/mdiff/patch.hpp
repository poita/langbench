// Applying an edit script.
#pragma once

#include "mdiff/lines.hpp"
#include "mdiff/script.hpp"

namespace mdiff {

/// Applies a textual edit script (each element is a tag character followed by
/// the line text) to `a` in a single pass and returns the lines of the result.
/// Returned views point into `a` or `script_lines`.
///
/// Throws ScriptError if a tag is invalid, or if the script's keep/delete
/// lines do not match `a` exactly (text and count).
Lines apply_script(const Lines& a, const Lines& script_lines);

}  // namespace mdiff
