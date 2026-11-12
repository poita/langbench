/// @file base64.hpp
/// Base64 encoding (standard and URL-safe alphabets) and a strict decoder.
#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "webhooks/bytes.hpp"

namespace webhooks {

/// Standard alphabet (`+/`), padded with `=` to a multiple of four characters.
std::string base64_encode(ByteView data);

/// URL-safe alphabet (`-_`), without padding.
std::string base64url_encode(ByteView data);

/// Decodes Base64 in either alphabet, with or without padding.
///
/// Rules (SPEC.md §1.3): a trailing run of `=` must be exactly the padding the
/// encoder would emit; `=` anywhere else is invalid; the two alphabets must not
/// be mixed; a body length of 1 mod 4 is invalid; non-zero trailing bits are
/// ignored. Returns std::nullopt for an invalid string.
std::optional<Bytes> base64_decode(std::string_view text);

}  // namespace webhooks
