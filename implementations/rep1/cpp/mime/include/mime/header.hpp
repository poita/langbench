// Header block parsing: line classification, unfolding, name/value split.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace mime {

/// One header field, unfolded, with name and value decoded as UTF-8.
struct HeaderField {
  std::string name;       ///< text before the first ':' (original case)
  std::string raw_value;  ///< unfolded text after the first ':'

  /// Lower-cased name with surrounding blanks stripped.
  std::string key() const;
};

/// A parsed header block.
struct HeaderBlock {
  std::vector<HeaderField> fields;
  std::size_t body_offset = 0;  ///< where the body starts in the input
};

/// Parses the header block of `message` (line endings already normalised).
HeaderBlock parse_headers(std::string_view message);

/// First field whose key equals `key` (lower case), or nullptr.
const HeaderField* find_field(const std::vector<HeaderField>& fields, std::string_view key);

/// The value shown in the dump: collapse() for a fixed set of structured
/// fields, decode_unstructured() otherwise.
std::string display_value(const HeaderField& field);

}  // namespace mime
