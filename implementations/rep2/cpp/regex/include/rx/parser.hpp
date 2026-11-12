// Recursive-descent parser for the supported pattern syntax.
#pragma once

#include <string_view>

#include "rx/ast.hpp"
#include "rx/error.hpp"

namespace rx {

/// Largest count accepted in a `{n,m}` quantifier.
constexpr int kMaxRepeatCount = 1000;

/// Parses `pattern` into a syntax tree. Character classes are resolved to
/// CharSets and every node's `nullable` flag is filled in.
/// \throws ParseError if the pattern is not valid.
ParsedPattern parse(std::string_view pattern);

}  // namespace rx
