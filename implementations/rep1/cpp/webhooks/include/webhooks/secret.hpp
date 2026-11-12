/// @file secret.hpp
/// Parsing of Standard Webhooks secrets.
#pragma once

#include <optional>
#include <string_view>

#include "webhooks/bytes.hpp"

namespace webhooks {

/// Turns a textual secret into the raw HMAC key.
///
/// A single leading `whsec_` is removed (once), then the remainder is decoded
/// with base64_decode(). Returns std::nullopt if the remainder is not valid
/// Base64 or decodes to zero bytes.
std::optional<Bytes> parse_secret(std::string_view secret);

}  // namespace webhooks
