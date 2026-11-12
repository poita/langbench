#include "jsoncanon/jsoncanon.hpp"

namespace jsoncanon {

std::optional<std::string> canonicalize(std::string_view input, const ParseOptions& options) {
  auto value = try_parse(input, options);
  if (!value) return std::nullopt;
  return serialize(*value);
}

}  // namespace jsoncanon
