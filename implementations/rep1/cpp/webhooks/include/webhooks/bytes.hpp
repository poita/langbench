/// @file bytes.hpp
/// Byte-string vocabulary types shared by every module.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

namespace webhooks {

/// An owned byte string.
using Bytes = std::vector<std::uint8_t>;

/// A non-owning view of a byte string.
using ByteView = std::span<const std::uint8_t>;

/// Views the characters of @p text as bytes (no copy).
inline ByteView as_bytes(std::string_view text) noexcept {
  return ByteView(reinterpret_cast<const std::uint8_t*>(text.data()), text.size());
}

/// Views @p bytes as characters (no copy).
inline std::string_view as_text(ByteView bytes) noexcept {
  return std::string_view(reinterpret_cast<const char*>(bytes.data()), bytes.size());
}

}  // namespace webhooks
