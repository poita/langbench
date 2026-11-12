// KBL parsing.
#pragma once

#include <memory>
#include <string>
#include <string_view>

#include "kiln/ast.hpp"

namespace kiln {

/// Lexes and parses a whole build file. Throws `Error("E_PARSE", "path:line")`
/// choosing the error exactly as SPEC "Which E_PARSE is reported" prescribes.
std::unique_ptr<ParsedFile> parseBuildFile(std::string_view source, const std::string& path);

/// True if `word` is a KBL reserved word.
bool isReservedWord(std::string_view word) noexcept;

}  // namespace kiln
