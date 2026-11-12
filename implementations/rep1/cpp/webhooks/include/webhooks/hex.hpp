/// @file hex.hpp
/// Lowercase hexadecimal encoding and strict decoding.
#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "webhooks/bytes.hpp"

namespace webhooks {

/// Encodes @p bytes as lowercase hex digits (two per byte, no separators).
std::string to_hex(ByteView bytes);

/// Decodes an even-length run of lowercase hex digits.
/// Returns std::nullopt on an odd length or any other character (including
/// uppercase digits). The empty string decodes to zero bytes.
std::optional<Bytes> from_hex(std::string_view hex);

}  // namespace webhooks
