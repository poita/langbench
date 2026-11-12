// Convenience entry points combining the pieces: bytes/hex <-> text.
#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "protowire/decoder.hpp"
#include "protowire/encoder.hpp"
#include "protowire/hex.hpp"
#include "protowire/schema.hpp"
#include "protowire/text_format.hpp"

namespace protowire {

/// Decodes `bytes` as `message` and returns its canonical text. Throws WireError.
inline std::string decodeToText(const MessageDescriptor& message, std::span<const std::uint8_t> bytes) {
  return formatMessage(decode(message, bytes));
}

/// Parses `text` as `message` and returns its canonical encoding. Throws TextError.
inline std::vector<std::uint8_t> encodeFromText(const MessageDescriptor& message, std::string_view text) {
  return encode(parseMessage(message, text));
}

}  // namespace protowire
