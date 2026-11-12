// UTF-8 helpers: strict validation, encoding and UTF-16 ordering.
#pragma once

#include <string>
#include <string_view>

namespace jsoncanon::utf8 {

/// Returns true iff `s` is well-formed UTF-8 per RFC 3629: no overlong
/// forms, no encoded surrogates (U+D800..U+DFFF), nothing above U+10FFFF and
/// no truncated sequences. A byte-order mark is ordinary valid UTF-8 here;
/// rejecting it is the parser's concern.
bool is_valid(std::string_view s) noexcept;

/// Appends the UTF-8 encoding of the Unicode scalar value `cp` to `out`.
/// `cp` must be <= 0x10FFFF and not a surrogate.
void append_code_point(std::string& out, char32_t cp);

/// Three-way comparison of two *valid* UTF-8 strings by the sequence of their
/// UTF-16 code units, compared as unsigned 16-bit integers (a proper prefix
/// sorts first). Returns <0, 0 or >0.
///
/// This differs from UTF-8 byte order (= code point order) only in that
/// supplementary characters (surrogate pairs 0xD800..0xDFFF) sort before
/// U+E000..U+FFFF. Runs in time proportional to the common prefix length.
int compare_utf16(std::string_view a, std::string_view b) noexcept;

}  // namespace jsoncanon::utf8
