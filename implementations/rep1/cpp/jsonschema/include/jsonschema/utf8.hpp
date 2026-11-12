// UTF-8 helpers used throughout the library.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>

namespace jsonschema::utf8 {

/// Number of Unicode code points in a UTF-8 string (continuation bytes are not counted).
std::size_t length(std::string_view s) noexcept;

/// Decodes UTF-8 into code points. Malformed bytes decode to U+FFFD.
std::u32string decode(std::string_view s);

/// Appends the UTF-8 encoding of `cp` to `out`. Surrogates are encoded as three bytes.
void append(std::string& out, char32_t cp);

}  // namespace jsonschema::utf8
