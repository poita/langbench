// 64-bit FNV-1a content hashing.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace kiln {

/// FNV-1a, 64 bit. `fnv1a64("")` is `0xcbf29ce484222325`.
std::uint64_t fnv1a64(std::string_view bytes) noexcept;

/// Exactly 16 lowercase hex digits, zero padded.
std::string hash_to_hex(std::uint64_t hash);

/// Parses exactly 16 lowercase hex digits; returns false for anything else.
bool hash_from_hex(std::string_view text, std::uint64_t& out) noexcept;

}  // namespace kiln
