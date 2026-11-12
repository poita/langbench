// toml/utf8.hpp - strict UTF-8 helpers.
#pragma once

#include <string>
#include <string_view>

namespace toml {

/// True when `s` is well-formed UTF-8: no truncated or overlong sequences, no
/// encoded surrogates and nothing above U+10FFFF.
bool is_valid_utf8(std::string_view s);

/// Appends the UTF-8 encoding of `cp` (which must be a Unicode scalar value).
void append_utf8(std::string& out, char32_t cp);

}  // namespace toml
