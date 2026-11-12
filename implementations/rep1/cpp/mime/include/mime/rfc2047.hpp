// RFC 2047 encoded words and the two header-text decoders built on them.
#pragma once

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace mime {

/// A recognised encoded word.
struct EncodedWord {
  std::size_t end;   ///< index just after the word
  std::string text;  ///< decoded text (UTF-8)
};

/// Tries to read an encoded word starting at `v[pos]`.
std::optional<EncodedWord> match_encoded_word(std::string_view v, std::size_t pos);

/// Decodes unstructured header text: encoded words are decoded and blanks
/// between adjacent encoded words are dropped; the result is stripped.
std::string decode_unstructured(std::string_view v);

/// Like decode_unstructured, but also handles comments (each becomes one
/// space) and quoted strings (kept literally). Used for address phrases.
std::string decode_display(std::string_view v);

}  // namespace mime
