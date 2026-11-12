#pragma once

/// \file script.hpp
/// Running a whole script: an initial document followed by commands.

#include <cstddef>
#include <iosfwd>
#include <string_view>

namespace textbuffer {

/// Runs \p input, which is: a line with the number N of document lines, N
/// document lines taken verbatim, then one command per line. The output of
/// every `print` command goes to \p out. Lines that are not valid commands
/// are reported on \p err (when non-null) and skipped. Returns the number of
/// skipped lines.
std::size_t runScript(std::string_view input, std::ostream& out, std::ostream* err = nullptr);

}  // namespace textbuffer
