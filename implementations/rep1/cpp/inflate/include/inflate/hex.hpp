#pragma once
/// \file hex.hpp
/// Lowercase hexadecimal conversion helpers.

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace inflate {

/// Decode hexadecimal text (two digits per byte, either case) into bytes.
/// Leading and trailing ASCII whitespace is ignored. Returns false, leaving
/// `out` empty, on an odd digit count or a non-hex character.
bool hex_decode(std::string_view text, std::vector<std::uint8_t>& out);

/// Encode bytes as lowercase hexadecimal, two digits per byte.
std::string hex_encode(const std::uint8_t* data, std::size_t size);
std::string hex_encode(const std::vector<std::uint8_t>& data);

}  // namespace inflate
