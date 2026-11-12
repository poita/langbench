// Structured header values (Content-Type & co.) with RFC 2231 parameters.
#pragma once

#include <map>
#include <optional>
#include <string>
#include <string_view>

namespace mime {

/// A parsed `value; name=value; ...` header.
struct StructuredValue {
  std::string value;  ///< first segment, stripped and lower-cased
  /// Effective parameters, RFC 2231 assembled and decoded, keyed by
  /// lower-cased name.
  std::map<std::string, std::string> params;

  /// The effective parameter `name`, if present.
  std::optional<std::string> param(const std::string& name) const;
};

/// Parses an unfolded raw header value.
StructuredValue parse_structured(std::string_view raw);

}  // namespace mime
