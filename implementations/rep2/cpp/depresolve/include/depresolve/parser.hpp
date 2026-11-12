// Parsing of the registry + root manifest text format.
#pragma once

#include <cstddef>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "depresolve/registry.hpp"

namespace depresolve {

/// Thrown for input that does not follow the grammar.
class ParseError : public std::runtime_error {
 public:
  ParseError(std::size_t line, const std::string& message)
      : std::runtime_error("line " + std::to_string(line) + ": " + message), line_(line) {}
  /// 1-based line number of the offending line.
  std::size_t line() const noexcept { return line_; }

 private:
  std::size_t line_;
};

/// A registry together with the root manifest's requirements.
struct Problem {
  Registry registry;            ///< finalized
  std::vector<Dependency> root;  ///< in the order written
};

/// Parses `registry_line* root_line` (see SPEC.md for the grammar).
/// The returned registry is finalized.
/// @throws ParseError on malformed input, std::invalid_argument on a
///         duplicate (name, version) pair.
Problem parse_problem(std::string_view text);

/// Parses a requirement list such as "a ^1.0.0, b *" (without the leading
/// space that follows the colon in the file format). An empty string yields
/// no requirements.
/// @throws ParseError (reported with line number `line`).
std::vector<Dependency> parse_requirements(std::string_view text, std::size_t line = 0);

}  // namespace depresolve
