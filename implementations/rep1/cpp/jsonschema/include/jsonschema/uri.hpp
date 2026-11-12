// RFC 3986 reference resolution and RFC 6901 JSON Pointer helpers.
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace jsonschema::uri {

/// A URI reference split into its five RFC 3986 components. A component that
/// is absent is nullopt, which is different from present-but-empty.
struct Reference {
  std::optional<std::string> scheme;
  std::optional<std::string> authority;
  std::string path;
  std::optional<std::string> query;
  std::optional<std::string> fragment;
};

/// Splits `text` into components (RFC 3986 appendix B); never fails.
Reference parse(std::string_view text);

/// Recomposes a reference (RFC 3986 section 5.3).
std::string recompose(const Reference& ref);

/// RFC 3986 section 5.2.4.
std::string remove_dot_segments(std::string_view path);

/// Strict reference resolution (RFC 3986 section 5.2.2). `base` may be empty.
std::string resolve(std::string_view reference, std::string_view base);

/// `uri` without its `#fragment`, if any.
std::string strip_fragment(std::string_view uri);

/// Splits at the first '#': the document part and, if a '#' was present, the fragment.
std::pair<std::string, std::optional<std::string>> split_fragment(std::string_view uri);

/// Decodes %XX escapes; malformed escapes are kept verbatim.
std::string percent_decode(std::string_view s);

/// Splits an RFC 6901 pointer ("" or "/a/b") into unescaped reference tokens
/// (`~1` -> `/`, `~0` -> `~`). Returns nullopt if the pointer does not start with '/'
/// (and is not empty).
std::optional<std::vector<std::string>> parse_json_pointer(std::string_view pointer);

}  // namespace jsonschema::uri
