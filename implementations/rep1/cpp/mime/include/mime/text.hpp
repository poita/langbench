// Byte/line helpers shared by every module: newline normalisation, line
// splitting, blank stripping, quoted-string and comment scanning, and the
// escaping used by the text dump.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace mime {

/// True for SPACE and TAB.
inline bool is_blank(char c) { return c == ' ' || c == '\t'; }

/// Strips SPACE/TAB from both ends.
std::string_view strip_blanks(std::string_view s);

/// ASCII-only lower-casing.
std::string ascii_lower(std::string_view s);

/// Replaces each maximal run of SPACE/TAB by one SPACE, then strips one
/// leading and one trailing SPACE.
std::string collapse(std::string_view s);

/// Turns every CRLF into LF and leaves every other byte alone.
std::string normalize_newlines(std::string_view s);

/// Splits into lines per the specification: terminators (LF, or CRLF) are
/// removed and a trailing terminator does not yield an empty last line.
std::vector<std::string_view> split_lines(std::string_view s);

/// Result of scanning a quoted string.
struct QuotedString {
  std::string text;  ///< contents with backslash escapes resolved
  std::size_t end;   ///< index just after the closing quote (or end of input)
};

/// Scans a quoted string whose opening `"` is at `s[pos]`. An unterminated
/// string runs to the end of `s`; a trailing lone backslash stands for itself.
QuotedString scan_quoted(std::string_view s, std::size_t pos);

/// Skips a (possibly nested) comment whose `(` is at `s[pos]`; returns the
/// index just after the matching `)`, or `s.size()` if it is unterminated.
std::size_t skip_comment(std::string_view s, std::size_t pos);

/// Escapes a UTF-8 string for the text dump (`\\`, `\n`, `\r`, `\t`, `\"`,
/// `\xHH` for C0/DEL/C1 code points).
std::string escape(std::string_view s);

/// `"` + escape(s) + `"`.
std::string quote(std::string_view s);

}  // namespace mime
