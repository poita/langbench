// FNV-1a 64-bit content hashing, as used throughout Kiln.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace kiln {

/// 64-bit FNV-1a hash of a byte string.
std::uint64_t fnv1a(std::string_view bytes) noexcept;

/// Renders a hash as exactly 16 lowercase hexadecimal digits.
std::string toHex16(std::uint64_t h);

/// Parses exactly 16 lowercase hex digits. Returns false for anything else.
bool parseHex16(std::string_view text, std::uint64_t& out) noexcept;

}  // namespace kiln
