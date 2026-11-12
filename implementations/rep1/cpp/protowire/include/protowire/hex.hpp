// Lowercase hexadecimal conversion.
#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace protowire {

/// Appends the lowercase hex of `bytes` to `out`.
void appendHex(std::string& out, std::span<const std::uint8_t> bytes);

/// Lowercase hex of `bytes`.
std::string toHex(std::span<const std::uint8_t> bytes);

/// Parses lowercase hex (even length, digits 0-9a-f only). Throws HexError otherwise.
std::vector<std::uint8_t> fromHex(std::string_view hex);

}  // namespace protowire
