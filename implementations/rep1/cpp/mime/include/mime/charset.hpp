// Character-set decoding to UTF-8.
#pragma once

#include <string>
#include <string_view>

namespace mime {

/// Strips SPACE/TAB from both ends and lower-cases ASCII letters.
std::string normalize_charset_name(std::string_view name);

/// Appends the UTF-8 encoding of a code point.
void append_utf8(std::string& out, char32_t cp);

/// Decodes `bytes` as UTF-8 using the "maximal subpart" replacement rule.
std::string decode_utf8(std::string_view bytes);

/// Decodes `bytes` in the named charset (ASCII, UTF-8, Latin-1 and cp1252;
/// every unknown name, including the empty one, means cp1252). The result
/// is always valid UTF-8.
std::string decode(std::string_view bytes, std::string_view charset);

/// Number of code points in a valid UTF-8 string.
std::size_t count_code_points(std::string_view utf8);

}  // namespace mime
