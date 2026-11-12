// Strict RFC 8259 parser (with the extra restrictions listed in SPEC.md).
#pragma once

#include <cstddef>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

#include "jsoncanon/value.hpp"

namespace jsoncanon {

/// Maximum nesting depth of arrays/objects accepted by default.
inline constexpr std::size_t kDefaultMaxDepth = 512;

struct ParseOptions {
  /// Containers nested deeper than this are rejected. A top-level array has
  /// depth 1. Keep this modest: the parser is recursive.
  std::size_t max_depth = kDefaultMaxDepth;
};

/// Thrown by `parse` on malformed input.
class ParseError : public std::runtime_error {
 public:
  ParseError(std::string message, std::size_t offset)
      : std::runtime_error(message + " at byte " + std::to_string(offset)), offset_(offset) {}
  /// Byte offset in the input at which the problem was detected.
  std::size_t offset() const noexcept { return offset_; }

 private:
  std::size_t offset_;
};

/// Parses exactly one JSON document occupying the whole of `input`.
///
/// The bytes are first validated as strict UTF-8 (a leading BOM is rejected),
/// then parsed in one forward pass. Numbers are kept as canonical text,
/// strings are decoded, objects keep duplicate keys in input order.
/// Throws ParseError if the input is not a valid document.
Value parse(std::string_view input, const ParseOptions& options = {});

/// Like `parse` but returns std::nullopt instead of throwing ParseError.
std::optional<Value> try_parse(std::string_view input, const ParseOptions& options = {});

}  // namespace jsoncanon
