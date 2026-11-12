/// @file like.hpp
/// @brief The `LIKE` pattern matcher.
#pragma once

#include <string_view>

namespace minisql {

/// Matches `text` against `pattern`. `%` matches any run of characters, `_`
/// exactly one (UTF-8) character; everything else matches itself,
/// case-insensitively for ASCII letters only. The whole text must match.
/// Runs in O(|text|·|pattern|) using a single backtrack point.
bool like_match(std::string_view text, std::string_view pattern);

}  // namespace minisql
