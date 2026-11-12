// The single diagnostic type used for every invalid input.
#pragma once

#include <exception>
#include <string>

namespace typeset {

/// A positioned error: `<file>:<line>:<col>: <code>`.
struct Error : std::exception {
    std::string file;  ///< "settings.cfg", "document.cdx" or "-"
    int line = 0;      ///< 1-based line
    int col = 0;       ///< 1-based column in Unicode scalar values
    std::string code;  ///< e.g. "bad-length"

    Error() = default;
    Error(std::string f, int l, int c, std::string cd)
        : file(std::move(f)), line(l), col(c), code(std::move(cd)) {}

    /// Formatted as `file:line:col: code` (no trailing newline).
    std::string format() const { return file + ":" + std::to_string(line) + ":" + std::to_string(col) + ": " + code; }
    const char* what() const noexcept override { return code.c_str(); }
};

}  // namespace typeset
