// Content-Transfer-Encoding decoders (hand written).
#pragma once

#include <string>
#include <string_view>

namespace mime {

/// Quoted-printable decoding as defined by the specification (lenient).
std::string decode_quoted_printable(std::string_view in);

/// Lenient base64 decoding: every non-alphabet byte (including `=`) is dropped.
std::string decode_base64(std::string_view in);

/// Decodes a part body for the given (already lower-cased) encoding token.
/// Unknown encodings, `7bit`, `8bit` and `binary` return the input unchanged.
std::string decode_body(std::string_view body, std::string_view encoding);

/// True if `decode_body` would return the input unchanged for `encoding`.
bool is_identity_encoding(std::string_view encoding);

}  // namespace mime
