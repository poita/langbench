/// \file parser.hpp
/// Parser for the textual registry + root manifest format of SPEC.md.
#pragma once

#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "depresolve/registry.hpp"

namespace depresolve {

/// A complete resolution problem: the registry and the root's requirements.
struct Problem {
  Registry registry;
  std::vector<Requirement> root;
};

/// Thrown by parse_problem on malformed input.
class ParseError : public std::runtime_error {
 public:
  ParseError(std::size_t line, const std::string& message)
      : std::runtime_error("line " + std::to_string(line) + ": " + message), line_(line) {}
  /// 1-based line number of the offending line.
  std::size_t line() const { return line_; }

 private:
  std::size_t line_;
};

/// Parses zero or more registry lines (`name X.Y.Z: dep range, dep range`)
/// followed by the root line (`root: dep range, ...`).
/// \throws ParseError if the text is malformed or has no root line.
Problem parse_problem(std::string_view text);

}  // namespace depresolve
