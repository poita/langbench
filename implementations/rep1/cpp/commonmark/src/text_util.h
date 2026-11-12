// Internal character classification and text helpers shared by the parsers
// and the renderer. Not part of the public API.
#ifndef COMMONMARK_TEXT_UTIL_H
#define COMMONMARK_TEXT_UTIL_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace commonmark::detail {

/// cmark's whitespace set: space, TAB, LF, VT, FF, CR.
constexpr bool is_space(char c) noexcept {
  return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}
constexpr bool is_space_or_tab(char c) noexcept { return c == ' ' || c == '\t'; }
constexpr bool is_digit(char c) noexcept { return c >= '0' && c <= '9'; }
constexpr bool is_alpha(char c) noexcept {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}
constexpr bool is_alnum(char c) noexcept { return is_alpha(c) || is_digit(c); }
constexpr bool is_xdigit(char c) noexcept {
  return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
/// ASCII punctuation: !"#$%&'()*+,-./:;<=>?@[\]^_`{|}~
constexpr bool is_ascii_punct(char c) noexcept {
  return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') ||
         (c >= '{' && c <= '~');
}

/// Appends the UTF-8 encoding of `cp` (invalid code points become U+FFFD).
void append_utf8(std::string& out, std::uint32_t cp);

/// If `s[pos] == '&'` starts a recognised entity reference (`&amp;`, `&lt;`,
/// `&gt;`, `&quot;`, `&#NNN;`, `&#xHHH;`), appends its decoded text to `out`
/// and returns the number of bytes consumed; otherwise returns 0.
std::size_t match_entity(std::string_view s, std::size_t pos, std::string& out);

/// Replaces every recognised entity reference in `s` by its text.
std::string decode_entities(std::string_view s);

/// Removes the backslash from every backslash-escaped ASCII punctuation.
std::string unescape_backslashes(std::string_view s);

/// Trims cmark whitespace from both ends.
std::string_view trim(std::string_view s) noexcept;
/// Trims cmark whitespace from the end.
std::string_view rtrim(std::string_view s) noexcept;

}  // namespace commonmark::detail

#endif  // COMMONMARK_TEXT_UTIL_H
